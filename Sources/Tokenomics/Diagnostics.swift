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

/// Prints today's non-empty 5-minute token buckets (combined Claude+Codex) plus a
/// TOTAL, to sanity-check the intraday rate chart. Invoked with `--dump-intraday`.
enum DumpIntraday {
    static func run() {
        let provider = CombinedProvider([ClaudeNativeProvider(), CodexProvider()])
        let semaphore = DispatchSemaphore(value: 0)
        provider.fetchTodayByMinute(now: Date()) { minutes in
            var out = ""
            var total = 0
            var start = 0
            while start < 1440 {
                let sum = minutes[start..<min(start + 5, 1440)].reduce(0, +)
                total += sum
                if sum > 0 { out += String(format: "%02d:%02d\t%d\n", start / 60, start % 60, sum) }
                start += 5
            }
            out += "TOTAL\t\(total)\n"
            FileHandle.standardOutput.write(Data(out.utf8))
            semaphore.signal()
        }
        semaphore.wait()
    }
}

enum DumpDaily {
    /// `--dump-daily` dumps Claude; `--dump-codex` dumps Codex.
    static func run(provider: UsageProvider = ClaudeNativeProvider()) {
        let semaphore = DispatchSemaphore(value: 0)
        provider.fetchDaily { result in
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
