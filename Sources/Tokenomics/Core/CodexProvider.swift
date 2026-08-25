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

    /// Per-file parse cache persisted one-file-per-source; the version in the
    /// directory name is the format version. Deltas are computed per file, so each
    /// file's records are self-contained and cacheable by (mtime, size).
    private let cache = FileRecordCache<UsageRecord>(
        cacheDirectoryName: "codex-records-v8",
        queueLabel: "tokenomics.codex-reader",
        legacyFiles: (3...7).map { "codex-records-v\($0).ndjson" })

    /// Raw, pre-dedup records; the union + single `Dedup.collapse` happens upstream.
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.cachedRecords())
        }
    }

    /// All parsed records, re-parsing only rollout files whose mtime/size changed.
    private func cachedRecords() -> [UsageRecord] {
        cache.records(for: Self.rolloutFiles(in: Self.codexHomes()), parse: Self.parseFile)
    }

    // MARK: - Parsing

    /// Parse one rollout file into per-turn records. The model carries forward from
    /// the latest `turn_context`; cumulative counters are tracked for the old-format
    /// fallback. Self-contained, so the result caches by (mtime, size). Internal for
    /// fixture tests.
    /// Max gap between consecutive replayed token_counts (and between the spawn
    /// timestamp and the first one). Measured: intra-block gaps stay sub-second even
    /// when the flush straddles a second; the first real turn lands ≥ 6.6s later.
    private static let replayChainGap: TimeInterval = 2

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
        // Forked / sub-agent sessions REPLAY the parent's token_count history into
        // the new file at spawn time (verified: value-identical to the parent).
        // Counting it double-bills usage the parent's file already carries. The
        // whole block flushes in milliseconds but its timestamps can straddle a
        // wall-clock second, so a fixed "first second" window under-skips (observed:
        // a 52M leak). Instead the block is a CHAIN anchored at the spawn timestamp:
        // an event is replay while it lands within `replayChainGap` of the previous
        // replayed event. Real turns need a model roundtrip — the first genuine
        // token_count arrives several seconds after the chain ends (observed ≥ 6.6s,
        // intra-block gaps < 1s), so the threshold has margin on both sides.
        var isFirstLine = true
        var skipReplay = false
        var lastReplayDate: Date?

        LineReader.forEachLine(of: file) { lineData in
            if isFirstLine {
                isFirstLine = false
                if let head = String(data: lineData, encoding: .utf8),
                   head.contains("thread_spawn") || head.contains("forked_from_id") {
                    skipReplay = true
                    // Anchor at the session_meta timestamp: replayed history starts
                    // AT spawn, while a fork with nothing to replay logs its first
                    // token_count a roundtrip later and must not be skipped.
                    if let meta = try? decoder.decode(CodexLine.self, from: lineData),
                       let ts = meta.timestamp {
                        lastReplayDate = DayBucket.date(from: ts)
                    }
                }
            }
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

            if skipReplay {
                if date.timeIntervalSince(lastReplayDate ?? date) <= Self.replayChainGap {
                    // Replayed history: don't emit, but keep the cumulative baseline
                    // so a later old-format delta stays correct.
                    lastReplayDate = date
                    prevInput = usage.input_tokens
                    prevCached = usage.cached_input_tokens ?? 0
                    prevOutput = usage.output_tokens
                    return
                }
                skipReplay = false   // first event clear of the spawn chain: real work
            }

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

    /// The standard `~/.codex` home plus `$CODEX_HOME` (when set) and any roots
    /// from `~/.config/tokenomics/sources.json`. Tokenomics aggregates local usage,
    /// so an inherited isolated environment adds a source rather than hiding the
    /// standard one.
    static func codexHomes(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalHomes: [URL]? = nil
    ) -> [URL] {
        var homes = [home.appendingPathComponent(".codex")]
        if let environmentHome = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !environmentHome.isEmpty {
            homes.append(URL(fileURLWithPath: environmentHome))
        }
        let additional = additionalHomes ?? UsageSourceConfiguration.load(home: home).codex
        return UsageSourceConfiguration.uniqueURLs(homes + additional)
    }

    /// All `rollout-*.jsonl` under every configured Codex home's `sessions/` tree.
    static func rolloutFiles(in homes: [URL]) -> [URL] {
        let fm = FileManager.default
        var files: [URL] = []
        for home in UsageSourceConfiguration.uniqueURLs(homes) {
            let sessions = home.appendingPathComponent("sessions")
            guard let enumerator = fm.enumerator(
                at: sessions, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator
            where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                files.append(url)
            }
        }
        return UsageSourceConfiguration.uniqueURLs(files).sorted { $0.path < $1.path }
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
