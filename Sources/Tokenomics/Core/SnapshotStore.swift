import Foundation

/// The durable daily-snapshot store: a single `snapshots.ndjson` under Application
/// Support holding one frozen `DaySnapshot` per finalized day. Snapshots are a
/// derived cache of the archive — their value is keeping each day's cost frozen at
/// the prices in effect then (the archive stores only token counts, re-priced live).
///
/// The file URL is injectable so tests never touch the real Application Support.
final class SnapshotStore {
    private let fileURL: URL?
    private let machineId: String
    private let queue = DispatchQueue(label: "\(AppPaths.bundleID).snapshots", qos: .utility)
    /// The calendar day the last successful sweep ran for — so a sweep does real work
    /// at most once per day per session (finalized days don't change within a day).
    private var sweptForDay: String?

    init(fileURL: URL? = AppPaths.applicationSupport()?.appendingPathComponent("snapshots.ndjson"),
         machineId: String = DeviceIdentity.id) {
        self.fileURL = fileURL
        self.machineId = machineId
    }

    /// Every stored day snapshot, ascending. Empty when there's no file yet.
    func snapshots() -> [DaySnapshot] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let days = SnapshotFile.decode(data) else { return [] }
        return days
    }

    /// Freeze every finalized day (strictly before today) the archive holds that isn't
    /// snapshotted yet, at current prices. Idempotent and guarded to one real sweep
    /// per calendar day per session. Today is never frozen — it's still in progress.
    func refresh(now: Date = Date(), archive: UsageArchive, calendar: Calendar = .current) {
        queue.sync {
            let todayKey = DayBucket.dayKey(now, calendar: calendar)
            if sweptForDay == todayKey { return }

            let existing = snapshots()
            let have = Set(existing.map(\.date))

            // Only re-read the archive months that could hold un-snapshotted days:
            // from the last snapshot onward (everything earlier is already frozen).
            let months: [String]
            if let last = existing.map(\.date).max(), let lastDate = Self.date(fromDayKey: last, calendar: calendar) {
                months = DayBucket.monthsSpanning(from: lastDate, to: now, calendar: calendar)
            } else {
                months = archive.availableMonths()
            }

            let records = archive.records(forMonths: months)
            let fresh = UsageAggregator
                .daySummaries(records, pricedAt: Int(now.timeIntervalSince1970), frozen: true, calendar: calendar)
                .filter { $0.date < todayKey && !have.contains($0.date) }

            sweptForDay = todayKey
            guard !fresh.isEmpty else { return }

            let merged = (existing + fresh).sorted { $0.date < $1.date }
            guard let fileURL else { return }
            try? SnapshotFile.encode(merged, machineId: machineId, updatedAt: Int(now.timeIntervalSince1970))
                .write(to: fileURL, options: .atomic)
        }
    }

    /// Parse a "yyyy-MM-dd" key to a Date under `calendar` (its day-start instant).
    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
