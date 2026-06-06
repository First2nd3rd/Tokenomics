import Foundation

/// Reads Claude Code usage directly from the local JSONL logs — no ccusage / Node.
///
/// Mirrors ccusage's behaviour so per-day token totals match exactly:
///   - discovers config dirs the same way ($CLAUDE_CONFIG_DIR, else ~/.config/claude
///     then ~/.claude; each must contain a `projects/` subdir)
///   - globs `projects/**/*.jsonl` at ALL depths (so nested subagent/workflow logs
///     are included, matching ccusage)
///   - keeps lines carrying `message.usage` with input/output token counts
///   - dedups by `message.id:requestId` (null key => never deduped, always counted)
///   - buckets each line by its `timestamp` converted to the LOCAL calendar day
///
/// Cost is computed per message from the bundled `Pricing` table (same formula
/// and LiteLLM-sourced prices as ccusage) and summed per day.
final class ClaudeNativeProvider: UsageProvider {
    let id = "claude-native"

    private static let usageNeedle = Data("input_tokens".utf8)

    /// Serializes reads and guards `fileCache` (no concurrent refreshes).
    private let queue = DispatchQueue(label: "tokenomics.claude-reader", qos: .utility)
    /// path -> parsed records, reused while the file's mtime + size are unchanged.
    private var fileCache: [String: CachedFile] = [:]

    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void) {
        queue.async {
            completion(.success(self.readDaily()))
        }
    }

    // MARK: - Reading

    /// Aggregates per-day usage, re-parsing only files whose mtime/size changed
    /// since the last call; unchanged files reuse their cached records. This keeps
    /// the recurring 60s refresh cheap once the first full scan is warm.
    private func readDaily() -> [DailyUsage] {
        let files = Self.claudeProjectRoots().flatMap { Self.jsonlFiles(under: $0) }
        let fm = FileManager.default

        var nextCache: [String: CachedFile] = [:]
        var records: [Record] = []

        for file in files {
            let path = file.path
            let attrs = try? fm.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? Int) ?? -1

            let cached: CachedFile
            if let hit = fileCache[path], hit.mtime == mtime, hit.size == size {
                cached = hit
            } else {
                cached = CachedFile(mtime: mtime, size: size, records: Self.parseFile(file))
            }
            nextCache[path] = cached
            records.append(contentsOf: cached.records)
        }
        fileCache = nextCache   // entries for deleted files fall away

        return Self.aggregate(records)
    }

    /// Parse one JSONL file into usage records (cross-file dedup happens later).
    private static func parseFile(_ file: URL) -> [Record] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        var records: [Record] = []

        for lineSlice in data.split(separator: 0x0A) where !lineSlice.isEmpty {
            let lineData = Data(lineSlice)
            // Fast path: only assistant usage lines contain "input_tokens" — skip the
            // far more numerous user/tool/thinking lines before the JSON decode.
            guard lineData.range(of: usageNeedle) != nil,
                  let line = try? decoder.decode(Line.self, from: lineData),
                  let usage = line.message?.usage,
                  let input = usage.input_tokens,
                  let output = usage.output_tokens,
                  let timestamp = line.timestamp,
                  let day = DayBucket.localDay(from: timestamp)
            else { continue }

            // ccusage tags "fast" (priority-tier) turns by appending "-fast" to the
            // model name, which carries the 6x price; mirror that here.
            var model = line.message?.model
            if usage.speed == "fast", let base = model { model = base + "-fast" }

            let entry = Entry(
                day: day,
                input: input,
                output: output,
                cacheCreation: usage.cache_creation_input_tokens ?? 0,
                cacheRead: usage.cache_read_input_tokens ?? 0,
                model: model
            )

            var key: String?
            if let id = line.message?.id, let requestId = line.requestId {
                key = id + ":" + requestId
            }
            records.append(Record(key: key, entry: entry))
        }
        return records
    }

    /// Cross-file dedup (keep the largest-output line per message) + per-day totals.
    private static func aggregate(_ records: [Record]) -> [DailyUsage] {
        // One assistant turn spans several JSONL lines sharing `message.id:requestId`
        // with identical input/cache but a growing output_tokens; keep the largest.
        // Lines missing either id can't be deduped (kept individually, like ccusage).
        var best: [String: Entry] = [:]
        var keyless: [Entry] = []
        for record in records {
            if let key = record.key {
                if let existing = best[key], existing.output >= record.entry.output { continue }
                best[key] = record.entry
            } else {
                keyless.append(record.entry)
            }
        }

        var byDay: [String: DayAccumulator] = [:]
        for entry in best.values { byDay[entry.day, default: DayAccumulator()].add(entry) }
        for entry in keyless     { byDay[entry.day, default: DayAccumulator()].add(entry) }

        return byDay
            .map { $0.value.makeDailyUsage(date: $0.key) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Discovery

    /// The `<base>/projects` directories to scan, mirroring ccusage's resolution.
    static func claudeProjectRoots() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment

        var bases: [URL] = []
        if let configDir = env["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
           !configDir.isEmpty {
            bases = configDir.split(separator: ",")
                .map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
        } else {
            let xdg = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".config")
            bases = [xdg.appendingPathComponent("claude"), home.appendingPathComponent(".claude")]
        }

        var seen = Set<String>()
        var roots: [URL] = []
        for base in bases {
            let projects = base.appendingPathComponent("projects")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let key = projects.standardizedFileURL.path
            if seen.insert(key).inserted { roots.append(projects) }
        }
        return roots
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

// MARK: - Per-day accumulation

/// A single message's usage, tagged with its local day.
private struct Entry {
    let day: String
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int
    let model: String?
}

/// One usage line's contribution plus its dedup key (nil = can't be deduped).
private struct Record {
    let key: String?
    let entry: Entry
}

/// Cached parse result for a file, valid while its mtime + size are unchanged.
private struct CachedFile {
    let mtime: Date
    let size: Int
    let records: [Record]
}

private struct DayAccumulator {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var cost = 0.0
    var models = Set<String>()

    mutating func add(_ entry: Entry) {
        input += entry.input
        output += entry.output
        cacheCreation += entry.cacheCreation
        cacheRead += entry.cacheRead
        if let model = entry.model, model != "<synthetic>" { models.insert(model) }
        // Cost is per-message (each model has its own prices), summed per day.
        if let pricing = PricingStore.shared.pricing(for: entry.model) {
            cost += pricing.cost(input: entry.input, output: entry.output,
                                 cacheCreation: entry.cacheCreation, cacheRead: entry.cacheRead)
        }
    }

    func makeDailyUsage(date: String) -> DailyUsage {
        DailyUsage(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            totalTokens: input + output + cacheCreation + cacheRead,
            totalCost: cost,
            models: models.sorted()
        )
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
