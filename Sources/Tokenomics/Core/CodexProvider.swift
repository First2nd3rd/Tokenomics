import Foundation

/// Reads OpenAI Codex usage from `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// `token_count` events carry a CUMULATIVE `total_token_usage` per session. We emit
/// per-event deltas (current cumulative − previous), which naturally dedups repeated
/// events. Mapping to the normalized model:
///   - cacheRead       = cached_input_tokens
///   - input           = input_tokens − cached_input_tokens (non-cached input)
///   - output          = output_tokens (already includes reasoning tokens)
///   - cacheCreation   = 0 (Codex has no cache-creation concept)
///
/// Each record carries a dedup key = hash(rollout-file-name : event-index). The
/// filename holds the session UUID and is preserved by any file sync, so the same
/// event hashes identically on every machine. Locally each event's key is unique, so
/// the downstream collapse is a no-op; the key only does work in the cross-machine
/// union, where it prevents double-counting a rollout file that reached two machines.
///
/// This provider only PARSES; deduping, day bucketing, and cost happen once,
/// downstream, over the union of all sources (`UsageAggregator`).
final class CodexProvider: UsageProvider {
    let id = "codex"

    /// Per-file parse cache with NDJSON persistence; the version in the filename is
    /// the format version. Deltas are computed per file, so each file's records are
    /// self-contained and cacheable by (mtime, size).
    private let cache = FileRecordCache<UsageRecord>(diskFileName: "codex-records-v3.ndjson",
                                                     queueLabel: "tokenomics.codex-reader")

    /// Raw, pre-dedup records; the union + single `Dedup.collapse` happens upstream.
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.cachedRecords())
        }
    }

    /// All parsed records, re-parsing only rollout files whose mtime/size changed.
    private func cachedRecords() -> [UsageRecord] {
        cache.records(for: Self.rolloutFiles(), parse: Self.parseFile)
    }

    // MARK: - Parsing

    /// Parse one rollout file into per-event delta records. Cumulative counters are
    /// tracked within the file; the model carries forward from the latest
    /// `turn_context`. Self-contained, so the result caches by (mtime, size).
    private static func parseFile(_ file: URL) -> [UsageRecord] {
        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        var model: String?
        var prevInput = 0, prevCached = 0, prevOutput = 0
        // Stable per-event identity for cross-machine dedup: the rollout file's name
        // (carries the session UUID; preserved by file sync) + the event's ordinal.
        let session = file.lastPathComponent
        var index = 0

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

            records.append(UsageRecord(
                source: .codex,
                key: Dedup.key(session, String(index)),
                epoch: Int(date.timeIntervalSince1970),
                input: max(0, deltaInput - deltaCached),
                output: deltaOutput,
                cacheCreation: 0,
                cacheRead: deltaCached,
                model: model
            ))
            index += 1
        }
        return records
    }

    // MARK: - Discovery

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
