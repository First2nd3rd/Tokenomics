import Foundation

/// Reads Claude Code usage directly from the local JSONL logs — no ccusage / Node.
///
/// Mirrors ccusage's behaviour so per-day token totals match exactly:
///   - discovers config dirs the same way ($CLAUDE_CONFIG_DIR, else ~/.config/claude
///     then ~/.claude; each must contain a `projects/` subdir)
///   - globs `projects/**/*.jsonl` at ALL depths (so nested subagent/workflow logs
///     are included, matching ccusage)
///   - keeps lines carrying `message.usage` with input/output token counts
///   - tags each record with a `message.id:requestId` dedup key (null => never
///     deduped, always counted)
///   - stores the UTC instant; the local day and cost are derived at read time by
///     `UsageAggregator`.
///
/// This provider only PARSES; deduping and aggregation happen once, downstream, over
/// the union of all sources.
final class ClaudeNativeProvider: UsageProvider {
    let id = "claude-native"

    private static let usageNeedle = Data("input_tokens".utf8)

    /// Per-file parse cache (mtime+size keyed), persisted one-file-per-source. The
    /// version in the directory name is the format version — bump it if
    /// `UsageRecord` or the parsing semantics change.
    private let cache = FileRecordCache<UsageRecord>(cacheDirectoryName: "records-v4",
                                                     queueLabel: "tokenomics.claude-reader",
                                                     legacyFiles: ["records-v3.ndjson"])

    /// Raw, pre-dedup records; the union + single `Dedup.collapse` happens upstream.
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.cachedRecords())
        }
    }

    /// All parsed records, re-parsing only files whose mtime/size changed; unchanged
    /// files reuse cached records, so the recurring refresh stays cheap once warm.
    private func cachedRecords() -> [UsageRecord] {
        let files = UsageSourceConfiguration.uniqueURLs(
            Self.claudeProjectRoots().flatMap { Self.jsonlFiles(under: $0) })
        return cache.records(for: files, parse: Self.parseFile)
    }

    // MARK: - Parsing

    /// Parse one JSONL file into usage records (cross-file dedup happens later).
    private static func parseFile(_ file: URL) -> [UsageRecord] {
        let decoder = JSONDecoder()
        var records: [UsageRecord] = []

        LineReader.forEachLine(of: file) { lineData in
            // Fast path: only assistant usage lines contain "input_tokens" — skip the
            // far more numerous user/tool/thinking lines before the JSON decode.
            guard lineData.range(of: usageNeedle) != nil,
                  let line = try? decoder.decode(Line.self, from: lineData),
                  let usage = line.message?.usage,
                  let input = usage.input_tokens,
                  let output = usage.output_tokens,
                  let timestamp = line.timestamp,
                  let date = DayBucket.date(from: timestamp)
            else { return }

            // ccusage tags "fast" (priority-tier) turns by appending "-fast" to the
            // model name, which carries the 6x price; mirror that here.
            var model = line.message?.model
            if usage.speed == "fast", let base = model { model = base + "-fast" }

            // Globally-unique, idempotent dedup key; nil when the line lacks the ids
            // (then it can't be deduped and is always counted).
            var key: String?
            if let id = line.message?.id, let requestId = line.requestId {
                key = Dedup.key(id, requestId)
            }

            records.append(UsageRecord(
                source: .claude,
                key: key,
                epoch: Int(date.timeIntervalSince1970),
                input: input,
                output: output,
                cacheCreation: usage.cache_creation_input_tokens ?? 0,
                cacheRead: usage.cache_read_input_tokens ?? 0,
                model: model
            ))
        }
        return records
    }

    // MARK: - Discovery

    /// The `<base>/projects` directories to scan, mirroring ccusage's resolution.
    static func claudeProjectRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        additionalHomes: [URL]? = nil
    ) -> [URL] {
        let fm = FileManager.default

        var bases: [URL] = []
        if let configDir = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
           !configDir.isEmpty {
            bases = configDir.split(separator: ",")
                .map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        } else {
            let xdg = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".config")
            bases = [xdg.appendingPathComponent("claude"), home.appendingPathComponent(".claude")]
        }
        bases.append(contentsOf: additionalHomes ?? UsageSourceConfiguration.load(home: home).claude)

        var roots: [URL] = []
        for base in UsageSourceConfiguration.uniqueURLs(bases) {
            let projects = base.appendingPathComponent("projects")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue else { continue }
            roots.append(projects.standardizedFileURL.resolvingSymlinksInPath())
        }
        return UsageSourceConfiguration.uniqueURLs(roots)
    }

    /// All `*.jsonl` under `projects`, recursing into nested subagent/workflow dirs.
    static func jsonlFiles(under projects: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: nil
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

}

// MARK: - Tolerant JSONL line shape (only the fields we read)

private struct Line: Decodable {
    let timestamp: String?
    let requestId: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
        let speed: String?          // "fast" => priority-tier pricing
    }
}
