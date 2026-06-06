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
final class CodexProvider: UsageProvider {
    let id = "codex"

    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(.success(Self.readDaily()))
        }
    }

    static func readDaily() -> [DailyUsage] {
        let decoder = JSONDecoder()
        var byDay: [String: CodexDay] = [:]

        for file in rolloutFiles() {
            guard let data = try? Data(contentsOf: file) else { continue }

            var model: String?
            var prevInput = 0, prevCached = 0, prevOutput = 0

            for lineSlice in data.split(separator: 0x0A) where !lineSlice.isEmpty {
                guard let line = try? decoder.decode(CodexLine.self, from: Data(lineSlice)) else { continue }

                if line.type == "turn_context", let m = line.payload?.model {
                    model = m
                    continue
                }

                guard line.type == "event_msg",
                      line.payload?.type == "token_count",
                      let usage = line.payload?.info?.total_token_usage,
                      let timestamp = line.timestamp,
                      let day = DayBucket.localDay(from: timestamp)
                else { continue }

                let cached = usage.cached_input_tokens ?? 0
                // Deltas vs the previous cumulative (clamped ≥ 0 against resets).
                let deltaInput = max(0, usage.input_tokens - prevInput)
                let deltaCached = max(0, cached - prevCached)
                let deltaOutput = max(0, usage.output_tokens - prevOutput)
                prevInput = usage.input_tokens
                prevCached = cached
                prevOutput = usage.output_tokens

                byDay[day, default: CodexDay()].add(
                    input: max(0, deltaInput - deltaCached),
                    output: deltaOutput,
                    cacheRead: deltaCached,
                    model: model
                )
            }
        }

        return byDay
            .map { $0.value.makeDailyUsage(date: $0.key) }
            .sorted { $0.date < $1.date }
    }

    /// All `rollout-*.jsonl` under `~/.codex/sessions` (or `$CODEX_HOME`).
    static func rolloutFiles() -> [URL] {
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
