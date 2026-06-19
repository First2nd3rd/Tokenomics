import Testing
import Foundation
@testable import Tokenomics

@Suite("UsageRecord + Dedup")
struct UsageRecordTests {

    /// Builds a record with sensible defaults so each test states only what it cares about.
    private func rec(
        source: UsageSource = .codex,
        key: String? = nil,
        epoch: Int = 1_700_000_000,
        input: Int = 0,
        output: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        model: String? = nil
    ) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: epoch, input: input, output: output,
                    cacheCreation: cacheCreation, cacheRead: cacheRead, model: model)
    }

    // MARK: - Dedup.key

    @Test("key is deterministic for the same components (idempotent across machines)")
    func keyDeterministic() {
        #expect(Dedup.key("abc", "123") == Dedup.key("abc", "123"))
    }

    @Test("key differs when any component differs")
    func keyDistinct() {
        #expect(Dedup.key("abc", "123") != Dedup.key("abc", "124"))
        #expect(Dedup.key("abc", "123") != Dedup.key("abd", "123"))
    }

    @Test("key respects the component boundary (no concatenation collision)")
    func keyBoundary() {
        // "a" + "bc" must not hash the same as "ab" + "c" — the ":" separator guards this.
        #expect(Dedup.key("a", "bc") != Dedup.key("ab", "c"))
    }

    // MARK: - Dedup.collapse

    @Test("keeps the largest-output record among those sharing a key")
    func collapseKeepsLargestOutput() throws {
        let out = Dedup.collapse([
            rec(key: "K", output: 10),
            rec(key: "K", output: 99),
            rec(key: "K", output: 50),
        ])
        #expect(out.count == 1)
        #expect(out.first?.output == 99)
    }

    @Test("collapses identical keyed records to one (cross-machine idempotency)")
    func collapseIdempotent() throws {
        // The same Codex event arriving from two machines (e.g. a synced ~/.codex).
        let r = rec(source: .codex, key: "rollout-abc.jsonl:7", input: 5, output: 8, cacheRead: 2)
        let out = Dedup.collapse([r, r])
        #expect(out.count == 1)
        #expect(try #require(out.first) == r)
    }

    @Test("keyless records are never deduped")
    func collapseKeylessKept() {
        // Identical content but no key (a Claude line missing message.id/requestId).
        let out = Dedup.collapse([rec(key: nil, output: 1), rec(key: nil, output: 1)])
        #expect(out.count == 2)
    }

    @Test("is a no-op on all-unique keys (Codex's local case): count and sums preserved")
    func collapseUniqueKeysNoop() {
        let records = (0..<5).map { i in
            rec(source: .codex, key: Dedup.key("rollout-x.jsonl", String(i)), output: i * 10)
        }
        let out = Dedup.collapse(records)
        #expect(out.count == records.count)
        #expect(Set(out) == Set(records))
        #expect(out.reduce(0) { $0 + $1.output } == records.reduce(0) { $0 + $1.output })
    }

    @Test("returns empty for empty input")
    func collapseEmpty() {
        #expect(Dedup.collapse([]).isEmpty)
    }

    // MARK: - On-disk shape

    @Test("round-trips through JSON with the compact coding keys")
    func roundTrip() throws {
        let r = rec(source: .claude, key: "K", epoch: 1_750_000_000,
                    input: 1, output: 2, cacheCreation: 3, cacheRead: 4, model: "opus")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(UsageRecord.self, from: data)
        #expect(back == r)
    }

    @Test("Claude and Codex records persist with an identical schema")
    func identicalSchema() throws {
        let claude = rec(source: .claude, key: "K1", input: 1, output: 2,
                         cacheCreation: 3, cacheRead: 4, model: "opus")
        let codex = rec(source: .codex, key: "K2", input: 5, output: 6,
                        cacheCreation: 0, cacheRead: 7, model: "gpt-5")
        let claudeKeys = try jsonKeys(of: claude)
        let codexKeys = try jsonKeys(of: codex)
        #expect(claudeKeys == codexKeys)
        #expect(claudeKeys == ["i", "k", "m", "o", "r", "ts", "v", "w"])
    }

    @Test("source encodes to its compact vendor tag")
    func sourceTag() throws {
        let obj = try jsonObject(of: rec(source: .claude, key: "K"))
        #expect(obj["v"] as? String == "c")
        let obj2 = try jsonObject(of: rec(source: .codex, key: "K"))
        #expect(obj2["v"] as? String == "x")
    }

    // MARK: - machine dimension

    @Test("with(machine:) tags a copy and leaves the original untouched")
    func withMachineTags() {
        let r = rec(source: .codex, key: "X:0", input: 5, model: "g")
        let tagged = r.with(machine: "peer-2")
        #expect(r.machine == nil)
        #expect(tagged.machine == "peer-2")
        #expect(tagged.input == 5 && tagged.key == "X:0")   // other fields preserved
    }

    @Test("a local (nil-machine) record omits the machine key on disk")
    func localOmitsMachineKey() throws {
        #expect(!(try jsonKeys(of: rec(source: .claude, key: "K", model: "m"))).contains("h"))
    }

    @Test("decodes a legacy v3 line without the machine key as nil (no cache bump)")
    func decodesLegacyWithoutMachine() throws {
        let json = #"{"v":"c","k":"K","ts":1,"i":1,"o":2,"w":3,"r":4,"m":"opus"}"#
        let r = try JSONDecoder().decode(UsageRecord.self, from: Data(json.utf8))
        #expect(r.machine == nil)
        #expect(r.source == .claude && r.model == "opus")
    }

    @Test("a peer-tagged record round-trips its machine key")
    func peerTaggedRoundTrips() throws {
        let r = rec(source: .claude, key: "K", model: "m").with(machine: "peer-7")
        let back = try JSONDecoder().decode(UsageRecord.self, from: JSONEncoder().encode(r))
        #expect(back.machine == "peer-7")
        #expect(back == r)
    }

    // MARK: - Helpers

    private func jsonObject(of record: UsageRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(record)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonKeys(of record: UsageRecord) throws -> [String] {
        try jsonObject(of: record).keys.map { $0 }.sorted()
    }
}
