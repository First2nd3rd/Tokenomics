import Foundation

/// The durable, log-rotation-surviving record store.
///
/// The parse cache mirrors the current logs and drops whatever Claude rotates away;
/// the archive keeps every record it has ever observed, in monthly segments under
/// Application Support, so a report stays correct long after the source logs are
/// gone. Segments are pure storage — the month boundary is just log rotation, not a
/// report period; analysis reads across whatever range it needs.
final class UsageArchive {
    private let folder: ArchiveFolder
    private let machineId: String
    private let displayName: () -> String
    private let appVersion: String

    /// Serializes ingest writes (the timer, a wake, and the quit-flush can overlap).
    /// Reads run lock-free: a whole-segment atomic rewrite means a reader always sees
    /// a complete file, never a torn one.
    private let queue = DispatchQueue(label: "\(AppPaths.bundleID).archive", qos: .utility)
    private var lastFingerprint: Int?

    init(folder: ArchiveFolder,
         machineId: String = DeviceIdentity.id,
         displayName: @escaping () -> String = { DeviceIdentity.displayName() },
         appVersion: String = AppPaths.version) {
        self.folder = folder
        self.machineId = machineId
        self.displayName = displayName
        self.appVersion = appVersion
    }

    // MARK: - Read

    /// Months ("YYYY-MM") that have a segment on disk, ascending.
    func availableMonths() -> [String] {
        folder.segmentURLs()
            .compactMap { archiveMonth(fromSegmentName: $0.lastPathComponent) }
            .sorted()
    }

    /// Collapsed records across the given months. Reading the segments and collapsing
    /// ONCE (keyless folded too) yields each unique event exactly once, regardless of
    /// any superseded streamed-output lines a rewrite may have left behind.
    func records(forMonths months: [String]) -> [UsageRecord] {
        Dedup.collapse(months.flatMap(rawSegment), foldKeyless: true)
    }

    /// Convenience: every record in the archive, collapsed. O(all history) — for
    /// diagnostics and tests, not the per-report read path.
    func allRecords() -> [UsageRecord] { records(forMonths: availableMonths()) }

    /// Raw (uncollapsed) records currently in a month's segment, or [] if none.
    private func rawSegment(_ month: String) -> [UsageRecord] {
        guard let dir = folder.directoryURL else { return [] }
        let url = dir.appendingPathComponent(archiveSegmentName(forMonth: month))
        guard let data = folder.readData(at: url), let contents = ArchiveFile.decode(data) else { return [] }
        return contents.records
    }

    // MARK: - Ingest

    /// Fold this machine's freshly-parsed records into the archive. Idempotent: the
    /// providers hand back the WHOLE local corpus every refresh (not a delta), so this
    /// must never grow a segment when the same data is re-presented.
    ///
    /// - A cheap fingerprint of the raw batch short-circuits an unchanged tick before
    ///   any collapse or disk I/O.
    /// - Otherwise the batch is collapsed and routed only to the current and previous
    ///   month (a day/month boundary can still be finalizing yesterday); older months
    ///   don't change and are captured by backfill, so they're skipped to bound work.
    /// - Each touched segment is merged with what's on disk, collapsed, and rewritten
    ///   WHOLESALE only when the collapsed set actually changed.
    func ingest(_ rawRecords: [UsageRecord], now: Date = Date()) {
        queue.sync {
            let fingerprint = Self.fingerprint(rawRecords)
            if fingerprint == lastFingerprint { return }

            let window = Self.acceptableMonths(now: now)
            var byMonth: [String: [UsageRecord]] = [:]
            for record in Dedup.collapse(rawRecords, foldKeyless: true) {
                let month = DayBucket.month(epoch: record.epoch)
                guard window.contains(month) else { continue }
                byMonth[month, default: []].append(record)
            }

            for (month, records) in byMonth {
                writeMerged(records, into: month)
            }
            lastFingerprint = fingerprint
        }
    }

    /// Merge `records` with the month's existing segment, collapse, and rewrite the
    /// whole segment only when the result differs. Caller holds `queue`.
    private func writeMerged(_ records: [UsageRecord], into month: String) {
        let existing = rawSegment(month)
        let merged = Dedup.collapse(existing + records, foldKeyless: true)
        guard Self.fingerprint(merged) != Self.fingerprint(existing) else { return }
        let data = ArchiveFile.encode(records: merged, month: month, machineId: machineId,
                                      displayName: displayName(), appVersion: appVersion,
                                      updatedAt: Int(Date().timeIntervalSince1970))
        try? folder.writeSegment(data, month: month)
    }

    // MARK: - Helpers

    /// The current month plus the previous calendar month — the only segments steady-
    /// state ingest may touch.
    static func acceptableMonths(now: Date, calendar: Calendar = .current) -> Set<String> {
        var months: Set<String> = [DayBucket.monthKey(now, calendar: calendar)]
        if let prev = calendar.date(byAdding: .month, value: -1, to: now) {
            months.insert(DayBucket.monthKey(prev, calendar: calendar))
        }
        return months
    }

    /// Order-independent fingerprint of a record set; changes when records are added
    /// or their token counts grow. Deterministic within a process (no per-run seed).
    static func fingerprint(_ records: [UsageRecord]) -> Int {
        var total = 0, maxEpoch = 0
        for r in records {
            total = total &+ r.input &+ r.output &+ r.cacheCreation &+ r.cacheRead
            maxEpoch = max(maxEpoch, r.epoch)
        }
        return records.count &* 1_000_003 &+ total &+ maxEpoch
    }
}
