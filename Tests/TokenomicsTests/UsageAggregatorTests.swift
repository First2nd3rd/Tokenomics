import Testing
import Foundation
@testable import Tokenomics

@Suite("UsageAggregator.hourlyCounts")
struct HourlyCountsTests {
    /// Fixed UTC calendar so hour buckets are deterministic on any machine.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func epoch(_ h: Int, _ min: Int = 0) -> Int {
        Int(cal.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: h, minute: min))!
            .timeIntervalSince1970)
    }
    private func rec(key: String, input: Int, epoch: Int) -> UsageRecord {
        UsageRecord(source: .claude, key: key, epoch: epoch,
                    input: input, output: 0, cacheCreation: 0, cacheRead: 0, model: "m")
    }

    @Test("buckets records into their local hour and ignores other days")
    func hourBuckets() {
        let records = [
            rec(key: "a", input: 10, epoch: epoch(9, 5)),
            rec(key: "b", input: 20, epoch: epoch(9, 55)),
            rec(key: "c", input: 30, epoch: epoch(23)),
            rec(key: "other", input: 999, epoch: epoch(9) + 86_400),   // next day
        ]
        let hours = UsageAggregator.hourlyCounts(collapsed: records, day: "2026-07-20", calendar: cal)
        #expect(hours.count == 24)
        #expect(hours[9].total == 30)
        #expect(hours[23].total == 30)
        #expect(hours.reduce(0) { $0 + $1.total } == 60)      // the other day is excluded
    }
}

@Suite("UsageAggregator")
struct UsageAggregatorTests {

    /// A fixed instant; all records share it so they land in one local day
    /// regardless of the test machine's timezone (no day-string hardcoding).
    private let E = 1_750_000_000

    private func rec(
        source: UsageSource,
        key: String?,
        input: Int = 0,
        output: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        model: String? = nil,
        epoch: Int? = nil
    ) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: epoch ?? E, input: input, output: output,
                    cacheCreation: cacheCreation, cacheRead: cacheRead, model: model)
    }

    // MARK: - vendorId

    @Test("vendorId maps sources to the break-even provider ids")
    func vendorIds() {
        #expect(UsageAggregator.vendorId(for: .claude) == "claude-native")
        #expect(UsageAggregator.vendorId(for: .codex) == "codex")
    }

    // MARK: - daily

    @Test("daily sums token fields per day and dedups a streamed-duplicate key")
    func dailySumsAndDedups() throws {
        let days = UsageAggregator.daily([
            // One streamed Claude turn logged twice (same key, growing output) → keep 50.
            rec(source: .claude, key: "A", input: 100, output: 10, cacheRead: 7, model: "m"),
            rec(source: .claude, key: "A", input: 100, output: 50, cacheRead: 7, model: "m"),
            // A distinct turn.
            rec(source: .claude, key: "B", input: 5, output: 5, model: "m"),
        ])
        #expect(days.count == 1)
        let d = try #require(days.first)
        #expect(d.inputTokens == 105)     // 100 + 5
        #expect(d.outputTokens == 55)     // 50 + 5
        #expect(d.cacheReadTokens == 7)
        #expect(d.totalTokens == 105 + 55 + 0 + 7)
    }

    @Test("daily splits distinct days and sorts ascending")
    func dailySplitsDays() {
        let twoDaysLater = E + 2 * 24 * 3600   // > 48h apart ⇒ different local day in any tz
        let days = UsageAggregator.daily([
            rec(source: .codex, key: "X:0", input: 1, model: "g", epoch: twoDaysLater),
            rec(source: .codex, key: "X:1", input: 2, model: "g", epoch: E),
        ])
        #expect(days.count == 2)
        #expect(days.map(\.date) == days.map(\.date).sorted())
    }

    @Test("daily excludes the <synthetic> model from the model list")
    func dailyExcludesSynthetic() throws {
        let days = UsageAggregator.daily([
            rec(source: .claude, key: "A", input: 1, model: "<synthetic>"),
            rec(source: .claude, key: "B", input: 1, model: "opus"),
        ])
        #expect(try #require(days.first).models == ["opus"])
    }

    // MARK: - byVendor

    @Test("byVendor groups records under the break-even provider ids")
    func byVendorSplit() {
        let v = UsageAggregator.byVendor([
            rec(source: .claude, key: "A", input: 10, output: 1, model: "m"),
            rec(source: .codex, key: "X:0", input: 20, output: 2, model: "g"),
        ])
        #expect(Set(v.keys) == ["claude-native", "codex"])
        #expect(v["claude-native"]?.first?.inputTokens == 10)
        #expect(v["codex"]?.first?.inputTokens == 20)
    }

    // MARK: - Union equivalence (the behavior-preserving guarantee)

    @Test("daily(union) equals per-source daily then merge — no drift, no double count")
    func unionEquivalence() {
        let claude = [
            rec(source: .claude, key: "A", input: 100, output: 10, model: "m1"),
            rec(source: .claude, key: "A", input: 100, output: 50, model: "m1"),  // dup, larger wins
            rec(source: .claude, key: "B", input: 5, output: 5, model: "m1"),
        ]
        let codex = [
            rec(source: .codex, key: "X:0", input: 7, output: 3, cacheRead: 2, model: "g"),
            rec(source: .codex, key: "X:1", input: 1, output: 1, model: "g"),
        ]

        let union = UsageAggregator.daily(claude + codex)
        let separate = CombinedProvider.merge([UsageAggregator.daily(claude), UsageAggregator.daily(codex)])

        #expect(union.map(\.date) == separate.map(\.date))
        for (u, s) in zip(union, separate) {
            #expect(u.inputTokens == s.inputTokens)
            #expect(u.outputTokens == s.outputTokens)
            #expect(u.cacheCreationTokens == s.cacheCreationTokens)
            #expect(u.cacheReadTokens == s.cacheReadTokens)
            #expect(u.totalTokens == s.totalTokens)
            #expect(u.totalCost == s.totalCost)
        }
    }

    @Test("an identical record arriving twice (local + peer copy) is counted once")
    func peerIdempotent() throws {
        let r = rec(source: .codex, key: "X:0", input: 10, output: 5, cacheRead: 2, model: "g")
        let once = try #require(UsageAggregator.daily([r]).first)
        let twice = try #require(UsageAggregator.daily([r, r]).first)
        #expect(once.totalTokens == twice.totalTokens)
        #expect(twice.inputTokens == 10)   // not 20
    }

    // MARK: - byMachine

    @Test("byMachine groups local (nil) records under localMachine and peers separately")
    func byMachineGroups() {
        let recs = [
            rec(source: .claude, key: "A", input: 10, model: "m"),
            rec(source: .claude, key: "B", input: 20, model: "m").with(machine: "peer-1"),
        ]
        let bm = UsageAggregator.byMachine(recs, localMachine: "this-mac")
        #expect(bm["this-mac"]?.first?.inputTokens == 10)
        #expect(bm["peer-1"]?.first?.inputTokens == 20)
    }

    @Test("byMachine dedups an identical turn shared by local and a peer (counts once)")
    func byMachineDedupsShared() {
        // Same Claude turn present locally (nil) and in a peer's file.
        let local = rec(source: .claude, key: "DUP", input: 100, output: 50, model: "m")
        let peer = local.with(machine: "peer-1")
        let bm = UsageAggregator.byMachine([local, peer], localMachine: "this-mac")
        let total = bm.values.flatMap { $0 }.reduce(0) { $0 + $1.totalTokens }
        #expect(total == 100 + 50)   // counted once across all machines, not twice
    }

    // MARK: - matrix

    @Test("splitDayMinuteMatrix keeps combined = all but local = nil-machine only")
    func splitMatrix() {
        let recs = [
            rec(source: .claude, key: "A", input: 10, model: "m"),                       // local (nil)
            rec(source: .claude, key: "B", input: 20, model: "m").with(machine: "peer"), // a peer
        ]
        let (combined, local) = UsageAggregator.splitDayMinuteMatrix(recs)
        let c = combined.values.flatMap { $0 }.reduce(0) { $0 + $1.counts.total }
        let l = local.values.flatMap { $0 }.reduce(0) { $0 + $1.counts.total }
        #expect(c == 30)   // 10 local + 20 peer
        #expect(l == 10)   // local only ⇒ the live series' true height (peer overlay = c − l)
    }

    @Test("dayMinuteMatrix buckets records with a by-model split")
    func matrixBuckets() throws {
        let m = UsageAggregator.dayMinuteMatrix([
            rec(source: .claude, key: "A", input: 10, output: 5, model: "m1"),
            rec(source: .codex, key: "X:0", input: 4, output: 1, model: "g1"),
        ])
        #expect(m.count == 1)
        let day = try #require(m.values.first)
        #expect(day.count == 1440)
        #expect(day.reduce(0) { $0 + $1.counts.total } == 10 + 5 + 4 + 1)
        let models = Set(day.flatMap { $0.byModel.keys })
        #expect(models.contains("m1"))
        #expect(models.contains("g1"))
    }
}
