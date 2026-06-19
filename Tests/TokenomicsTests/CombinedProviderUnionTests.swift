import Testing
import Foundation
@testable import Tokenomics

/// A provider that returns a fixed record list — exercises the record-level union
/// without touching the filesystem.
private struct StubProvider: UsageProvider {
    let id: String
    let records: [UsageRecord]
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) { completion(records) }
}

@Suite("CombinedProvider union")
struct CombinedProviderUnionTests {

    private let E = 1_750_000_000

    private func rec(_ source: UsageSource, key: String?, input: Int = 0, output: Int = 0,
                     cacheRead: Int = 0, model: String? = nil) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: E, input: input, output: output,
                    cacheCreation: 0, cacheRead: cacheRead, model: model)
    }

    /// Runs a callback-based fetch to completion synchronously.
    private func resolve<T>(_ fetch: (@escaping (T) -> Void) -> Void) -> T {
        let sem = DispatchSemaphore(value: 0)
        var out: T!
        fetch { out = $0; sem.signal() }
        sem.wait()
        return out
    }

    @Test("fetchRecords concatenates children's raw records without collapsing")
    func unionConcatenatesRaw() {
        let a = StubProvider(id: "a", records: [rec(.claude, key: "DUP", input: 100, output: 50, model: "m")])
        let b = StubProvider(id: "b", records: [rec(.claude, key: "DUP", input: 100, output: 50, model: "m")])
        let union: [UsageRecord] = resolve { CombinedProvider([a, b]).fetchRecords(completion: $0) }
        // Raw union keeps both copies; dedup is the aggregator's job, not this layer's.
        #expect(union.count == 2)
    }

    @Test("a duplicate key across two children is counted once (mirror-sync / peer copy)")
    func crossChildDedup() throws {
        // The same Claude turn present under two sources (e.g. a mirror-synced ~/.claude).
        let dup = rec(.claude, key: "DUP", input: 100, output: 50, model: "m")
        let a = StubProvider(id: "a", records: [dup])
        let b = StubProvider(id: "b", records: [dup])

        let byVendor: [String: [DailyUsage]] = resolve { CombinedProvider([a, b]).fetchDailyByVendor(completion: $0) }
        let claude = try #require(byVendor["claude-native"]?.first)
        #expect(claude.inputTokens == 100)   // once, not 200
        #expect(claude.outputTokens == 50)
    }

    @Test("by-vendor keys are the provider ids the break-even view expects")
    func vendorKeysPreserved() {
        let claude = StubProvider(id: "a", records: [rec(.claude, key: "A", input: 1, model: "m")])
        let codex = StubProvider(id: "b", records: [rec(.codex, key: "X:0", input: 2, model: "g")])
        let byVendor: [String: [DailyUsage]] = resolve { CombinedProvider([claude, codex]).fetchDailyByVendor(completion: $0) }
        #expect(Set(byVendor.keys) == ["claude-native", "codex"])
    }

    @Test("distinct sources are summed in the combined matrix, deduped once")
    func matrixUnion() throws {
        let claude = StubProvider(id: "a", records: [rec(.claude, key: "A", input: 10, output: 5, model: "m")])
        // Same Codex event from two children → must count once.
        let ev = rec(.codex, key: "X:0", input: 4, output: 1, model: "g")
        let codex1 = StubProvider(id: "b", records: [ev])
        let codex2 = StubProvider(id: "c", records: [ev])

        let matrix: [String: [MinuteBucket]] = resolve {
            CombinedProvider([claude, codex1, codex2]).fetchDayMinuteMatrix(completion: $0)
        }
        let day = try #require(matrix.values.first)
        // claude 15 + codex 5 (the codex event counted ONCE despite two children).
        #expect(day.reduce(0) { $0 + $1.counts.total } == 15 + 5)
    }
}
