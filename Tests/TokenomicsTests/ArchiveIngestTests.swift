import Testing
import Foundation
@testable import Tokenomics

/// In-memory ArchiveFolder with a write counter. Internal (not private) so the
/// UsageStore wiring tests can reuse it. Never touches the real Application Support.
final class MemoryArchiveFolder: ArchiveFolder {
    var directoryURL: URL? = URL(fileURLWithPath: "/archive")
    var files: [String: Data] = [:]
    private(set) var writeCount = 0

    func segmentURLs() -> [URL] {
        files.keys
            .filter { archiveMonth(fromSegmentName: $0) != nil }
            .sorted()
            .map { directoryURL!.appendingPathComponent($0) }
    }
    func readData(at url: URL) -> Data? { files[url.lastPathComponent] }
    func writeSegment(_ data: Data, month: String) throws {
        files[archiveSegmentName(forMonth: month)] = data
        writeCount += 1
    }
}

@Suite("ArchiveIngest")
struct ArchiveIngestTests {
    /// Mid-June 2025 — mid-month so the routed month is the same in any timezone.
    private let clock = Date(timeIntervalSince1970: 1_750_000_000)
    private var thisMonth: String { DayBucket.monthKey(clock) }

    private func archive(_ folder: MemoryArchiveFolder) -> UsageArchive {
        UsageArchive(folder: folder, machineId: "mac", displayName: { "mac" }, appVersion: "0")
    }

    private func rec(_ key: String?, output: Int = 0, daysAgo: Int = 0,
                     source: UsageSource = .claude) -> UsageRecord {
        let epoch = Int(clock.timeIntervalSince1970) - daysAgo * 86_400
        return UsageRecord(source: source, key: key, epoch: epoch, input: 1, output: output,
                           cacheCreation: 0, cacheRead: 0, model: "m")
    }

    @Test("ingests records, then reads them back")
    func ingestThenRead() {
        let folder = MemoryArchiveFolder()
        let a = archive(folder)
        a.ingest([rec("A", output: 5), rec("B", output: 3)], now: clock)
        let records = a.records(forMonths: a.availableMonths())
        #expect(records.count == 2)
        #expect(Set(records.map(\.key)) == ["A", "B"])
    }

    @Test("re-ingesting the same batch writes nothing (fingerprint fast-path)")
    func reingestFastPath() {
        let folder = MemoryArchiveFolder()
        let a = archive(folder)
        let batch = [rec("A", output: 5), rec("B", output: 3)]
        a.ingest(batch, now: clock)
        #expect(folder.writeCount == 1)
        a.ingest(batch, now: clock)
        #expect(folder.writeCount == 1)   // unchanged batch → no second write
    }

    @Test("re-ingesting after relaunch (cold instance) rewrites nothing")
    func reingestAcrossInstances() {
        let folder = MemoryArchiveFolder()
        let batch = [rec("A", output: 5), rec("B", output: 3)]
        archive(folder).ingest(batch, now: clock)
        let bytesBefore = folder.files[archiveSegmentName(forMonth: thisMonth)]
        // A fresh instance has no in-memory fingerprint; it must still find the disk
        // set unchanged and not rewrite (no updatedAt churn).
        archive(folder).ingest(batch, now: clock)
        #expect(folder.writeCount == 1)
        #expect(folder.files[archiveSegmentName(forMonth: thisMonth)] == bytesBefore)
    }

    @Test("a streamed turn whose output grows keeps the largest, not duplicates")
    func streamedOutputKeepsMax() {
        let folder = MemoryArchiveFolder()
        let a = archive(folder)
        a.ingest([rec("A", output: 1)], now: clock)
        a.ingest([rec("A", output: 9)], now: clock)
        let records = a.records(forMonths: [thisMonth])
        #expect(records.count == 1)
        #expect(records.first?.output == 9)
    }

    @Test("duplicate keyless records collapse and stay collapsed across ingests")
    func keylessIdempotent() {
        let folder = MemoryArchiveFolder()
        let keyless = rec(nil, output: 3)
        archive(folder).ingest([keyless, keyless, keyless], now: clock)
        #expect(archive(folder).records(forMonths: [thisMonth]).count == 1)
        archive(folder).ingest([keyless, keyless, keyless], now: clock)
        #expect(archive(folder).records(forMonths: [thisMonth]).count == 1)
    }

    @Test("routes records to the current and previous month segments")
    func routesCurrentAndPrevious() {
        let folder = MemoryArchiveFolder()
        let a = archive(folder)
        a.ingest([rec("J", daysAgo: 0), rec("M", daysAgo: 30)], now: clock)
        #expect(a.availableMonths().count == 2)
        #expect(Set(a.records(forMonths: a.availableMonths()).map(\.key)) == ["J", "M"])
    }

    @Test("drops records older than the previous month (captured by backfill instead)")
    func dropsOutOfWindow() {
        let folder = MemoryArchiveFolder()
        let a = archive(folder)
        a.ingest([rec("J", daysAgo: 0), rec("OLD", daysAgo: 60)], now: clock)
        #expect(a.availableMonths() == [thisMonth])
        #expect(a.records(forMonths: a.availableMonths()).map(\.key) == ["J"])
    }

    @Test("an empty batch writes nothing")
    func emptyBatch() {
        let folder = MemoryArchiveFolder()
        archive(folder).ingest([], now: clock)
        #expect(folder.writeCount == 0)
        #expect(folder.files.isEmpty)
    }
}
