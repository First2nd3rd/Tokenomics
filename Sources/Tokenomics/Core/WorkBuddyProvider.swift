import Foundation

/// Reads WorkBuddy (Tencent's agent app) usage from `~/.workbuddy/projects/**/*.jsonl`.
///
/// WorkBuddy session logs are Claude-Code-style JSONL transcripts. Every row
/// carrying `providerData.rawUsage` is one billed API request: a turn fans out into
/// many `function_call` rows plus a closing assistant `message`, and each carries its
/// OWN request's usage (verified against real logs — prompt_tokens grows
/// monotonically across a turn's rows, so they are distinct requests, not
/// restatements of one). Mapping to the normalized model — rawUsage uses
/// OpenAI-style names, and `prompt_tokens` INCLUDES the cached portion:
///   - cacheRead     = prompt_cache_hit_tokens (or the Anthropic-style
///                     cache_read_input_tokens, whichever the backend filled)
///   - cacheCreation = prompt_cache_write_tokens / cache_creation_input_tokens
///   - input         = prompt_tokens − cacheRead − cacheCreation
///   - output        = completion_tokens (thinking tokens already included)
///
/// `providerData.messageId` is globally unique per request and survives file sync,
/// so it is the cross-machine dedup key.
///
/// This provider only PARSES; deduping and aggregation happen once, downstream, over
/// the union of all sources (`UsageAggregator`).
final class WorkBuddyProvider: UsageProvider {
    let id = "workbuddy"

    /// Fast pre-decode filters: usage rows carry `"rawUsage"` (the per-request
    /// billing block) or a `"usage":` object (the normalized fallback). The far more
    /// numerous content/snapshot rows contain neither.
    private static let rawUsageNeedle = Data("\"rawUsage\"".utf8)
    private static let usageNeedle = Data("\"usage\":".utf8)

    /// Per-file parse cache (mtime+size keyed), persisted one-file-per-source. The
    /// version in the directory name is the format version — bump it if
    /// `UsageRecord` or the parsing semantics change.
    private let cache = FileRecordCache<UsageRecord>(cacheDirectoryName: "workbuddy-records-v1",
                                                     queueLabel: "tokenomics.workbuddy-reader")

    /// Raw, pre-dedup records; the union + single `Dedup.collapse` happens upstream.
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.cachedRecords())
        }
    }

    /// All parsed records, re-parsing only files whose mtime/size changed.
    private func cachedRecords() -> [UsageRecord] {
        let files = UsageSourceConfiguration.uniqueURLs(
            Self.workBuddyProjectRoots().flatMap { ClaudeNativeProvider.jsonlFiles(under: $0) })
        return cache.records(for: files, parse: Self.parseFile)
    }

    // MARK: - Parsing

    /// Parse one session JSONL file into usage records (cross-file dedup happens
    /// later). Internal for fixture tests.
    static func parseFile(_ file: URL) -> [UsageRecord] {
        let decoder = JSONDecoder()
        var records: [UsageRecord] = []

        LineReader.forEachLine(of: file) { lineData in
            guard lineData.range(of: rawUsageNeedle) != nil
                    || lineData.range(of: usageNeedle) != nil,
                  let line = try? decoder.decode(WorkBuddyLine.self, from: lineData),
                  let stamp = line.timestamp,
                  let usage = normalizedUsage(line)
            else { return }

            // WorkBuddy stamps epoch MILLISECONDS; tolerate a seconds stamp.
            let epoch = stamp > 100_000_000_000 ? stamp / 1000 : stamp
            let requestId = line.providerData?.messageId ?? line.id
            records.append(UsageRecord(
                source: .workbuddy,
                key: requestId.map { Dedup.key("wb", $0) },
                epoch: epoch,
                input: usage.input,
                output: usage.output,
                cacheCreation: usage.cacheCreation,
                cacheRead: usage.cacheRead,
                model: line.providerData?.model ?? line.providerData?.requestModelId
            ))
        }
        return records
    }

    /// One request's token counts in the normalized shape, or nil when the row
    /// carries no usage. Prefers the per-request `rawUsage`; falls back to the
    /// normalized `message.usage`, whose `input_tokens` ALSO include the cached
    /// portion (verified equal to rawUsage.prompt_tokens on real rows).
    private static func normalizedUsage(_ line: WorkBuddyLine)
        -> (input: Int, output: Int, cacheCreation: Int, cacheRead: Int)? {
        if let raw = line.providerData?.rawUsage,
           let prompt = raw.prompt_tokens, let completion = raw.completion_tokens {
            // Backends fill either the OpenAI-style hit/write fields or the
            // Anthropic-style read/creation ones (never both nonzero on real rows);
            // max() picks whichever side is populated.
            let cacheRead = max(raw.prompt_cache_hit_tokens ?? 0, raw.cache_read_input_tokens ?? 0)
            let cacheCreation = max(raw.prompt_cache_write_tokens ?? 0,
                                    raw.cache_creation_input_tokens ?? 0)
            return (max(0, prompt - cacheRead - cacheCreation), completion, cacheCreation, cacheRead)
        }
        if let usage = line.message?.usage,
           let input = usage.input_tokens, let output = usage.output_tokens {
            let cacheRead = usage.cache_read_input_tokens ?? 0
            let cacheCreation = usage.cache_creation_input_tokens ?? 0
            return (max(0, input - cacheRead - cacheCreation), output, cacheCreation, cacheRead)
        }
        return nil
    }

    // MARK: - Discovery

    /// The `<home>/projects` directories to scan: `~/.workbuddy` plus any roots from
    /// `~/.config/tokenomics/sources.json`. Each must contain a `projects/` subdir.
    static func workBuddyProjectRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        additionalHomes: [URL]? = nil
    ) -> [URL] {
        let fm = FileManager.default
        let bases = [home.appendingPathComponent(".workbuddy")]
            + (additionalHomes ?? UsageSourceConfiguration.load(home: home).workbuddy)

        var roots: [URL] = []
        for base in UsageSourceConfiguration.uniqueURLs(bases) {
            let projects = base.appendingPathComponent("projects")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            roots.append(projects.standardizedFileURL.resolvingSymlinksInPath())
        }
        return UsageSourceConfiguration.uniqueURLs(roots)
    }
}

// MARK: - Tolerant JSONL line shape (only the fields we read)

private struct WorkBuddyLine: Decodable {
    let id: String?
    let timestamp: Int?          // epoch milliseconds
    let providerData: ProviderData?
    let message: Message?

    struct ProviderData: Decodable {
        let messageId: String?
        let model: String?
        let requestModelId: String?
        let rawUsage: RawUsage?
    }

    struct RawUsage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let prompt_cache_hit_tokens: Int?
        let prompt_cache_write_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }

    struct Message: Decodable {
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
    }
}
