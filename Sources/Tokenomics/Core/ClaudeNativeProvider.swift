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
/// Cost is intentionally NOT computed yet (totalCost = 0); tokens only for now.
final class ClaudeNativeProvider: UsageProvider {
    let id = "claude-native"

    func fetchDaily(completion: @escaping (Result<[DailyUsage], Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                completion(.success(try Self.readDaily()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - Reading

    static func readDaily() throws -> [DailyUsage] {
        let files = claudeProjectRoots().flatMap { jsonlFiles(under: $0) }
        let decoder = JSONDecoder()

        // One assistant turn is written as several JSONL lines (one per content
        // block) that share `message.id:requestId` and identical input/cache, but a
        // STREAMING output_tokens that grows to its final value on the last line.
        // So per message we keep the representative with the largest output_tokens.
        // Lines missing either id can't be deduped (kept individually, like ccusage).
        var best: [String: Entry] = [:]
        var keyless: [Entry] = []

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for lineSlice in data.split(separator: 0x0A) where !lineSlice.isEmpty {
                guard let line = try? decoder.decode(Line.self, from: Data(lineSlice)),
                      let usage = line.message?.usage,
                      let input = usage.input_tokens,
                      let output = usage.output_tokens,
                      let timestamp = line.timestamp,
                      let day = localDay(from: timestamp)
                else { continue }

                let entry = Entry(
                    day: day,
                    input: input,
                    output: output,
                    cacheCreation: usage.cache_creation_input_tokens ?? 0,
                    cacheRead: usage.cache_read_input_tokens ?? 0,
                    model: line.message?.model
                )

                if let id = line.message?.id, let requestId = line.requestId {
                    let key = id + ":" + requestId
                    if let existing = best[key], existing.output >= output { continue }
                    best[key] = entry
                } else {
                    keyless.append(entry)
                }
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

    // MARK: - Date helpers

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// UTC ISO-8601 timestamp -> local "yyyy-MM-dd" (matching ccusage's local bucketing).
    static func localDay(from timestamp: String) -> String? {
        guard let date = isoFractional.date(from: timestamp) ?? isoPlain.date(from: timestamp)
        else { return nil }
        return dayFormatter.string(from: date)
    }
}

// MARK: - Per-day accumulation

/// A single deduplicated message's usage, tagged with its local day.
private struct Entry {
    let day: String
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int
    let model: String?
}

private struct DayAccumulator {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var models = Set<String>()

    mutating func add(_ entry: Entry) {
        input += entry.input
        output += entry.output
        cacheCreation += entry.cacheCreation
        cacheRead += entry.cacheRead
        if let model = entry.model, model != "<synthetic>" { models.insert(model) }
    }

    func makeDailyUsage(date: String) -> DailyUsage {
        DailyUsage(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            totalTokens: input + output + cacheCreation + cacheRead,
            totalCost: 0,                       // cost not computed yet
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
    }
}
