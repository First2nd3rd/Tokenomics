import Foundation

/// Debug entry point: prints the native reader's per-day token totals as
/// "yyyy-MM-dd<TAB>totalTokens", one line per day, sorted ascending — for diffing
/// against `ccusage daily --json`. Invoked with the `--dump-daily` argument.
/// Times two consecutive reads on one provider instance: the first does the full
/// scan, the second should hit the mtime cache. Invoked with `--bench`.
enum Bench {
    static func run() {
        let provider = ClaudeNativeProvider()
        for i in 1...2 {
            let start = Date()
            let semaphore = DispatchSemaphore(value: 0)
            provider.fetchDaily { _ in semaphore.signal() }
            semaphore.wait()
            let ms = Date().timeIntervalSince(start) * 1000
            FileHandle.standardError.write(Data(String(format: "read #%d: %.0f ms\n", i, ms).utf8))
        }
    }
}

enum DumpDaily {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        ClaudeNativeProvider().fetchDaily { result in
            switch result {
            case .success(let days):
                var out = ""
                for day in days.sorted(by: { $0.date < $1.date }) {
                    out += "\(day.date)\t\(day.inputTokens)\t\(day.outputTokens)\t\(day.cacheCreationTokens)\t\(day.cacheReadTokens)\t\(day.totalTokens)\t\(String(format: "%.6f", day.totalCost))\n"
                }
                FileHandle.standardOutput.write(Data(out.utf8))
            case .failure(let error):
                FileHandle.standardError.write(Data("dump-daily error: \(error)\n".utf8))
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
