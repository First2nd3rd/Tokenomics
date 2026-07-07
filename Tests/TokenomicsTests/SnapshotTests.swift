import Testing
import Foundation
@testable import Tokenomics

@Suite("SnapshotFile")
struct SnapshotFileTests {
    private func day(_ date: String, frozen: Bool = true) -> DaySnapshot {
        DaySnapshot(date: date, total: TokenCounts(input: 10, output: 5, cacheCreation: 0, cacheRead: 0),
                    cost: 1.25, pricedAt: 1_750_000_000, frozen: frozen,
                    byVendor: [VendorUsage(vendor: "Claude", counts: TokenCounts(input: 10, output: 5, cacheCreation: 0, cacheRead: 0), cost: 1.25)],
                    byModel: [ModelUsage(model: "claude-opus-4-8", counts: TokenCounts(input: 10, output: 5, cacheCreation: 0, cacheRead: 0), cost: 1.25)])
    }

    @Test("round-trips the manifest and day snapshots")
    func roundTrip() throws {
        let data = SnapshotFile.encode([day("2026-06-01"), day("2026-06-02")], machineId: "mac", updatedAt: 1)
        let days = try #require(SnapshotFile.decode(data))
        #expect(days.count == 2)
        #expect(days.first?.date == "2026-06-01")
        #expect(days.first?.cost == 1.25)
        #expect(days.first?.byModel.first?.model == "claude-opus-4-8")
    }

    @Test("skips a file whose schemaVersion is newer than supported")
    func skipsNewer() throws {
        let future = SnapshotFile.Manifest(schemaVersion: SnapshotFile.schemaVersion + 1, machineId: "m", updatedAt: 1, dayCount: 0)
        var data = try JSONEncoder().encode(future)
        data.append(0x0A)
        #expect(SnapshotFile.decode(data) == nil)
    }

    @Test("skips unparseable day lines, returns nil for empty")
    func tolerant() throws {
        var data = SnapshotFile.encode([day("2026-06-01")], machineId: "m", updatedAt: 1)
        data.append(Data("not json\n".utf8))
        #expect(SnapshotFile.decode(data)?.count == 1)
        #expect(SnapshotFile.decode(Data()) == nil)
    }
}

@Suite("DaySummaries & frozen reports")
struct DaySummariesTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func rec(_ source: UsageSource = .claude, key: String?, tokens: Int,
                     model: String = "claude-opus-4-8", _ y: Int, _ m: Int, _ d: Int) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: Int(date(y, m, d).timeIntervalSince1970),
                    input: tokens, output: 0, cacheCreation: 0, cacheRead: 0, model: model)
    }

    @Test("daySummaries groups by day with per-vendor and per-model splits")
    func daySummaries() {
        let records = [
            rec(.claude, key: "a", tokens: 100, model: "claude-opus-4-8", 2026, 6, 1),
            rec(.codex, key: "x", tokens: 60, model: "gpt-5.5", 2026, 6, 1),
            rec(.claude, key: "b", tokens: 40, model: "claude-opus-4-8", 2026, 6, 2),
        ]
        let summaries = UsageAggregator.daySummaries(records, pricedAt: 123, frozen: true, calendar: cal)
        #expect(summaries.map(\.date) == ["2026-06-01", "2026-06-02"])
        let d1 = summaries[0]
        #expect(d1.total.total == 160)
        #expect(d1.frozen == true)
        #expect(d1.pricedAt == 123)
        #expect(Set(d1.byVendor.map(\.vendor)) == ["Claude", "GPT"])
        #expect(d1.byModel.count == 2)
    }

    @Test("report is frozen only when every completed day came from a snapshot")
    func pricesFrozen() {
        let juneRecords = [rec(key: "a", tokens: 100, 2026, 6, 1), rec(key: "b", tokens: 200, 2026, 6, 2)]
        let frozen = UsageAggregator.daySummaries(juneRecords, pricedAt: 0, frozen: true, calendar: cal)
        let live = UsageAggregator.daySummaries(juneRecords, pricedAt: 0, frozen: false, calendar: cal)

        let frozenReport = PeriodReport.make(daySummaries: frozen, period: .month,
                                             anchor: date(2026, 6, 15), now: date(2026, 7, 1), calendar: cal)
        #expect(frozenReport.pricesFrozen == true)
        #expect(frozenReport.total.total == 300)

        let liveReport = PeriodReport.make(daySummaries: live, period: .month,
                                           anchor: date(2026, 6, 15), now: date(2026, 7, 1), calendar: cal)
        #expect(liveReport.pricesFrozen == false)
    }

    @Test("today is excluded from the frozen check (current period stays frozen)")
    func currentPeriodFrozen() {
        let completed = UsageAggregator.daySummaries([rec(key: "a", tokens: 100, 2026, 6, 1)],
                                                     pricedAt: 0, frozen: true, calendar: cal)
        let today = UsageAggregator.daySummaries([rec(key: "t", tokens: 50, 2026, 6, 15)],
                                                 pricedAt: 0, frozen: false, calendar: cal)
        let report = PeriodReport.make(daySummaries: completed + today, period: .month,
                                       anchor: date(2026, 6, 15), now: date(2026, 6, 15), calendar: cal)
        #expect(report.isCurrent)
        #expect(report.pricesFrozen == true)   // Jun 1 frozen; today (Jun 15) excluded
    }
}

@Suite("SnapshotStore")
struct SnapshotStoreTests {
    private let clock = Date(timeIntervalSince1970: 1_750_000_000)   // mid-June 2025
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).ndjson")
    }
    private func rec(daysAgo: Int) -> UsageRecord {
        UsageRecord(source: .claude, key: "k\(daysAgo)", epoch: Int(clock.timeIntervalSince1970) - daysAgo * 86_400,
                    input: 100, output: 0, cacheCreation: 0, cacheRead: 0, model: "claude-opus-4-8")
    }

    @Test("freezes finalized days from the archive, never today")
    func freezesFinalizedDays() {
        let folder = MemoryArchiveFolder()
        let archive = UsageArchive(folder: folder, machineId: "m", displayName: { "m" }, appVersion: "0")
        archive.backfill([rec(daysAgo: 2), rec(daysAgo: 1), rec(daysAgo: 0)])   // Jun13, Jun14, today

        let store = SnapshotStore(fileURL: tempFile(), machineId: "m")
        store.refresh(now: clock, archive: archive, calendar: cal)
        let snaps = store.snapshots()
        let today = DayBucket.dayKey(clock, calendar: cal)
        #expect(snaps.count == 2)
        #expect(snaps.allSatisfy { $0.frozen })
        #expect(!snaps.map(\.date).contains(today))   // today never frozen
    }

    @Test("re-running across a fresh instance adds no duplicates")
    func idempotent() {
        let folder = MemoryArchiveFolder()
        let archive = UsageArchive(folder: folder, machineId: "m", displayName: { "m" }, appVersion: "0")
        archive.backfill([rec(daysAgo: 2), rec(daysAgo: 1)])
        let file = tempFile()

        SnapshotStore(fileURL: file, machineId: "m").refresh(now: clock, archive: archive, calendar: cal)
        let fresh = SnapshotStore(fileURL: file, machineId: "m")   // sweptForDay nil → re-sweeps
        fresh.refresh(now: clock, archive: archive, calendar: cal)
        #expect(fresh.snapshots().count == 2)
    }

    @Test("re-freezes a day whose archive later grew (midnight-straddling turn)")
    func growOnlyRefreeze() {
        let folder = MemoryArchiveFolder()
        let archive = UsageArchive(folder: folder, machineId: "m", displayName: { "m" }, appVersion: "0")
        let yesterday = Int(clock.timeIntervalSince1970) - 86_400
        let turn = UsageRecord(source: .claude, key: "T", epoch: yesterday, input: 0, output: 100,
                               cacheCreation: 0, cacheRead: 0, model: "claude-opus-4-8")
        archive.ingest([turn], now: clock)
        let file = tempFile()
        SnapshotStore(fileURL: file, machineId: "m").refresh(now: clock, archive: archive, calendar: cal)

        // The same turn's output kept growing after the day was frozen.
        let grown = UsageRecord(source: .claude, key: "T", epoch: yesterday, input: 0, output: 900,
                                cacheCreation: 0, cacheRead: 0, model: "claude-opus-4-8")
        archive.ingest([turn, grown], now: clock)
        let fresh = SnapshotStore(fileURL: file, machineId: "m")
        fresh.refresh(now: clock, archive: archive, calendar: cal)
        #expect(fresh.snapshots().first?.total.total == 900)   // updated, not stuck at 100
    }

    @Test("never shrinks a frozen day when a recompute says less")
    func neverShrinks() throws {
        let folder = MemoryArchiveFolder()
        let archive = UsageArchive(folder: folder, machineId: "m", displayName: { "m" }, appVersion: "0")
        archive.ingest([rec(daysAgo: 1)], now: clock)   // archive says 100 for yesterday
        let file = tempFile()

        // A frozen snapshot claims MORE than the archive (e.g. records the archive
        // has since lost to a partial recompute window) — it must be kept as is.
        let day = DayBucket.day(epoch: Int(clock.timeIntervalSince1970) - 86_400, calendar: cal)
        let bigger = DaySnapshot(date: day, total: TokenCounts(input: 5_000, output: 0, cacheCreation: 0, cacheRead: 0),
                                 cost: 9.9, pricedAt: 1, frozen: true, byVendor: [], byModel: [])
        try SnapshotFile.encode([bigger], machineId: "m", updatedAt: 1).write(to: file)

        let store = SnapshotStore(fileURL: file, machineId: "m")
        store.refresh(now: clock, archive: archive, calendar: cal)
        #expect(store.snapshots().first?.total.total == 5_000)   // untouched
        #expect(store.snapshots().first?.cost == 9.9)
    }
}
