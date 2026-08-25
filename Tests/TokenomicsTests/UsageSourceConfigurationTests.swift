import Foundation
import Testing
@testable import Tokenomics

@Suite("Usage source configuration")
struct UsageSourceConfigurationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenomics-sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(string.utf8).write(to: url)
    }

    @Test("loads tilde and absolute additional homes")
    func loadsAdditionalHomes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let absoluteClaude = root.appendingPathComponent("claude-work")
        let config = root.appendingPathComponent("sources.json")
        try makeDirectory(home)
        try write("""
        {
          "version": 1,
          "additionalCodexHomes": ["~/.codex-b"],
          "additionalClaudeHomes": ["\(absoluteClaude.path)"]
        }
        """, to: config)

        let homes = UsageSourceConfiguration.load(home: home, from: config)

        #expect(homes.codex == [home.appendingPathComponent(".codex-b")])
        #expect(homes.claude == [absoluteClaude])
    }

    @Test("ignores malformed, unsupported, and relative configuration")
    func ignoresInvalidConfiguration() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let malformed = root.appendingPathComponent("malformed.json")
        let unsupported = root.appendingPathComponent("unsupported.json")
        let relative = root.appendingPathComponent("relative.json")
        try write("{", to: malformed)
        try write(#"{"version":2,"additionalCodexHomes":["~/.codex-b"]}"#, to: unsupported)
        try write(#"{"version":1,"additionalCodexHomes":["relative/path"]}"#, to: relative)

        #expect(UsageSourceConfiguration.load(home: root, from: malformed) == .empty)
        #expect(UsageSourceConfiguration.load(home: root, from: unsupported) == .empty)
        #expect(UsageSourceConfiguration.load(home: root, from: relative) == .empty)
    }

    @Test("canonicalizes and deduplicates symlinked homes")
    func deduplicatesSymlinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        let config = root.appendingPathComponent("sources.json")
        try makeDirectory(real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try write("""
        {"version":1,"additionalCodexHomes":["\(real.path)","\(link.path)"]}
        """, to: config)

        let homes = UsageSourceConfiguration.load(home: root, from: config)

        #expect(homes.codex.map(\.path) == [real.path])
    }

    @Test("Codex discovers rollouts under every configured home")
    func codexMultipleHomes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent(".codex")
        let additional = root.appendingPathComponent(".codex-b")
        let first = primary.appendingPathComponent("sessions/2026/rollout-first.jsonl")
        let second = additional.appendingPathComponent("sessions/2026/rollout-second.jsonl")
        try write("{}\n", to: first)
        try write("{}\n", to: second)
        try write("{}\n", to: additional.appendingPathComponent("sessions/ignored.jsonl"))

        let homes = CodexProvider.codexHomes(
            home: root, environment: [:], additionalHomes: [additional])
        let files = CodexProvider.rolloutFiles(in: homes)

        #expect(Set(homes.map(\.path)) == Set([primary.path, additional.path]))
        #expect(Set(files.map(\.path)) == Set([first.path, second.path]))
    }

    @Test("Codex keeps the standard home when launched from an isolated environment")
    func codexEnvironmentDoesNotReplaceStandardHome() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let standard = root.appendingPathComponent(".codex")
        let isolated = root.appendingPathComponent(".codex-b")
        try makeDirectory(standard.appendingPathComponent("sessions"))
        try makeDirectory(isolated.appendingPathComponent("sessions"))

        let homes = CodexProvider.codexHomes(
            home: root,
            environment: ["CODEX_HOME": isolated.path],
            additionalHomes: [isolated]
        )

        #expect(Set(homes.map(\.path)) == Set([standard.path, isolated.path]))
    }

    @Test("Claude discovers projects under every configured home")
    func claudeMultipleHomes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent(".claude")
        let additional = root.appendingPathComponent(".claude-work")
        try makeDirectory(primary.appendingPathComponent("projects"))
        try makeDirectory(additional.appendingPathComponent("projects"))

        let roots = ClaudeNativeProvider.claudeProjectRoots(
            home: root, environment: [:], additionalHomes: [additional])

        #expect(roots == [
            primary.appendingPathComponent("projects"),
            additional.appendingPathComponent("projects"),
        ])
    }
}
