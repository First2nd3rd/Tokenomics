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

    /// Finalized days recent enough that the LIVE logs are still authoritative —
    /// rotation never eats days this young, and the archive's copy can only have
    /// drifted UP (its merge keeps a turn's largest transient variant).
    static let liveFreezeWindow = 3

    /// The day keys inside that window: the `liveFreezeWindow` days before today.
    static func liveFreezeDays(now: Date, calendar: Calendar) -> Set<String> {
        Set((1...liveFreezeWindow).compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: now)
                .map { DayBucket.dayKey($0, calendar: calendar) }
        })
    }

    /// Freeze every finalized day (strictly before today) the archive holds that isn't
    /// snapshotted yet, at current prices. Idempotent and guarded to one real sweep
    /// per calendar day per session. Today is never frozen — it's still in progress.
    ///
    /// Days inside `liveFreezeWindow` freeze from `liveRecords` (the logs, with the
    /// dashboard's exact collapse) when provided — the frozen value then matches what
    /// the dashboard showed that day, instead of whatever transient maximum the
    /// archive happened to capture. Older days keep freezing from the archive.
    func refresh(now: Date = Date(), archive: UsageArchive,
                 liveRecords: [UsageRecord]? = nil, calendar: Calendar = .current) {
        queue.sync {
            let todayKey = DayBucket.dayKey(now, calendar: calendar)
            if sweptForDay == todayKey { return }

            let existing = snapshots()
            // A populated file that reads back empty is a FAILED read (corrupt
            // manifest, newer schema), not an empty store — sweeping against
            // nothing would rewrite history at current prices. Sit this one out.
            if existing.isEmpty, let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                return
            }

            // Sweep the WHOLE archive (a few MB, once per day): grow-only re-freeze
            // must see every month, so a parser fix that back-corrects an old month's
            // segment propagates into its frozen days instead of leaving the report
            // stuck below the dashboard.
            let records = archive.records(forMonths: archive.availableMonths())
            var summaries = UsageAggregator
                .daySummaries(records, pricedAt: Int(now.timeIntervalSince1970), frozen: true,
                              calendar: calendar, assumeCollapsed: true)   // archive read collapses
                .filter { $0.date < todayKey }

            if let liveRecords {
                let window = Self.liveFreezeDays(now: now, calendar: calendar)
                // Dashboard semantics: collapse the WHOLE corpus first, then
                // bucket by the SURVIVOR's epoch — filtering by day first would
                // resurrect the superseded partials of a midnight-straddling
                // turn into yesterday (double-counted with today's final).
                var liveByDay: [String: [UsageRecord]] = [:]
                for r in Dedup.collapse(liveRecords) {
                    let day = DayBucket.day(epoch: r.epoch, calendar: calendar)
                    guard window.contains(day) else { continue }
                    liveByDay[day, default: []].append(r)
                }
                let archiveByDate = Dictionary(uniqueKeysWithValues: summaries.map { ($0.date, $0) })
                let live = UsageAggregator.daySummaries(
                    liveByDay.values.flatMap { $0 }, pricedAt: Int(now.timeIntervalSince1970),
                    frozen: true, calendar: calendar, assumeCollapsed: true)
                // Live wins inside the window; a window day the logs don't cover
                // (shouldn't happen this young) keeps its archive value.
                var byDate = archiveByDate
                for day in live {
                    byDate[day.date] = day
                    // The archive's LARGER copy (captured transients) would win
                    // the grow-only merge again once this day leaves the window —
                    // settle the archive to the logs' records now, so the two
                    // sources agree forever after. Smaller/equal copies stand
                    // (keyless folding legitimately trims the archive a little).
                    if let archived = archiveByDate[day.date],
                       archived.total.total > day.total.total,
                       let dayRecords = liveByDay[day.date] {
                        archive.replaceDay(day.date, with: dayRecords, calendar: calendar)
                    }
                }
                summaries = Array(byDate.values)
            }

            sweptForDay = todayKey

            // New days are frozen; an already-frozen day is RE-frozen only when the
            // archive now holds MORE tokens for it (a turn straddling midnight keeps
            // growing after the day was first swept — grow-only, so a partial
            // recompute window can never shrink a frozen day).
            var byDate = Dictionary(uniqueKeysWithValues: existing.map { ($0.date, $0) })
            var changed = false
            for day in summaries {
                if let frozen = byDate[day.date] {
                    guard day.total.total > frozen.total.total else { continue }
                }
                byDate[day.date] = day
                changed = true
            }
            guard changed, let fileURL else { return }

            let merged = byDate.values.sorted { $0.date < $1.date }
            try? SnapshotFile.encode(merged, machineId: machineId, updatedAt: Int(now.timeIntervalSince1970))
                .write(to: fileURL, options: .atomic)
        }
    }

    /// Overwrite one day's snapshot UNCONDITIONALLY — the `--refreeze` repair path.
    /// Grow-only is the steady-state rule; this is the explicit correction tool for
    /// a day the archive froze from inflated transients. Returns false (and writes
    /// nothing) when the store file exists but reads back empty — that's a failed
    /// read, and rewriting from it would wipe every other frozen day.
    @discardableResult
    func overwrite(_ day: DaySnapshot, now: Date = Date()) -> Bool {
        queue.sync {
            guard let fileURL else { return false }
            let existing = snapshots()
            if existing.isEmpty, FileManager.default.fileExists(atPath: fileURL.path) {
                return false
            }
            var byDate = Dictionary(uniqueKeysWithValues: existing.map { ($0.date, $0) })
            byDate[day.date] = day
            let merged = byDate.values.sorted { $0.date < $1.date }
            let data = SnapshotFile.encode(merged, machineId: machineId,
                                           updatedAt: Int(now.timeIntervalSince1970))
            return (try? data.write(to: fileURL, options: .atomic)) != nil
        }
    }
}
