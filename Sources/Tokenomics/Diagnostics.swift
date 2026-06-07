import Foundation

/// Runs an async, callback-based fetch synchronously. Diagnostics only.
private func waitFor<T>(_ fetch: (@escaping (T) -> Void) -> Void) -> T {
    var result: T!
    let semaphore = DispatchSemaphore(value: 0)
    fetch { value in
        result = value
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

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

/// Streams every Claude JSONL line WITHOUT decoding or storing — isolates the
/// LineReader's memory behaviour from parsing. Invoked with `--scan-only`.
enum ScanOnly {
    static func run() {
        var lines = 0
        var bytes = 0
        for root in ClaudeNativeProvider.claudeProjectRoots() {
            for file in ClaudeNativeProvider.jsonlFiles(under: root) {
                LineReader.forEachLine(of: file) { lineData in
                    lines += 1
                    bytes += lineData.count
                }
            }
        }
        FileHandle.standardOutput.write(Data("lines=\(lines) bytes=\(bytes)\n".utf8))
    }
}

/// Prints per-day token totals + cost as TSV, for diffing against
/// `ccusage daily --json`. `--dump-daily` dumps Claude; `--dump-codex` dumps Codex.
enum DumpDaily {
    static func run(provider: UsageProvider = ClaudeNativeProvider()) {
        let result = waitFor { provider.fetchDaily(completion: $0) }
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
    }
}

/// Prints today's non-empty 5-minute token buckets (combined Claude+Codex) plus a
/// TOTAL, to sanity-check the intraday rate chart. Invoked with `--dump-intraday`.
enum DumpIntraday {
    static func run() {
        let provider = CombinedProvider([ClaudeNativeProvider(), CodexProvider()])
        let now = Date()
        let matrix = waitFor { provider.fetchDayMinuteMatrix(now: now, lastDays: 0, completion: $0) }
        let minutes = matrix[DayBucket.dayKey(now)] ?? Array(repeating: MinuteBucket(), count: 1440)

        var out = ""
        var total = 0
        var start = 0
        while start < 1440 {
            let sum = minutes[start..<min(start + 5, 1440)].reduce(0) { $0 + $1.counts.total }
            total += sum
            if sum > 0 { out += String(format: "%02d:%02d\t%d\n", start / 60, start % 60, sum) }
            start += 5
        }
        out += "TOTAL\t\(total)\n"
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

/// Prints the cumulative-curve summary (today final, typical final, projected) to
/// sanity-check the prediction. Invoked with `--dump-curve`.
enum DumpCurve {
    static func run() {
        let provider = CombinedProvider([ClaudeNativeProvider(), CodexProvider()])
        let now = Date()
        let matrix = waitFor { provider.fetchDayMinuteMatrix(now: now, lastDays: 14, completion: $0) }
        let series = IntradayCurve.build(matrix: matrix, now: now)

        var out = ""
        out += "prior days in matrix: \(matrix.keys.count - 1)\n"
        out += "today cumulative (so far): \(series.today.last?.tokens ?? 0)\n"
        out += "typical day (avg total):   \(series.typical.last?.tokens ?? 0)\n"
        out += "projected end-of-day:      \(series.projectedTotal.map(String.init) ?? "n/a")\n"
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}
