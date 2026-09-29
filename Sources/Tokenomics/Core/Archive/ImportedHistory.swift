import Foundation

/// A retired Mac's usage history (e.g. a returned work laptop), imported from its
/// Application Support export and kept READ-ONLY under
/// `Application Support/me.stfang.tokenomics/imported/<machine-id>/`, in the same
/// segment + snapshot formats as this Mac's own history.
///
/// Deliberately NOT merged into this Mac's archive: that one is rewritten by ingest,
/// the daily snapshot sweep, and `--refreeze`, all of which treat every record as
/// this Mac's — the sweep even settles recent days to this Mac's logs, which would
/// silently delete another machine's records for those days. Nothing but an explicit
/// import writes here; reports fold it in at read time (`UsageStore.buildReport`).
struct ImportedMachine {
    let machineId: String
    let displayName: String
    let archive: UsageArchive
    let snapshots: SnapshotStore
}

enum ImportedHistory {
    /// `imported/` under Application Support. Not created until an import writes it.
    static var defaultRoot: URL? {
        AppPaths.applicationSupport()?.appendingPathComponent("imported", isDirectory: true)
    }

    private static let infoFileName = "machine.json"
    private static let snapshotsFileName = "snapshots.ndjson"
    private static let archiveDirName = "archive"

    /// Sidecar identifying one imported machine. An import writes it last, inside
    /// its staging directory, so a directory without it is never loaded.
    struct Info: Codable, Equatable {
        let machineId: String
        let displayName: String
        let importedAt: Int         // UTC epoch seconds
        let source: String          // the export path it came from
        /// The export's newest segment write (UTC epoch) — an older export is
        /// refused. Absent in sidecars from the first import format.
        var sourceUpdatedAt: Int? = nil
    }

    // MARK: - Read

    /// The imported machines' sidecars, sorted by name. Cheap — no segment reads.
    static func infos(root: URL? = defaultRoot) -> [Info] {
        machineDirectories(root: root).compactMap { readInfo(in: $0) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Every fully imported machine, ready for reports to read.
    static func load(root: URL? = defaultRoot) -> [ImportedMachine] {
        machineDirectories(root: root).compactMap { dir -> ImportedMachine? in
            guard let info = readInfo(in: dir) else { return nil }
            let folder = LocalArchiveFolder(dir.appendingPathComponent(archiveDirName, isDirectory: true))
            return ImportedMachine(
                machineId: info.machineId, displayName: info.displayName,
                archive: UsageArchive(folder: folder, machineId: info.machineId,
                                      displayName: { info.displayName }),
                snapshots: SnapshotStore(fileURL: dir.appendingPathComponent(snapshotsFileName),
                                         machineId: info.machineId))
        }
        .sorted { $0.displayName < $1.displayName }
    }

    private static func machineDirectories(root: URL?) -> [URL] {
        guard let root,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        // Dot-prefixed entries are an import's staging / swap-aside directories.
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func readInfo(in dir: URL) -> Info? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(infoFileName)) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    // MARK: - Import

    enum ImportError: Error, CustomStringConvertible, Equatable {
        case noArchive(String)
        case unreadableSegment(String)
        case truncatedSegment(String, expected: Int, actual: Int)
        case mixedMachines([String])
        case isThisMac(String)
        case unreadableSnapshots(String)
        case olderExport(exportedAt: Int, importedAt: Int)
        case missingHistory([String])
        case writeFailed(String)

        var description: String {
            switch self {
            case .noArchive(let path):
                return "no archive segments under \(path) (expected archive/archive-YYYY-MM.ndjson)"
            case .unreadableSegment(let name):
                return "\(name): manifest missing or from a newer app version"
            case .truncatedSegment(let name, let expected, let actual):
                return "\(name): manifest lists \(expected) records but only \(actual) parse"
            case .mixedMachines(let ids):
                return "export mixes machine ids \(ids.joined(separator: ", ")) — import one Mac at a time"
            case .isThisMac(let id):
                return "export is THIS Mac's own history (\(id)) — nothing to import"
            case .unreadableSnapshots(let path):
                return "\(path) exists but can't be read — refusing rather than drop its frozen days"
            case .olderExport(let exportedAt, let importedAt):
                return "export was last written \(Date(timeIntervalSince1970: TimeInterval(exportedAt))), "
                    + "older than the imported copy (\(Date(timeIntervalSince1970: TimeInterval(importedAt))))"
            case .missingHistory(let keys):
                return "export lacks history the imported copy holds (\(keys.joined(separator: ", "))) — "
                    + "is it complete?"
            case .writeFailed(let path):
                return "writing \(path) failed (disk full or no permission?) — the previous copy is untouched"
            }
        }
    }

    struct Summary {
        let machineId: String
        let displayName: String
        let months: [String]
        let recordCount: Int
        let snapshotDays: Int
        /// Days the export's own snapshots didn't cover (or undercounted), frozen
        /// from its archive at import-time prices — e.g. the partial export day.
        let frozenAtImport: [String]
        let firstDay: String?
        let lastDay: String?
        /// Record keys also present in this Mac's archive. Reports sum machines by
        /// day, so any overlap would be double-counted — expected to be 0.
        let overlapWithLocal: Int
        let replacedPrevious: Bool
    }

    /// Import a Mac's exported `me.stfang.tokenomics` Application Support folder
    /// (`source` may be that folder or its parent).
    ///
    /// The imported copy mirrors the LATEST export of that Mac: a re-import
    /// replaces it wholesale, so the source's own downward repairs (`--refreeze`)
    /// carry over instead of losing to a grow-only merge. Because a replace could
    /// otherwise drop history, it refuses an export older than the imported copy,
    /// or one missing a month or frozen day the copy holds. The copy is built in a
    /// staging directory, read back and checked against the export, then swapped
    /// in — a failed write aborts with the previous copy untouched.
    ///
    /// The export's own frozen snapshots are kept verbatim (their costs are the
    /// historical ones). A retired machine's days are all final, so any archive
    /// day the export never froze is frozen now, as that Mac's own sweep would have.
    @discardableResult
    static func importExport(from source: URL, into root: URL, localMachineId: String,
                             localArchive: UsageArchive? = nil, now: Date = Date(),
                             calendar: Calendar = .current) throws -> Summary {
        let dataDir = try locateDataDirectory(source)
        let segments = try readSegments(in: dataDir.appendingPathComponent(archiveDirName, isDirectory: true))

        // Attribution: the export's machine-id file when present, else the
        // segment manifests — which must all agree.
        var ids = Set(segments.map(\.contents.manifest.machineId))
        if let fileId = try? String(contentsOf: dataDir.appendingPathComponent("machine-id"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !fileId.isEmpty {
            ids.insert(fileId)
        }
        guard ids.count == 1, let machineId = ids.first else {
            throw ImportError.mixedMachines(ids.sorted())
        }
        guard machineId != localMachineId else { throw ImportError.isThisMac(machineId) }
        let newest = segments.max { $0.contents.manifest.updatedAt < $1.contents.manifest.updatedAt }!
        let displayName = newest.contents.manifest.displayName

        let sourceSnapshotsURL = dataDir.appendingPathComponent(snapshotsFileName)
        var sourceSnapshots: [DaySnapshot] = []
        if FileManager.default.fileExists(atPath: sourceSnapshotsURL.path) {
            guard let data = try? Data(contentsOf: sourceSnapshotsURL),
                  let days = SnapshotFile.decode(data) else {
                throw ImportError.unreadableSnapshots(sourceSnapshotsURL.path)
            }
            sourceSnapshots = days
        }

        let exportedAt = newest.contents.manifest.updatedAt

        let fm = FileManager.default
        let machineDir = root.appendingPathComponent(machineId, isDirectory: true)
        let staging = root.appendingPathComponent(".staging-\(machineId)", isDirectory: true)
        let replaced = root.appendingPathComponent(".replaced-\(machineId)", isDirectory: true)
        // A swap cut short between its two renames leaves the old copy aside.
        if fm.fileExists(atPath: replaced.path) {
            if fm.fileExists(atPath: machineDir.path) { try? fm.removeItem(at: replaced) }
            else { try fm.moveItem(at: replaced, to: machineDir) }
        }

        // The copy being replaced, if any — the guards below compare against it.
        let previous = readInfo(in: machineDir)
        let previousSnapshotsURL = machineDir.appendingPathComponent(snapshotsFileName)
        let previousSnapshots = SnapshotStore(fileURL: previousSnapshotsURL, machineId: machineId).snapshots()
        if previousSnapshots.isEmpty, fm.fileExists(atPath: previousSnapshotsURL.path) {
            throw ImportError.unreadableSnapshots(previousSnapshotsURL.path)
        }
        let previousMonths = LocalArchiveFolder
            .segmentURLs(in: machineDir.appendingPathComponent(archiveDirName, isDirectory: true))
            .compactMap { archiveMonth(fromSegmentName: $0.lastPathComponent) }
        if let previousAt = previous?.sourceUpdatedAt, exportedAt < previousAt {
            throw ImportError.olderExport(exportedAt: exportedAt, importedAt: previousAt)
        }

        let expected = Dedup.collapse(segments.flatMap(\.contents.records), foldKeyless: true)
        try? fm.removeItem(at: staging)
        let summary: Summary
        do {
            let archive = UsageArchive(
                folder: LocalArchiveFolder(staging.appendingPathComponent(archiveDirName, isDirectory: true)),
                machineId: machineId, displayName: { displayName },
                appVersion: newest.contents.manifest.appVersion)
            archive.backfill(expected)
            // Backfill swallows write errors (the app's steady ingest retries them);
            // an import must not report success over a missing segment.
            let records = archive.allRecords()
            guard records.count == expected.count,
                  UsageArchive.fingerprint(records) == UsageArchive.fingerprint(expected) else {
                throw ImportError.writeFailed(staging.path)
            }

            // Frozen days: the export's own, verbatim; then its archive for any day
            // they miss or undercount (grow-only, like that Mac's sweep). A day the
            // previous import froze at the same total keeps its original freeze, so
            // re-importing never re-prices history.
            let previousByDate = Dictionary(uniqueKeysWithValues: previousSnapshots.map { ($0.date, $0) })
            var byDate = Dictionary(uniqueKeysWithValues: sourceSnapshots.map { ($0.date, $0) })
            var frozenAtImport: [String] = []
            let fromArchive = UsageAggregator.daySummaries(
                records, pricedAt: Int(now.timeIntervalSince1970), frozen: true,
                calendar: calendar, assumeCollapsed: true)
            for day in fromArchive {
                if let kept = byDate[day.date], kept.total.total >= day.total.total { continue }
                if let earlier = previousByDate[day.date], earlier.total == day.total {
                    byDate[day.date] = earlier
                } else {
                    byDate[day.date] = day
                    frozenAtImport.append(day.date)
                }
            }
            let merged = byDate.values.sorted { $0.date < $1.date }

            let months = archive.availableMonths()
            let lostMonths = Set(previousMonths).subtracting(months)
            let lostDays = Set(previousSnapshots.map(\.date)).subtracting(merged.map(\.date))
            guard lostMonths.isEmpty, lostDays.isEmpty else {
                throw ImportError.missingHistory((lostMonths.union(lostDays)).sorted())
            }

            try SnapshotFile.encode(merged, machineId: machineId, updatedAt: Int(now.timeIntervalSince1970))
                .write(to: staging.appendingPathComponent(snapshotsFileName), options: .atomic)
            let info = Info(machineId: machineId, displayName: displayName,
                            importedAt: Int(now.timeIntervalSince1970), source: source.path,
                            sourceUpdatedAt: exportedAt)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(info).write(to: staging.appendingPathComponent(infoFileName), options: .atomic)

            var overlap = 0
            if let localArchive {
                let localKeys = Set(localArchive.allRecords().compactMap(\.key))
                overlap = records.filter { $0.key.map(localKeys.contains) ?? false }.count
            }
            summary = Summary(machineId: machineId, displayName: displayName, months: months,
                              recordCount: records.count, snapshotDays: merged.count,
                              frozenAtImport: frozenAtImport.sorted(),
                              firstDay: merged.first?.date, lastDay: merged.last?.date,
                              overlapWithLocal: overlap, replacedPrevious: previous != nil)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // Swap in: two same-volume renames, restoring the old copy if the second fails.
        if fm.fileExists(atPath: machineDir.path) {
            try fm.moveItem(at: machineDir, to: replaced)
            do {
                try fm.moveItem(at: staging, to: machineDir)
            } catch {
                try? fm.moveItem(at: replaced, to: machineDir)
                try? fm.removeItem(at: staging)
                throw error
            }
            try? fm.removeItem(at: replaced)
        } else {
            try fm.moveItem(at: staging, to: machineDir)
        }
        return summary
    }

    /// The folder holding `archive/`: `source` itself, or the export's
    /// `me.stfang.tokenomics` subfolder.
    private static func locateDataDirectory(_ source: URL) throws -> URL {
        for candidate in [source, source.appendingPathComponent(AppPaths.bundleID, isDirectory: true)] {
            let archiveDir = candidate.appendingPathComponent(archiveDirName, isDirectory: true)
            if !LocalArchiveFolder.segmentURLs(in: archiveDir).isEmpty { return candidate }
        }
        throw ImportError.noArchive(source.path)
    }

    private struct Segment {
        let name: String
        let contents: ArchiveFile.Contents
    }

    /// Every segment, strictly: an unreadable or short segment aborts the import
    /// instead of silently leaving a hole in the history.
    private static func readSegments(in dir: URL) throws -> [Segment] {
        let urls = LocalArchiveFolder.segmentURLs(in: dir).sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { throw ImportError.noArchive(dir.path) }
        return try urls.map { url in
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url), let contents = ArchiveFile.decode(data) else {
                throw ImportError.unreadableSegment(name)
            }
            guard contents.records.count >= contents.manifest.recordCount else {
                throw ImportError.truncatedSegment(name, expected: contents.manifest.recordCount,
                                                   actual: contents.records.count)
            }
            return Segment(name: name, contents: contents)
        }
    }
}
