import Testing
import Foundation
@testable import Tokenomics

@Suite("WorkBuddyProvider parsing")
struct WorkBuddyProviderTests {

    private func write(_ lines: [String]) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-test-\(UUID().uuidString).jsonl")
        try? lines.joined(separator: "\n").appending("\n").data(using: .utf8)!.write(to: url)
        return url
    }

    /// A row shaped like a real WorkBuddy assistant message: `rawUsage` uses
    /// OpenAI-style names and `prompt_tokens` INCLUDES the cached portion.
    private func assistantRow(messageId: String = "msg-a", model: String = "hy3",
                              millis: Int = 1_787_728_454_590,
                              prompt: Int = 33162, completion: Int = 1071,
                              cacheHit: Int = 288) -> String {
        #"{"id":"row-\#(messageId)","timestamp":\#(millis),"type":"message","role":"assistant","status":"completed","providerData":{"messageId":"\#(messageId)","model":"\#(model)","requestModelId":"\#(model)","rawUsage":{"prompt_tokens":\#(prompt),"completion_tokens":\#(completion),"total_tokens":\#(prompt + completion),"prompt_cache_hit_tokens":\#(cacheHit),"prompt_cache_miss_tokens":\#(prompt - cacheHit),"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"prompt_cache_write_tokens":0}},"message":{"usage":{"input_tokens":\#(prompt),"output_tokens":\#(completion),"cache_read_input_tokens":\#(cacheHit)}}}"#
    }

    @Test("maps rawUsage: prompt minus cache hits becomes input")
    func rawUsageMapping() {
        let records = WorkBuddyProvider.parseFile(write([assistantRow()]))
        #expect(records.count == 1)
        #expect(records[0].source == .workbuddy)
        #expect(records[0].input == 32874)        // 33162 − 288 cached
        #expect(records[0].cacheRead == 288)
        #expect(records[0].cacheCreation == 0)
        #expect(records[0].output == 1071)
        #expect(records[0].model == "hy3")
        #expect(records[0].epoch == 1_787_728_454) // millis → seconds
    }

    @Test("a turn's function_call rows are distinct billed requests, each counted")
    func functionCallRows() {
        // Real turns fan out into many function_call rows before the closing
        // message; each carries its own request's usage.
        let file = write([
            #"{"id":"r1","timestamp":1787650000000,"type":"function_call","providerData":{"messageId":"m1","model":"deepseek-v4-flash","rawUsage":{"prompt_tokens":32477,"completion_tokens":186,"prompt_cache_hit_tokens":9984,"prompt_cache_miss_tokens":22493,"prompt_cache_write_tokens":0}}}"#,
            #"{"id":"r2","timestamp":1787650009000,"type":"function_call","providerData":{"messageId":"m2","model":"deepseek-v4-flash","rawUsage":{"prompt_tokens":34492,"completion_tokens":85,"prompt_cache_hit_tokens":30000,"prompt_cache_miss_tokens":4492,"prompt_cache_write_tokens":0}}}"#,
        ])
        let records = WorkBuddyProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records[0].input == 22493)
        #expect(records[0].cacheRead == 9984)
        #expect(records[0].output == 186)
        #expect(records.allSatisfy { $0.model == "deepseek-v4-flash" })
    }

    @Test("rows without usage (reasoning, user, snapshots) are skipped")
    func skipsNonUsageRows() {
        let file = write([
            #"{"id":"u1","timestamp":1787650000000,"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}"#,
            #"{"id":"t1","timestamp":1787650001000,"type":"reasoning","providerData":{"model":"hy3"},"content":"thinking"}"#,
            #"{"id":"s1","timestamp":1787650002000,"type":"file-history-snapshot","snapshot":{}}"#,
            assistantRow(),
        ])
        #expect(WorkBuddyProvider.parseFile(file).count == 1)
    }

    @Test("Anthropic-style rawUsage fields are honored when the backend fills those")
    func anthropicStyleRawUsage() {
        let file = write([
            #"{"id":"r1","timestamp":1787650000000,"type":"message","role":"assistant","providerData":{"messageId":"m1","model":"hy3","rawUsage":{"prompt_tokens":1000,"completion_tokens":50,"prompt_cache_hit_tokens":0,"cache_read_input_tokens":500,"cache_creation_input_tokens":200,"prompt_cache_write_tokens":0}}}"#,
        ])
        let records = WorkBuddyProvider.parseFile(file)
        #expect(records.count == 1)
        #expect(records[0].cacheRead == 500)
        #expect(records[0].cacheCreation == 200)
        #expect(records[0].input == 300)          // 1000 − 500 − 200
    }

    @Test("falls back to message.usage, whose input_tokens also include cache reads")
    func messageUsageFallback() {
        let file = write([
            #"{"id":"r1","timestamp":1787650000000,"type":"message","role":"assistant","providerData":{"messageId":"m1","model":"glm-5.2"},"message":{"usage":{"input_tokens":5000,"output_tokens":120,"cache_read_input_tokens":4000}}}"#,
        ])
        let records = WorkBuddyProvider.parseFile(file)
        #expect(records.count == 1)
        #expect(records[0].input == 1000)         // 5000 − 4000 cached
        #expect(records[0].cacheRead == 4000)
        #expect(records[0].output == 120)
        #expect(records[0].model == "glm-5.2")
    }

    @Test("messageId keys are stable and dedup a re-presented row")
    func stableDedupKeys() {
        let file = write([assistantRow(), assistantRow()])
        let records = WorkBuddyProvider.parseFile(file)
        #expect(records.count == 2)
        #expect(records[0].key != nil)
        #expect(records[0].key == records[1].key)
        #expect(Dedup.collapse(records).count == 1)
        // Re-parsing yields identical keys (cross-machine idempotence).
        #expect(WorkBuddyProvider.parseFile(file).map(\.key) == records.map(\.key))
    }

    @Test("a seconds-resolution timestamp is not divided again")
    func secondsTimestamp() {
        let file = write([assistantRow(millis: 1_787_728_454)])
        #expect(WorkBuddyProvider.parseFile(file)[0].epoch == 1_787_728_454)
    }

    @Test("workbuddy records aggregate under their own vendor")
    func vendorMapping() {
        #expect(UsageAggregator.vendorId(for: .workbuddy) == "workbuddy")
        #expect(Vendor.workbuddy.providerID == "workbuddy")
        #expect(Vendor.workbuddy.displayName == "WorkBuddy")

        let records = WorkBuddyProvider.parseFile(write([assistantRow()]))
        let byVendor = UsageAggregator.byVendor(records)
        #expect(byVendor.keys.contains("workbuddy"))
        #expect(byVendor["workbuddy"]?.first?.totalTokens == 34233)
    }

    @Test("discovers project logs under every configured home")
    func multipleHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-homes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent(".workbuddy")
        let additional = root.appendingPathComponent(".workbuddy-b")
        let first = primary.appendingPathComponent("projects/p1/session.jsonl")
        let second = additional.appendingPathComponent("projects/p2/nested/session.jsonl")
        for url in [first, second] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: url)
        }

        let roots = WorkBuddyProvider.workBuddyProjectRoots(
            home: root, additionalHomes: [additional])
        let files = roots.flatMap { ClaudeNativeProvider.jsonlFiles(under: $0) }

        // Discovery canonicalizes (/var → /private/var), so compare resolved paths.
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        #expect(roots.map(\.path) == [
            resolved(primary.appendingPathComponent("projects")),
            resolved(additional.appendingPathComponent("projects")),
        ])
        #expect(Set(files.map { resolved($0) }) == Set([resolved(first), resolved(second)]))
    }

    @Test("sources.json can add WorkBuddy homes")
    func configuredHomes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("sources.json")
        try Data(#"{"version":1,"additionalWorkbuddyHomes":["~/.workbuddy-b"]}"#.utf8)
            .write(to: config)

        let homes = UsageSourceConfiguration.load(home: root, from: config)
        #expect(homes.workbuddy == [root.appendingPathComponent(".workbuddy-b")])
        #expect(homes.codex.isEmpty)
    }
}
