import Testing
import Foundation
@testable import Tokenomics

/// A provider that returns a fixed record list.
private struct FixedProvider: UsageProvider {
    let id = "claude-native"
    let records: [UsageRecord]
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) { completion(records) }
}

/// Local noon on a fixed day, so ± a few hours never crosses a day boundary.
private func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func rec(_ key: String?, at date: Date, input: Int, output: Int = 0,
                 source: UsageSource = .claude) -> UsageRecord {
    UsageRecord(source: source, key: key, epoch: Int(date.timeIntervalSince1970),
                input: input, output: output, cacheCreation: 0, cacheRead: 0, model: "m")
}

private func snapshot(_ date: Date, tokens: Int, cost: Double, frozen: Bool = true) -> DaySnapshot {
    let counts = TokenCounts(input: tokens, output: 0, cacheCreation: 0, cacheRead: 0)
    return DaySnapshot(date: DayBucket.dayKey(date), total: counts, cost: cost,
                       pricedAt: 1, frozen: frozen,
                       byVendor: [VendorUsage(vendor: "Claude", counts: counts, cost: cost)],
                       byModel: [ModelUsage(model: "m", counts: counts, cost: cost)])
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tok-import-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes an export laid out like the real one: `<root>/me.stfang.tokenomics/`
/// holding `archive/`, `snapshots.ndjson`, and `machine-id` (or those directly
/// under `root` when `nested` is false).
@discardableResult
private func writeExport(at root: URL, machineId: String = "MBP", name: String = "Work MBP",
                         records: [UsageRecord], snapshots: [DaySnapshot] = [],
                         machineIdFile: String? = "MBP", nested: Bool = true,
                         updatedAt: Int = 100) -> URL {
    let data = nested ? root.appendingPathComponent(AppPaths.bundleID, isDirectory: true) : root
    let archiveDir = data.appendingPathComponent("archive", isDirectory: true)
    try? FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
    for (month, group) in Dictionary(grouping: records, by: { DayBucket.month(epoch: $0.epoch) }) {
        let bytes = ArchiveFile.encode(records: group, month: month, machineId: machineId,
                                       displayName: name, appVersion: "0.1.0", updatedAt: updatedAt)
        try? bytes.write(to: archiveDir.appendingPathComponent(archiveSegmentName(forMonth: month)))
    }
    if !snapshots.isEmpty {
        try? SnapshotFile.encode(snapshots, machineId: machineId, updatedAt: 100)
            .write(to: data.appendingPathComponent("snapshots.ndjson"))
    }
    if let machineIdFile {
        try? machineIdFile.write(to: data.appendingPathComponent("machine-id"), atomically: true, encoding: .utf8)
    }
    return data
}

@Suite("Imported history")
struct ImportedHistoryTests {
    private let dayA = noon(2025, 6, 10)
    private let dayB = noon(2025, 6, 11)
    private let clock = noon(2025, 6, 18)

    // MARK: - Import

    @Test("imports the archive and frozen days, freezing any day the export never froze")
    func importsArchiveAndSnapshots() throws {
        let export = tempDir(), root = tempDir()
        writeExport(at: export,
                    records: [rec("A1", at: dayA, input: 10), rec("A2", at: dayA, input: 5),
                              rec("B1", at: dayB, input: 7)],
                    snapshots: [snapshot(dayA, tokens: 15, cost: 1.5)])

        let summary = try ImportedHistory.importExport(from: export, into: root,
                                                       localMachineId: "AIR", now: clock)
        #expect(summary.machineId == "MBP")
        #expect(summary.displayName == "Work MBP")
        #expect(summary.recordCount == 3)
        #expect(summary.snapshotDays == 2)
        #expect(summary.frozenAtImport == [DayBucket.dayKey(dayB)])
        #expect(summary.overlapWithLocal == 0)

        let machines = ImportedHistory.load(root: root)
        #expect(machines.count == 1)
        let machine = try #require(machines.first)
        #expect(machine.displayName == "Work MBP")
        #expect(Set(machine.archive.allRecords().compactMap(\.key)) == ["A1", "A2", "B1"])
        let frozen = machine.snapshots.snapshots()
        #expect(frozen.map(\.date) == [DayBucket.dayKey(dayA), DayBucket.dayKey(dayB)])
        #expect(frozen.allSatisfy { $0.frozen })
        #expect(frozen.first?.cost == 1.5)                 // the export's historical cost, verbatim
        #expect(ImportedHistory.infos(root: root).map(\.displayName) == ["Work MBP"])
    }

    @Test("keeps the export's frozen day when it holds more than its archive")
    func keepsLargerExportSnapshot() throws {
        let export = tempDir(), root = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10)],
                    snapshots: [snapshot(dayA, tokens: 12, cost: 3)])   // froze from the logs

        let summary = try ImportedHistory.importExport(from: export, into: root,
                                                       localMachineId: "AIR", now: clock)
        #expect(summary.frozenAtImport.isEmpty)
        let day = try #require(ImportedHistory.load(root: root).first?.snapshots.snapshots().first)
        #expect(day.total.total == 12)
        #expect(day.cost == 3)
    }

    @Test("re-importing the same export changes nothing, not even a frozen price")
    func reimportIsIdempotent() throws {
        let export = tempDir(), root = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10), rec(nil, at: dayB, input: 3)],
                    snapshots: [snapshot(dayA, tokens: 10, cost: 1)])
        try ImportedHistory.importExport(from: export, into: root, localMachineId: "AIR", now: clock)
        let before = try #require(ImportedHistory.load(root: root).first)
        let recordsBefore = Set(before.archive.allRecords())
        let frozenBefore = before.snapshots.snapshots()

        let later = clock.addingTimeInterval(86_400)
        let again = try ImportedHistory.importExport(from: export, into: root, localMachineId: "AIR", now: later)
        #expect(again.recordCount == 2)                     // the keyless record is not duplicated
        #expect(again.replacedPrevious)
        #expect(again.frozenAtImport.isEmpty)               // day B keeps its first freeze
        let after = try #require(ImportedHistory.load(root: root).first)
        #expect(Set(after.archive.allRecords()) == recordsBefore)
        #expect(after.snapshots.snapshots() == frozenBefore)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers == ["MBP"])                       // no staging / swap-aside debris
    }

    @Test("a newer export's downward repair replaces the imported day")
    func newerExportCorrectionWins() throws {
        let root = tempDir()
        let first = tempDir()
        writeExport(at: first, records: [rec("A1", at: dayA, input: 20)],
                    snapshots: [snapshot(dayA, tokens: 20, cost: 2)], updatedAt: 100)
        try ImportedHistory.importExport(from: first, into: root, localMachineId: "AIR", now: clock)

        let second = tempDir()   // that Mac ran --refreeze: day A settled down to 12
        writeExport(at: second, records: [rec("A1", at: dayA, input: 12)],
                    snapshots: [snapshot(dayA, tokens: 12, cost: 1.2)], updatedAt: 200)
        try ImportedHistory.importExport(from: second, into: root, localMachineId: "AIR", now: clock)

        let machine = try #require(ImportedHistory.load(root: root).first)
        #expect(machine.archive.allRecords().map(\.input) == [12])
        #expect(machine.snapshots.snapshots().map(\.total.total) == [12])
    }

    @Test("refuses an export older than the imported copy, keeping the copy")
    func refusesOlderExport() throws {
        let root = tempDir()
        let newer = tempDir()
        writeExport(at: newer, records: [rec("A1", at: dayA, input: 10), rec("B1", at: dayB, input: 7)],
                    updatedAt: 200)
        try ImportedHistory.importExport(from: newer, into: root, localMachineId: "AIR", now: clock)

        let older = tempDir()
        writeExport(at: older, records: [rec("A1", at: dayA, input: 10)], updatedAt: 100)
        #expect(throws: ImportedHistory.ImportError.olderExport(exportedAt: 100, importedAt: 200)) {
            try ImportedHistory.importExport(from: older, into: root, localMachineId: "AIR", now: clock)
        }
        #expect(ImportedHistory.load(root: root).first?.archive.allRecords().count == 2)
    }

    @Test("refuses an export missing a month or frozen day the imported copy holds")
    func refusesIncompleteExport() throws {
        let may = noon(2025, 5, 20)
        let root = tempDir()
        let full = tempDir()
        writeExport(at: full, records: [rec("M", at: may, input: 4), rec("A1", at: dayA, input: 10)])
        try ImportedHistory.importExport(from: full, into: root, localMachineId: "AIR", now: clock)

        let partial = tempDir()   // someone copied only June's segment
        writeExport(at: partial, records: [rec("A1", at: dayA, input: 10)], updatedAt: 200)
        #expect(throws: ImportedHistory.ImportError.missingHistory(
            [DayBucket.dayKey(may), DayBucket.monthKey(may)].sorted())) {
            try ImportedHistory.importExport(from: partial, into: root, localMachineId: "AIR", now: clock)
        }
        #expect(ImportedHistory.load(root: root).first?.archive.availableMonths()
                == [DayBucket.monthKey(may), DayBucket.monthKey(dayA)])
    }

    @Test("a failed write aborts the import and leaves the previous copy intact")
    func failedWriteKeepsPreviousCopy() throws {
        let root = tempDir()
        let export = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10)])
        try ImportedHistory.importExport(from: export, into: root, localMachineId: "AIR", now: clock)

        let newer = tempDir()
        writeExport(at: newer, records: [rec("A1", at: dayA, input: 10), rec("B1", at: dayB, input: 7)],
                    updatedAt: 200)
        // Read-only root: the staging directory can't be created, so every
        // segment write fails — silently, inside backfill.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        #expect(throws: ImportedHistory.ImportError.writeFailed(
            root.appendingPathComponent(".staging-MBP").path)) {
            try ImportedHistory.importExport(from: newer, into: root, localMachineId: "AIR", now: clock)
        }
        #expect(ImportedHistory.load(root: root).first?.archive.allRecords().count == 1)
    }

    @Test("re-importing a newer export only grows the history")
    func reimportNewerGrows() throws {
        let root = tempDir()
        let first = tempDir()
        writeExport(at: first, records: [rec("A1", at: dayA, input: 10, output: 1)])
        try ImportedHistory.importExport(from: first, into: root, localMachineId: "AIR", now: clock)

        let second = tempDir()
        writeExport(at: second, records: [rec("A1", at: dayA, input: 10, output: 4),   // finished streaming
                                          rec("B1", at: dayB, input: 7)])
        let summary = try ImportedHistory.importExport(from: second, into: root, localMachineId: "AIR", now: clock)
        #expect(summary.recordCount == 2)
        let machine = try #require(ImportedHistory.load(root: root).first)
        #expect(machine.archive.allRecords().first { $0.key == "A1" }?.output == 4)
        let byDate = Dictionary(uniqueKeysWithValues: machine.snapshots.snapshots().map { ($0.date, $0) })
        #expect(byDate[DayBucket.dayKey(dayA)]?.total.total == 14)   // grew with the longer turn
        #expect(byDate[DayBucket.dayKey(dayB)]?.total.total == 7)
    }

    @Test("accepts the data folder itself, not just its parent")
    func acceptsDataFolderDirectly() throws {
        let export = tempDir(), root = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10)], nested: false)
        let summary = try ImportedHistory.importExport(from: export, into: root,
                                                       localMachineId: "AIR", now: clock)
        #expect(summary.recordCount == 1)
    }

    @Test("refuses to import this Mac's own history, writing nothing")
    func refusesOwnMachine() {
        let export = tempDir(), root = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10)])
        #expect(throws: ImportedHistory.ImportError.isThisMac("MBP")) {
            try ImportedHistory.importExport(from: export, into: root, localMachineId: "MBP", now: clock)
        }
        #expect(ImportedHistory.load(root: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("MBP").path))
    }

    @Test("refuses an export whose machine ids disagree")
    func refusesMixedMachines() {
        let export = tempDir(), root = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10)], machineIdFile: "OTHER")
        #expect(throws: ImportedHistory.ImportError.mixedMachines(["MBP", "OTHER"])) {
            try ImportedHistory.importExport(from: export, into: root, localMachineId: "AIR", now: clock)
        }
    }

    @Test("refuses an unreadable or truncated segment rather than leave a hole")
    func refusesDamagedSegments() throws {
        let garbled = tempDir()
        let data = writeExport(at: garbled, records: [rec("A1", at: dayA, input: 10)])
        let segment = data.appendingPathComponent("archive")
            .appendingPathComponent(archiveSegmentName(forMonth: DayBucket.monthKey(dayA)))
        try Data("not json\n".utf8).write(to: segment)
        #expect(throws: ImportedHistory.ImportError.unreadableSegment(segment.lastPathComponent)) {
            try ImportedHistory.importExport(from: garbled, into: tempDir(), localMachineId: "AIR", now: clock)
        }

        let truncated = tempDir()
        let tdata = writeExport(at: truncated, records: [rec("A1", at: dayA, input: 10), rec("A2", at: dayA, input: 5)])
        let tsegment = tdata.appendingPathComponent("archive")
            .appendingPathComponent(archiveSegmentName(forMonth: DayBucket.monthKey(dayA)))
        let lines = try Data(contentsOf: tsegment).split(separator: 0x0A)
        try Data(lines.dropLast().joined(separator: [0x0A])).write(to: tsegment)
        #expect(throws: ImportedHistory.ImportError.truncatedSegment(
            tsegment.lastPathComponent, expected: 2, actual: 1)) {
            try ImportedHistory.importExport(from: truncated, into: tempDir(), localMachineId: "AIR", now: clock)
        }
    }

    @Test("refuses a folder with no archive")
    func refusesEmptyFolder() {
        let empty = tempDir()
        #expect(throws: ImportedHistory.ImportError.noArchive(empty.path)) {
            try ImportedHistory.importExport(from: empty, into: tempDir(), localMachineId: "AIR", now: clock)
        }
    }

    @Test("neither a sidecar-less folder nor an import's staging folder is loaded")
    func partialImportIgnored() throws {
        let root = tempDir()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("MBP/archive", isDirectory: true), withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-OTHER", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode(ImportedHistory.Info(machineId: "OTHER", displayName: "x",
                                                      importedAt: 0, source: "/"))
            .write(to: staging.appendingPathComponent("machine.json"))
        #expect(ImportedHistory.load(root: root).isEmpty)
        #expect(ImportedHistory.infos(root: root).isEmpty)
    }

    @Test("an import resumes a swap cut short between its renames")
    func recoversInterruptedSwap() throws {
        let root = tempDir()
        let export = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10)])
        try ImportedHistory.importExport(from: export, into: root, localMachineId: "AIR", now: clock)
        // Simulate a crash right after the old copy was moved aside.
        try FileManager.default.moveItem(at: root.appendingPathComponent("MBP"),
                                         to: root.appendingPathComponent(".replaced-MBP"))
        #expect(ImportedHistory.load(root: root).isEmpty)

        let older = tempDir()   // the restored copy's guards still apply
        writeExport(at: older, records: [rec("A1", at: dayA, input: 10)], updatedAt: 50)
        #expect(throws: ImportedHistory.ImportError.olderExport(exportedAt: 50, importedAt: 100)) {
            try ImportedHistory.importExport(from: older, into: root, localMachineId: "AIR", now: clock)
        }
        #expect(ImportedHistory.load(root: root).count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".replaced-MBP").path))
    }

    @Test("reports records this Mac's archive also holds")
    func countsOverlapWithLocal() throws {
        let local = UsageArchive(folder: MemoryArchiveFolder(), machineId: "AIR",
                                 displayName: { "air" }, appVersion: "0")
        local.backfill([rec("A1", at: dayA, input: 10)])
        let export = tempDir()
        writeExport(at: export, records: [rec("A1", at: dayA, input: 10), rec("A2", at: dayA, input: 5)])
        let summary = try ImportedHistory.importExport(from: export, into: tempDir(), localMachineId: "AIR",
                                                       localArchive: local, now: clock)
        #expect(summary.overlapWithLocal == 1)
    }

    // MARK: - Merging days across machines

    @Test("mergedByDate sums a day across machines and leaves single days untouched")
    func mergedByDateSums() {
        let air = snapshot(dayA, tokens: 10, cost: 1)
        let mbp = snapshot(dayA, tokens: 90, cost: 4, frozen: false)
        let other = snapshot(dayB, tokens: 5, cost: 0.5)
        let merged = DaySnapshot.mergedByDate([other, air, mbp])
        #expect(merged.map(\.date) == [DayBucket.dayKey(dayA), DayBucket.dayKey(dayB)])
        #expect(merged[0].total.total == 100)
        #expect(merged[0].cost == 5)
        #expect(merged[0].frozen == false)                 // one part was live-priced
        #expect(merged[0].byVendor == [VendorUsage(vendor: "Claude",
                                                   counts: TokenCounts(input: 100), cost: 5)])
        #expect(merged[0].byModel.map(\.tokens) == [100])
        #expect(merged[1] == other)
    }

    // MARK: - Reports

    private func importedMachine(records: [UsageRecord], snapshots: [DaySnapshot]) -> ImportedMachine {
        let archive = UsageArchive(folder: MemoryArchiveFolder(), machineId: "MBP",
                                   displayName: { "Work MBP" }, appVersion: "0")
        archive.backfill(records)
        let url = tempDir().appendingPathComponent("snapshots.ndjson")
        if !snapshots.isEmpty {
            try? SnapshotFile.encode(snapshots, machineId: "MBP", updatedAt: 1).write(to: url)
        }
        return ImportedMachine(machineId: "MBP", displayName: "Work MBP", archive: archive,
                               snapshots: SnapshotStore(fileURL: url, machineId: "MBP"))
    }

    private func store(local: [UsageRecord] = [], archived: [UsageRecord] = [],
                       localSnapshots: [DaySnapshot] = [], imported: [ImportedMachine]) -> UsageStore {
        let archive = UsageArchive(folder: MemoryArchiveFolder(), machineId: "AIR",
                                   displayName: { "air" }, appVersion: "0")
        archive.backfill(archived)
        let url = tempDir().appendingPathComponent("snapshots.ndjson")
        if !localSnapshots.isEmpty {
            try? SnapshotFile.encode(localSnapshots, machineId: "AIR", updatedAt: 1).write(to: url)
        }
        return UsageStore(localProviders: [FixedProvider(records: local)],
                          folder: LocalFolder(tempDir()), archive: archive,
                          snapshots: SnapshotStore(fileURL: url, machineId: "AIR"),
                          imported: imported, machineId: "AIR",
                          isSyncEnabled: { false }, isArchiveEnabled: { true },
                          deliver: { $0() })
    }

    private func report(_ store: UsageStore, _ period: ReportPeriod, anchor: Date,
                        now: Date) async -> PeriodReport? {
        await withCheckedContinuation { c in
            store.report(period: period, anchor: anchor, now: now) { c.resume(returning: $0) }
        }
    }

    @Test("a past month sums this Mac's and the imported Mac's days by date")
    func pastMonthBlendsMachines() async throws {
        let may10 = noon(2025, 5, 10), may11 = noon(2025, 5, 11)
        let may12 = noon(2025, 5, 12), may13 = noon(2025, 5, 13)
        let mbp = importedMachine(
            records: [rec("M10", at: may10, input: 100), rec("M11", at: may11, input: 50),
                      rec("M13", at: may13, input: 7)],
            snapshots: [snapshot(may10, tokens: 100, cost: 2), snapshot(may11, tokens: 50, cost: 0.5)])
        let s = store(archived: [rec("L10", at: may10, input: 10), rec("L12", at: may12, input: 5)],
                      localSnapshots: [snapshot(may10, tokens: 10, cost: 1)], imported: [mbp])

        let r = try #require(await report(s, .month, anchor: may10, now: clock))
        #expect(r.total.total == 172)
        #expect(r.days.map(\.date) == [may10, may11, may12, may13].map { DayBucket.dayKey($0) })
        #expect(r.days.map(\.totalTokens) == [110, 50, 5, 7])
        #expect(r.activeDays == 4)                         // May 10 counted once, not per machine
        #expect(r.busiestDay?.totalTokens == 110)
        #expect(abs(r.cost - 3.5) < 1e-9)                  // both machines' frozen costs
        #expect(r.pricesFrozen == false)                   // May 12 / 13 were never frozen
    }

    @Test("today adds the imported Mac's final day to the live stream, hourly included")
    func todayIncludesImportedDay() async throws {
        let mbp = importedMachine(records: [rec("M", at: clock, input: 20)],
                                  snapshots: [snapshot(clock, tokens: 20, cost: 1)])
        let s = store(local: [rec("L", at: clock, input: 10)], imported: [mbp])

        let r = try #require(await report(s, .day, anchor: clock, now: clock))
        #expect(r.total.total == 30)
        #expect(r.hourly?.reduce(0) { $0 + $1.total } == 30)
        #expect(r.hourly?[Calendar.current.component(.hour, from: clock)].total == 30)
    }

    @Test("the week's hour slots include the imported Mac's records")
    func weekSlotsIncludeImported() async throws {
        let mbp = importedMachine(records: [rec("M", at: clock, input: 20)], snapshots: [])
        let s = store(local: [rec("L", at: clock, input: 10)], imported: [mbp])

        let r = try #require(await report(s, .week, anchor: clock, now: clock))
        #expect(r.total.total == 30)
        #expect(r.fine?.reduce(0) { $0 + $1.counts.total } == 30)
    }

    @Test("all time spans months only the imported history covers")
    func allTimeSpansImportedMonths() async throws {
        let april = noon(2025, 4, 20), may = noon(2025, 5, 5)
        let mbp = importedMachine(records: [rec("A", at: april, input: 40), rec("M", at: may, input: 60)],
                                  snapshots: [snapshot(april, tokens: 40, cost: 4)])
        let s = store(local: [rec("L", at: clock, input: 10)], imported: [mbp])

        let r = try #require(await report(s, .all, anchor: clock, now: clock))
        #expect(r.total.total == 110)
        #expect(r.months?.map(\.month) == ["2025-04", "2025-05", "2025-06"])
        #expect(r.months?.map(\.tokens) == [40, 60, 10])
        #expect(s.archivedMonths() == ["2025-04", "2025-05"])   // this Mac's archive is still empty
        #expect(s.importedMachineNames == ["Work MBP"])
    }

    @Test("without imported history a report is unchanged")
    func noImportedHistory() async throws {
        let s = store(local: [rec("L", at: clock, input: 10)],
                      archived: [rec("Y", at: noon(2025, 6, 17), input: 5)], imported: [])
        let r = try #require(await report(s, .week, anchor: clock, now: clock))
        #expect(r.days.map(\.totalTokens).reduce(0, +) == r.total.total)
        #expect(s.importedMachineNames.isEmpty)
    }
}
