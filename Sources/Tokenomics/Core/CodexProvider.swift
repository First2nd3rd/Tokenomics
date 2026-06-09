import Foundation

/// Reads OpenAI Codex usage from `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// `token_count` events carry a CUMULATIVE `total_token_usage` per session. We
/// bucket per-event deltas (current cumulative − previous) by local day, which
/// naturally dedups repeated events and splits sessions that cross midnight.
/// Mapping to the normalized model:
///   - cacheRead       = cached_input_tokens
///   - input           = input_tokens − cached_input_tokens (non-cached input)
///   - output          = output_tokens (already includes reasoning tokens)
///   - cacheCreation   = 0 (Codex has no cache-creation concept)
/// Cost comes from the shared price table; models without a price (e.g.
/// `codex-auto-review`) contribute tokens but $0, matching ccusage.
///
/// Deltas are computed per file, so each file's parsed records are self-contained
/// and cacheable by (mtime, size) — identical to the Claude reader — which keeps
/// recurring refreshes off the full-rescan path once warm.
final class CodexProvider: UsageProvider {
    let id = "codex"

    /// Per-file parse cache with NDJSON persistence. "v1" is the format version.
    private let cache = FileRecordCache<CodexRecord>(diskFileName: "codex-records-v2.ndjson",
                                                     queueLabel: "tokenomics.codex-reader")

    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(.success(self.readDaily()))
        }
    }

    func fetchDayMinuteMatrix(completion: @escaping ([String: [MinuteBucket]]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.dayMinuteMatrix())
        }
    }

    /// All parsed records, re-parsing only rollout files whose mtime/size changed.
    private func cachedRecords() -> [CodexRecord] {
        cache.records(for: Self.rolloutFiles(), parse: Self.parseFile)
    }

    /// Per-day totals.
    private func readDaily() -> [DailyUsage] {
        var byDay: [String: CodexDay] = [:]
        for r in cachedRecords() {
            byDay[DayBucket.day(epoch: r.epoch), default: CodexDay()].add(input: r.input, output: r.output,
                                                  cacheRead: r.cacheRead, model: r.model)
        }
        return byDay
            .map { $0.value.makeDailyUsage(date: $0.key) }
            .sorted { $0.date < $1.date }
    }

    /// Per-minute buckets (by type + by model) for every day with data.
    private func dayMinuteMatrix() -> [String: [MinuteBucket]] {
        var byDay: [String: [MinuteBucket]] = [:]
        for r in cachedRecords() {
            let (day, minute) = DayBucket.dayMinute(epoch: r.epoch)
            byDay[day, default: Array(repeating: MinuteBucket(), count: 1440)][minute]
                .add(input: r.input, output: r.output, cacheCreation: 0, cacheRead: r.cacheRead, model: r.model)
        }
        return byDay
    }

    /// Parse one rollout file into per-event delta records. Cumulative counters are
    /// tracked within the file; the model carries forward from the latest
    /// `turn_context`. Self-contained, so the result caches by (mtime, size).
    private static func parseFile(_ file: URL) -> [CodexRecord] {
        let decoder = JSONDecoder()
        var records: [CodexRecord] = []
        var model: String?
        var prevInput = 0, prevCached = 0, prevOutput = 0

        LineReader.forEachLine(of: file) { lineData in
            guard let line = try? decoder.decode(CodexLine.self, from: lineData) else { return }

            if line.type == "turn_context", let m = line.payload?.model {
                model = m
                return
            }

            guard line.type == "event_msg",
                  line.payload?.type == "token_count",
                  let usage = line.payload?.info?.total_token_usage,
                  let timestamp = line.timestamp,
                  let date = DayBucket.date(from: timestamp)
            else { return }

            let cached = usage.cached_input_tokens ?? 0
            // Deltas vs the previous cumulative (clamped ≥ 0 against resets).
            let deltaInput = max(0, usage.input_tokens - prevInput)
            let deltaCached = max(0, cached - prevCached)
            let deltaOutput = max(0, usage.output_tokens - prevOutput)
            prevInput = usage.input_tokens
            prevCached = cached
            prevOutput = usage.output_tokens

            records.append(CodexRecord(
                epoch: Int(date.timeIntervalSince1970),
                input: max(0, deltaInput - deltaCached),
                output: deltaOutput,
                cacheRead: deltaCached,
                model: model
            ))
        }
        return records
    }

    /// All `rollout-*.jsonl` under `~/.codex/sessions` (or `$CODEX_HOME`).
    private static func rolloutFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        let sessions = base.appendingPathComponent("sessions")

        guard let enumerator = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: nil
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            files.append(url)
        }
        return files
    }
}

// MARK: - Cached record

/// One Codex token_count event's contribution, already reduced to per-event
/// deltas and mapped to the normalized token types. Tagged with its absolute UTC
/// instant; the local day / minute is derived at read time. Short coding keys keep
/// the persisted cache compact.
private struct CodexRecord: Codable {
    let epoch: Int           // UTC seconds since 1970
    let input: Int           // non-cached input
    let output: Int
    let cacheRead: Int
    let model: String?

    enum CodingKeys: String, CodingKey {
        case epoch = "ts", input = "i", output = "o", cacheRead = "r", model = "m"
    }
}

// MARK: - Per-day accumulation

private struct CodexDay {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cost = 0.0
    var models = Set<String>()

    mutating func add(input: Int, output: Int, cacheRead: Int, model: String?) {
        self.input += input
        self.output += output
        self.cacheRead += cacheRead
        if let model { models.insert(model) }
        if let pricing = PricingStore.shared.pricing(for: model) {
            cost += pricing.cost(input: input, output: output, cacheCreation: 0, cacheRead: cacheRead)
        }
    }

    func makeDailyUsage(date: String) -> DailyUsage {
        DailyUsage(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheRead,
            totalTokens: input + output + cacheRead,
            totalCost: cost,
            models: models.sorted()
        )
    }
}

// MARK: - Tolerant rollout line shape (only the fields we read)

private struct CodexLine: Decodable {
    let type: String?
    let timestamp: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?       // event_msg payloads: "token_count", …
        let model: String?      // turn_context payloads
        let info: Info?
    }

    struct Info: Decodable {
        let total_token_usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int
        let cached_input_tokens: Int?
        let output_tokens: Int
    }
}
