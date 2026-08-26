import Foundation

/// A point-in-time view of usage: the per-day series, sorted ascending by date.
struct UsageSnapshot {
    let days: [DailyUsage]
}

/// One machine's contribution for the by-machine view + status line.
struct MachineSummary: Identifiable {
    let id: String           // machine id
    let name: String
    let todayTokens: Int
    let lastSeen: Int        // UTC epoch (a peer's publishedAt; now for this Mac)
    let isLocal: Bool
}

/// Owns the provider layer and exposes refresh + publish entry points. Results are
/// delivered (by default) on the main queue, ready for UI.
///
/// When cross-machine sync is enabled, peers' records fold into the SAME union the
/// local providers feed, so every view (headline, break-even, daily bars, intraday)
/// stays consistent; the single global `Dedup.collapse` removes any overlap. When
/// it's off, nothing is read from or written to iCloud.
final class UsageStore {
    private let localProviders: [UsageProvider]
    private let peerSource: PeerRecordSource
    private let publisher: PeerPublisher
    private let archive: UsageArchive?
    private let snapshots: SnapshotStore?
    private let machineId: String
    private let isSyncEnabled: () -> Bool
    private let isArchiveEnabled: () -> Bool
    private let deliver: (@escaping () -> Void) -> Void

    init(localProviders: [UsageProvider] = [ClaudeNativeProvider(), CodexProvider(),
                                            WorkBuddyProvider()],
         folder: PeerFolder = ICloudDriveFolder(),
         archive: UsageArchive? = LocalArchiveFolder().map { UsageArchive(folder: $0) },
         snapshots: SnapshotStore? = SnapshotStore(),
         machineId: String = DeviceIdentity.id,
         isSyncEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "syncEnabled") },
         isArchiveEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "archiveEnabled") },
         deliver: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }) {
        self.localProviders = localProviders
        self.peerSource = PeerRecordSource(folder: folder, ownMachineId: machineId)
        self.publisher = PeerPublisher(folder: folder, machineId: machineId)
        self.archive = archive
        self.snapshots = snapshots
        self.machineId = machineId
        self.isSyncEnabled = isSyncEnabled
        self.isArchiveEnabled = isArchiveEnabled
        self.deliver = deliver
    }

    /// The provider feeding the views: local always, peers folded in when sync is on.
    private var provider: UsageProvider {
        isSyncEnabled() ? CombinedProvider(localProviders + [peerSource]) : CombinedProvider(localProviders)
    }

    /// Everything one 60s tick needs, derived from a SINGLE records fetch and a
    /// SINGLE global dedup — previously each surface re-fetched and re-collapsed
    /// the same union, multiplying the per-tick CPU by the number of surfaces.
    struct TickData {
        let byVendor: [String: [DailyUsage]]
        let matrixCombined: [String: [MinuteBucket]]
        let matrixLocal: [String: [MinuteBucket]]
        let machines: [MachineSummary]
    }

    /// The last fetched local records, reused by report() while fresh — a
    /// Statistics reload then skips a full provider fetch AND shows literally the
    /// snapshot the menu bar rendered. One tick of staleness (the menu bar's own
    /// cadence) is the accepted bound. Guarded by `recentRecordsGate`.
    private var recentRecords: (records: [UsageRecord], at: Date)?
    private let recentRecordsGate = NSLock()
    private static let recentRecordsMaxAge: TimeInterval = 90

    private func rememberRecords(_ records: [UsageRecord], at: Date) {
        recentRecordsGate.lock()
        recentRecords = (records, at)
        recentRecordsGate.unlock()
    }

    private func freshRecords(now: Date) -> [UsageRecord]? {
        recentRecordsGate.lock()
        defer { recentRecordsGate.unlock() }
        guard let recent = recentRecords,
              now.timeIntervalSince(recent.at) <= Self.recentRecordsMaxAge else { return nil }
        return recent.records
    }

    /// One-shot per-tick refresh: fetch local (+ peers when sync is on) once,
    /// collapse once, derive every view, and run the throttled persist pass on the
    /// same records. Delivered ready for UI.
    func refreshTick(now: Date = Date(), lastDays: Int,
                     completion: @escaping (TickData) -> Void) {
        let syncOn = isSyncEnabled()
        fetchTickRecords(syncOn: syncOn) { [weak self] local, combined in
            guard let self else { return }
            self.rememberRecords(local, at: now)
            let collapsed = Dedup.collapse(combined)
            let byVendor = UsageAggregator.byVendor(collapsed: collapsed)
            let (c, l) = UsageAggregator.splitDayMinuteMatrix(collapsed: collapsed)
            let tick = TickData(
                byVendor: byVendor,
                matrixCombined: DayBucket.recentDays(c, now: now, count: lastDays),
                matrixLocal: DayBucket.recentDays(l, now: now, count: lastDays),
                machines: syncOn ? self.machineSummaries(collapsed: collapsed, now: now) : [])
            self.persistLocal(now: now, records: local)
            // The snapshot sweep rides the tick's fetch too, so freshly-finalized
            // days freeze from the same live records every other surface uses.
            self.refreshSnapshots(now: now, liveRecords: local)
            self.deliver { completion(tick) }
        }
    }

    /// The tick's two record streams: this Mac's union, and combined (== local when
    /// sync is off, local + peers when on). One fetch feeds both.
    private func fetchTickRecords(syncOn: Bool,
                                  _ completion: @escaping (_ local: [UsageRecord],
                                                           _ combined: [UsageRecord]) -> Void) {
        CombinedProvider(localProviders).fetchRecords { [weak self] local in
            guard let self, syncOn else { completion(local, local); return }
            self.peerSource.fetchRecords { peers in completion(local, local + peers) }
        }
    }

    /// Per-machine today totals from already-collapsed records (see refreshMachines).
    private func machineSummaries(collapsed: [UsageRecord], now: Date) -> [MachineSummary] {
        let today = DayBucket.dayKey(now)
        var tokens: [String: Int] = [:]
        for r in collapsed where DayBucket.day(epoch: r.epoch) == today {
            let machine = r.machine ?? machineId
            tokens[machine, default: 0] += r.input + r.output + r.cacheCreation + r.cacheRead
        }
        var summaries = [MachineSummary(id: machineId, name: DeviceIdentity.displayName(),
                                        todayTokens: tokens[machineId] ?? 0,
                                        lastSeen: Int(now.timeIntervalSince1970), isLocal: true)]
        for info in peerSource.peerInfos() {
            summaries.append(MachineSummary(id: info.machineId, name: info.displayName,
                                            todayTokens: tokens[info.machineId] ?? 0,
                                            lastSeen: info.publishedAt, isLocal: false))
        }
        return summaries.sorted { $0.todayTokens > $1.todayTokens }
    }

    /// Per-vendor daily series (provider id → days), delivered ready for UI. The
    /// single source for both the headline and the per-vendor break-even.
    func refreshByVendor(completion: @escaping ([String: [DailyUsage]]) -> Void) {
        provider.fetchDailyByVendor { byVendor in self.deliver { completion(byVendor) } }
    }

    /// Combined + local-only day→minute matrices (today + the `lastDays` prior days),
    /// trimmed to that window. `combined` drives the full-day chart + cumulative curve;
    /// `local` lets the live last-hour chart show this Mac at true height with a
    /// (combined − local) peer overlay. When sync is off, `local == combined`.
    func refreshMatrix(now: Date = Date(), lastDays: Int,
                       completion: @escaping (_ combined: [String: [MinuteBucket]],
                                              _ local: [String: [MinuteBucket]]) -> Void) {
        provider.fetchRecords { records in
            let (combined, local) = UsageAggregator.splitDayMinuteMatrix(records)
            let c = DayBucket.recentDays(combined, now: now, count: lastDays)
            let l = DayBucket.recentDays(local, now: now, count: lastDays)
            self.deliver { completion(c, l) }
        }
    }

    /// Per-machine summaries for today (this Mac + each peer), for the by-machine view
    /// and status line. Empty when sync is off. Delivered ready for UI.
    func refreshMachines(now: Date = Date(), completion: @escaping ([MachineSummary]) -> Void) {
        guard isSyncEnabled() else { deliver { completion([]) }; return }
        CombinedProvider(localProviders + [peerSource]).fetchRecords { records in
            let summaries = self.machineSummaries(collapsed: Dedup.collapse(records), now: now)
            self.deliver { completion(summaries) }
        }
    }

    /// Publish this machine's (LOCAL-only) records when sync is on. Fire-and-forget;
    /// the publisher throttles and skips an unchanged set, so an idle refresh writes
    /// nothing.
    func publishIfNeeded() {
        guard isSyncEnabled() else { return }
        CombinedProvider(localProviders).fetchRecords { [publisher] records in
            publisher.publishIfNeeded(localRecords: records)
        }
    }

    /// Archive + peer publish don't need minute freshness: run a real persist pass at
    /// most every `persistInterval`. The quit-time `flushLocal` stays immediate and
    /// forced, so at most this window of increments rides on the crash-only risk —
    /// and even then the source logs still hold them for the next ingest.
    private static let persistInterval: TimeInterval = 300
    /// Guarded by `persistGate`: persistLocal now runs from refreshTick's
    /// background completion, so overlapping ticks must not race the gate.
    private var lastPersistAt = Date.distantPast
    private let persistGate = NSLock()

    /// Fan this machine's local records to both the peer publisher and the durable
    /// archive — each a no-op when its feature is off or nothing changed. Pass
    /// `records` when the tick already fetched them (refreshTick); otherwise this
    /// fetches once itself.
    func persistLocal(now: Date = Date(), records: [UsageRecord]? = nil,
                      completion: (() -> Void)? = nil) {
        let wantPublish = isSyncEnabled()
        let wantArchive = isArchiveEnabled()
        guard wantPublish || wantArchive else { completion?(); return }
        persistGate.lock()
        let isDue = now.timeIntervalSince(lastPersistAt) >= Self.persistInterval
        if isDue { lastPersistAt = now }
        persistGate.unlock()
        guard isDue else { completion?(); return }
        let persist: ([UsageRecord]) -> Void = { [weak self] records in
            guard let self else { completion?(); return }
            if wantPublish { self.publisher.publishIfNeeded(localRecords: records) }
            if wantArchive { self.archive?.ingest(records) }
            completion?()
        }
        if let records {
            persist(records)
        } else {
            CombinedProvider(localProviders).fetchRecords(completion: persist)
        }
    }

    /// Build a usage report for the period containing `anchor` (this Mac only). Uses
    /// frozen daily snapshots for completed days (stable historical cost) and the raw
    /// archive for today plus any day a snapshot doesn't cover yet (live cost). Reads
    /// on a background queue — never the refresh path — and delivers ready for UI.
    /// nil when archiving is unavailable.
    func report(period: ReportPeriod, anchor: Date, now: Date = Date(),
                completion: @escaping (PeriodReport?) -> Void) {
        guard let archive else { deliver { completion(nil) }; return }
        // TODAY's row is computed from the same live records the menu bar
        // aggregates (same dedup, same prices) — never from the archive — so the
        // two surfaces can't disagree and a reload writes nothing to disk. The
        // archive's copy of today can only drift UP (collapse keeps the largest
        // variant, so a superseded streamed line is never corrected down).
        // Historical days still come from frozen snapshots + the archive.
        if period.range(containing: anchor).contains(now) {
            // Reuse the tick's snapshot when fresh — no refetch, and identical to
            // what the menu bar shows. Rapid period switches all hit this memo.
            if let records = freshRecords(now: now) {
                buildReport(archive: archive, period: period, anchor: anchor,
                            now: now, liveRecords: records, completion: completion)
            } else {
                CombinedProvider(localProviders).fetchRecords { [weak self] records in
                    guard let self else { return }
                    self.rememberRecords(records, at: now)
                    self.buildReport(archive: archive, period: period, anchor: anchor,
                                     now: now, liveRecords: records, completion: completion)
                }
            }
        } else {
            buildReport(archive: archive, period: period, anchor: anchor,
                        now: now, liveRecords: nil, completion: completion)
        }
    }

    /// Assemble the report from snapshots + archive (+ live records for today) on a
    /// background queue.
    private func buildReport(archive: UsageArchive, period: ReportPeriod, anchor: Date,
                             now: Date, liveRecords: [UsageRecord]?,
                             completion: @escaping (PeriodReport?) -> Void) {
        let snapshots = self.snapshots
        DispatchQueue.global(qos: .userInitiated).async { [deliver] in
            let todayKey = DayBucket.dayKey(now)
            let pricedAt = Int(now.timeIntervalSince1970)
            // Frozen completed days from snapshots; never use a snapshot for today.
            let frozen = (snapshots?.snapshots() ?? []).filter { $0.date < todayKey }
            let have = Set(frozen.map(\.date))
            let range = period.range(containing: anchor)
            // Today's records, collapsed ONCE with the dashboard's exact semantics
            // (keyless records all kept) — the summary row, the hour buckets, and
            // the week slots below all share this instead of re-collapsing.
            let todayCollapsed = liveRecords.map { live in
                Dedup.collapse(live.filter { DayBucket.day(epoch: $0.epoch) == todayKey })
            }
            // Un-snapshotted days from the raw archive (already collapsed by the
            // archive read). Nearly every past day is frozen, so those days are
            // dropped before the per-day aggregation; today is dropped too when
            // the live stream supersedes it. The all-time period spans whatever
            // the archive holds rather than a range's month window.
            let segments = period == .all ? archive.availableMonths() : range.segmentsToRead()
            let archiveRecords = archive.records(forMonths: segments)
            var excludedDays = have
            if todayCollapsed != nil { excludedDays.insert(todayKey) }
            let archived = UsageAggregator
                .daySummaries(archiveRecords, pricedAt: pricedAt, frozen: false,
                              assumeCollapsed: true, excludingDays: excludedDays)
            // Today, straight from the logs, so this figure matches the menu bar.
            var today: [DaySnapshot] = []
            if let todayCollapsed {
                today = UsageAggregator.daySummaries(todayCollapsed, pricedAt: pricedAt,
                                                     frozen: false, assumeCollapsed: true)
            }
            // The day view swaps the (single-bar) daily chart for an hour-of-day
            // one: today buckets the live stream, a past day its archive records.
            // Coarse epoch bounds prune the 3-month archive union with Int compares
            // before any per-record calendar math.
            let startEpoch = Int(range.start.timeIntervalSince1970)
            let endEpoch = Int(range.end.timeIntervalSince1970)
            var hourly: [TokenCounts]?
            if period == .day {
                if let todayCollapsed, range.key == todayKey {
                    hourly = UsageAggregator.hourlyCounts(collapsed: todayCollapsed, day: range.key)
                } else {
                    let dayRecords = archiveRecords.filter { $0.epoch >= startEpoch && $0.epoch < endEpoch }
                    hourly = UsageAggregator.hourlyCounts(collapsed: dayRecords, day: range.key)
                }
            }
            // The week view's click-to-toggle density: PER-HOUR slots across every
            // day of the week (the view regroups to the chosen width without a
            // reload) — archive days plus the live today, the same source split
            // the day rows use.
            var fine: [PeriodReport.SlotBucket]?
            if period == .week {
                var dayKeys: [String] = []
                var cursor = range.start
                while cursor < range.end {
                    dayKeys.append(DayBucket.dayKey(cursor))
                    cursor = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? range.end
                }
                let todayStartEpoch = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
                var slotRecords = archiveRecords.filter { r in
                    r.epoch >= startEpoch && r.epoch < endEpoch
                        && (todayCollapsed == nil || r.epoch < todayStartEpoch)
                }
                if let todayCollapsed { slotRecords += todayCollapsed }
                fine = UsageAggregator.slotCounts(collapsed: slotRecords, days: dayKeys, slotHours: 1)
            }
            let report = period == .all
                ? PeriodReport.makeAllTime(daySummaries: frozen + archived + today, now: now)
                : PeriodReport.make(daySummaries: frozen + archived + today,
                                    period: period, anchor: anchor, now: now,
                                    hourly: hourly, fine: fine)
            deliver { completion(report) }
        }
    }

    /// Freeze finalized days into the snapshot store (cheap, off-thread; one real
    /// sweep per calendar day). No-op when archiving is off or unavailable. Pass
    /// `liveRecords` (the tick's fetch) so recent days freeze from the logs.
    func refreshSnapshots(now: Date = Date(), liveRecords: [UsageRecord]? = nil) {
        guard isArchiveEnabled(), let archive, let snapshots else { return }
        DispatchQueue.global(qos: .utility).async {
            snapshots.refresh(now: now, archive: archive, liveRecords: liveRecords)
        }
    }

    /// Months ("YYYY-MM") the archive holds, ascending — bounds the report navigator.
    func archivedMonths() -> [String] { archive?.availableMonths() ?? [] }

    /// One-time (idempotent) backfill of all currently-available history into the
    /// archive. No-op when archiving is off, or when already backfilled unless `force`
    /// (used when the user re-enables archiving, to fill any gap accrued while off).
    func backfillArchiveIfNeeded(force: Bool = false) {
        guard isArchiveEnabled(), let archive, force || !archive.isBackfilled else { return }
        CombinedProvider(localProviders).fetchRecords { records in
            archive.backfill(records)
        }
    }

    /// Best-effort synchronous publish + archive for app termination, bounded by
    /// `timeout` so quitting is never blocked for long.
    func flushLocal(timeout: TimeInterval = 2) {
        let wantPublish = isSyncEnabled()
        let wantArchive = isArchiveEnabled()
        guard wantPublish || wantArchive else { return }
        let semaphore = DispatchSemaphore(value: 0)
        CombinedProvider(localProviders).fetchRecords { [weak self] records in
            if wantPublish { self?.publisher.publishIfNeeded(localRecords: records, force: true) }
            if wantArchive { self?.archive?.ingest(records) }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Stop participating: delete this machine's published file so peers no longer
    /// count it. Called when the user turns sync off.
    func retractOwnFile() {
        publisher.retract()
    }

    /// Best-effort synchronous publish for app termination — bypasses the throttle but
    /// still only writes when the record set changed. Bounded by `timeout` so quitting
    /// is never blocked for long.
    func flushPublish(timeout: TimeInterval = 2) {
        guard isSyncEnabled() else { return }
        let semaphore = DispatchSemaphore(value: 0)
        CombinedProvider(localProviders).fetchRecords { [publisher] records in
            publisher.publishIfNeeded(localRecords: records, force: true)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }
}
