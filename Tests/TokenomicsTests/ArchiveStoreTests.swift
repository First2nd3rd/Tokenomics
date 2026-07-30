import Testing
import Foundation
@testable import Tokenomics

@Suite("ArchiveStore")
struct ArchiveStoreTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func rec(_ source: UsageSource, key: String?, output: Int = 0, epoch: Int = 1_750_000_000) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: epoch, input: 1, output: output,
                    cacheCreation: 0, cacheRead: 0, model: "m")
    }

    private func write(_ folder: LocalArchiveFolder, _ records: [UsageRecord], month: String) throws {
        let data = ArchiveFile.encode(records: records, month: month, machineId: "mac-A",
                                      displayName: "My Mac", appVersion: "0.1.0", updatedAt: 1)
        try folder.writeSegment(data, month: month)
    }

    @Test("segment name round-trips and non-matching files are ignored")
    func segmentNaming() {
        #expect(archiveSegmentName(forMonth: "2026-06") == "archive-2026-06.ndjson")
        #expect(archiveMonth(fromSegmentName: "archive-2026-06.ndjson") == "2026-06")
        #expect(archiveMonth(fromSegmentName: "machine-id") == nil)
        #expect(archiveMonth(fromSegmentName: "archive-.ndjson") == nil)
        #expect(archiveMonth(fromSegmentName: "records-v3.ndjson") == nil)
    }

    @Test("writes segments and lists available months ascending")
    func listsMonths() throws {
        let folder = LocalArchiveFolder(tempDir())
        let archive = UsageArchive(folder: folder)
        try write(folder, [rec(.claude, key: "A", output: 5)], month: "2026-05")
        try write(folder, [rec(.claude, key: "B", output: 5)], month: "2026-06")
        #expect(archive.availableMonths() == ["2026-05", "2026-06"])
    }

    @Test("the segment cache serves repeat reads and is invalidated by our own writes")
    func segmentCacheInvalidation() {
        let folder = LocalArchiveFolder(tempDir())
        let archive = UsageArchive(folder: folder)
        let month = DayBucket.month(epoch: Int(Date().timeIntervalSince1970))
        let now = Int(Date().timeIntervalSince1970)

        archive.ingest([rec(.claude, key: "A", output: 5, epoch: now)])
        #expect(archive.records(forMonths: [month]).count == 1)     // populates the cache

        // A later ingest writes the segment; the cached copy must not mask it.
        archive.ingest([rec(.claude, key: "A", output: 5, epoch: now),
                        rec(.claude, key: "B", output: 7, epoch: now)])
        #expect(archive.records(forMonths: [month]).count == 2)
        #expect(archive.records(forMonths: [month]).count == 2)     // and repeat reads hold
    }

    @Test("a second instance's write over the same in-memory folder is visible to the first")
    func crossInstanceReadsStayFresh() {
        // In-memory folders can't be stat-ed, so the collapsed cache must stand
        // down entirely — otherwise instance A would keep serving its first read.
        let folder = MemoryArchiveFolder()
        let a = UsageArchive(folder: folder)
        let b = UsageArchive(folder: folder)
        let now = Int(Date().timeIntervalSince1970)
        let month = DayBucket.month(epoch: now)

        a.ingest([rec(.claude, key: "A", epoch: now)])
        #expect(a.records(forMonths: [month]).count == 1)   // primes any cache

        b.ingest([rec(.claude, key: "A", epoch: now), rec(.claude, key: "B", epoch: now)])
        #expect(a.records(forMonths: [month]).count == 2)   // must see b's write
    }

    @Test("reads records across months, collapsed once")
    func readsAcrossMonths() throws {
        let folder = LocalArchiveFolder(tempDir())
        let archive = UsageArchive(folder: folder)
        try write(folder, [rec(.claude, key: "A", output: 5)], month: "2026-05")
        try write(folder, [rec(.codex, key: "X", output: 7)], month: "2026-06")
        let records = archive.records(forMonths: ["2026-05", "2026-06"])
        #expect(records.count == 2)
        #expect(Set(records.map(\.key)) == ["A", "X"])
    }

    @Test("collapses superseded streamed-output lines to the largest output")
    func collapsesGrownOutput() throws {
        let folder = LocalArchiveFolder(tempDir())
        let archive = UsageArchive(folder: folder)
        // A streamed turn left three lines in the segment as its output grew.
        try write(folder, [rec(.claude, key: "A", output: 1),
                           rec(.claude, key: "A", output: 4),
                           rec(.claude, key: "A", output: 9)], month: "2026-06")
        let records = archive.records(forMonths: ["2026-06"])
        #expect(records.count == 1)
        #expect(records.first?.output == 9)
    }

    @Test("folds duplicate keyless records on read so a rewrite stays idempotent")
    func foldsKeylessDuplicates() throws {
        let folder = LocalArchiveFolder(tempDir())
        let archive = UsageArchive(folder: folder)
        let keyless = rec(.claude, key: nil, output: 3)
        try write(folder, [keyless, keyless, keyless], month: "2026-06")
        // Archive read folds keyless by shape...
        #expect(archive.records(forMonths: ["2026-06"]).count == 1)
        // ...while the default live collapse keeps every keyless record.
        #expect(Dedup.collapse([keyless, keyless, keyless]).count == 3)
    }

    @Test("a wholesale rewrite of a month replaces, never appends")
    func rewriteReplaces() throws {
        let folder = LocalArchiveFolder(tempDir())
        let archive = UsageArchive(folder: folder)
        try write(folder, [rec(.claude, key: "A", output: 5)], month: "2026-06")
        try write(folder, [rec(.claude, key: "B", output: 5),
                           rec(.claude, key: "C", output: 5)], month: "2026-06")
        let records = archive.records(forMonths: ["2026-06"])
        #expect(Set(records.map(\.key)) == ["B", "C"])   // A is gone
    }

    @Test("missing months read as empty, not a failure")
    func missingMonth() {
        let archive = UsageArchive(folder: LocalArchiveFolder(tempDir()))
        #expect(archive.records(forMonths: ["2026-01"]).isEmpty)
        #expect(archive.availableMonths().isEmpty)
    }
}
