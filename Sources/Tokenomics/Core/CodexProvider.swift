import Foundation

/// Reads OpenAI Codex usage from `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// `token_count` events carry the turn's own usage in `last_token_usage` plus a
/// session-cumulative `total_token_usage`. We count PER-TURN usage: some turns
/// (parallel review / sub-agent threads in newer CLIs) report `last_token_usage`
/// WITHOUT advancing the session cumulative, so summing cumulative deltas silently
/// undercounts — per-turn sums match `ccusage codex` exactly. Old rollouts without
/// `last_token_usage` fall back to cumulative deltas. Mapping to the normalized
/// model:
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
    private let cache = FileRecordCache<UsageRecord>(diskFileName: "codex-records-v5.ndjson",
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

    /// Parse one rollout file into per-turn records. The model carries forward from
    /// the latest `turn_context`; cumulative counters are tracked for the old-format
    /// fallback. Self-contained, so the result caches by (mtime, size). Internal for
    /// fixture tests.
    static func parseFile(_ file: URL) -> [UsageRecord] {
        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        var model: String?
        var firstModel: String?
        var prevInput = 0, prevCached = 0, prevOutput = 0
        // Stable per-event identity for cross-machine dedup: the rollout file's name
        // (carries the session UUID; preserved by file sync) + the event's ordinal.
        let session = file.lastPathComponent
        var index = 0
        var seenEvents = Set<String>()

        LineReader.forEachLine(of: file) { lineData in
            guard let line = try? decoder.decode(CodexLine.self, from: lineData) else { return }

            if line.type == "turn_context", let m = line.payload?.model {
                model = m
                if firstModel == nil { firstModel = m }
                return
            }

            guard line.type == "event_msg",
                  line.payload?.type == "token_count",
                  let info = line.payload?.info,
                  let usage = info.total_token_usage,
                  let timestamp = line.timestamp,
                  let date = DayBucket.date(from: timestamp)
            else { return }

            // Parallel-session rollouts occasionally write the SAME token_count
            // twice (identical timestamp, per-turn, and cumulative counts). Counting
            // both would double-bill the turn — skip literal re-emissions, as
            // `ccusage codex` does.
            let turnSig = info.last_token_usage.map {
                "\($0.input_tokens)|\($0.cached_input_tokens ?? 0)|\($0.output_tokens)"
            } ?? "-"
            let signature = "\(timestamp)|\(usage.input_tokens)|\(usage.cached_input_tokens ?? 0)|" +
                            "\(usage.output_tokens)|\(turnSig)"
            guard seenEvents.insert(signature).inserted else { return }

            let input: Int, cachedRead: Int, output: Int
            if let turn = info.last_token_usage {
                // Per-turn usage. A sub-turn (parallel review thread) reports here
                // without advancing the cumulative, so this is the complete count.
                cachedRead = turn.cached_input_tokens ?? 0
                input = max(0, turn.input_tokens - cachedRead)
                output = turn.output_tokens
            } else {
                // Old rollouts: cumulative only; per-event deltas (clamped ≥ 0
                // against resets).
                let cached = usage.cached_input_tokens ?? 0
                let deltaInput = max(0, usage.input_tokens - prevInput)
                let deltaCached = max(0, cached - prevCached)
                input = max(0, deltaInput - deltaCached)
                cachedRead = deltaCached
                output = max(0, usage.output_tokens - prevOutput)
            }
            // Track the cumulative unconditionally so a mixed file stays consistent.
            prevInput = usage.input_tokens
            prevCached = usage.cached_input_tokens ?? 0
            prevOutput = usage.output_tokens

            records.append(UsageRecord(
                source: .codex,
                key: Dedup.key(session, String(index)),
                epoch: Int(date.timeIntervalSince1970),
                input: input,
                output: output,
                cacheCreation: 0,
                cacheRead: cachedRead,
                model: model
            ))
            index += 1
        }
        // Events logged before the file's first turn_context carry no model. They
        // belong to the same session, so attribute them to its first declared model
        // (ccusage instead labels this bucket with a hardcoded "gpt-5" fallback).
        if let firstModel {
            records = records.map { r in
                r.model != nil ? r : UsageRecord(
                    source: r.source, key: r.key, epoch: r.epoch, input: r.input, output: r.output,
                    cacheCreation: r.cacheCreation, cacheRead: r.cacheRead, model: firstModel)
            }
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
        let last_token_usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int
        let cached_input_tokens: Int?
        let output_tokens: Int
    }
}
