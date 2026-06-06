import Foundation

/// Debug entry point: prints the native reader's per-day token totals as
/// "yyyy-MM-dd<TAB>totalTokens", one line per day, sorted ascending — for diffing
/// against `ccusage daily --json`. Invoked with the `--dump-daily` argument.
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
