import Foundation

/// Optional, user-maintained additions to Tokenomics' built-in usage-source
/// discovery. The file lives at `~/.config/tokenomics/sources.json`; missing,
/// malformed, or unsupported files simply contribute no additional roots.
enum UsageSourceConfiguration {
    static let version = 1

    struct Homes: Equatable {
        let codex: [URL]
        let claude: [URL]

        static let empty = Homes(codex: [], claude: [])
    }

    private struct FileContents: Decodable {
        let version: Int
        let additionalCodexHomes: [String]
        let additionalClaudeHomes: [String]

        enum CodingKeys: String, CodingKey {
            case version, additionalCodexHomes, additionalClaudeHomes
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            additionalCodexHomes = try values.decodeIfPresent(
                [String].self, forKey: .additionalCodexHomes) ?? []
            additionalClaudeHomes = try values.decodeIfPresent(
                [String].self, forKey: .additionalClaudeHomes) ?? []
        }
    }

    static func fileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/tokenomics/sources.json")
    }

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     from url: URL? = nil) -> Homes {
        let configURL = url ?? fileURL(home: home)
        guard let data = try? Data(contentsOf: configURL),
              let contents = try? JSONDecoder().decode(FileContents.self, from: data),
              contents.version == version else { return .empty }

        return Homes(
            codex: uniqueURLs(contents.additionalCodexHomes.compactMap { resolve($0, home: home) }),
            claude: uniqueURLs(contents.additionalClaudeHomes.compactMap { resolve($0, home: home) })
        )
    }

    /// Canonicalize before deduping so a configured symlink and its real path do not
    /// cause the same JSONL file to be parsed twice.
    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(canonical.path).inserted { result.append(canonical) }
        }
        return result
    }

    private static func resolve(_ rawPath: String, home: URL) -> URL? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)))
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
}
