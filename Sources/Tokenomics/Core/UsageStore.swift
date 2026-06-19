import Foundation

/// A point-in-time view of usage: the per-day series, sorted ascending by date.
struct UsageSnapshot {
    let days: [DailyUsage]
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
    private let isSyncEnabled: () -> Bool
    private let deliver: (@escaping () -> Void) -> Void

    init(localProviders: [UsageProvider] = [ClaudeNativeProvider(), CodexProvider()],
         folder: PeerFolder = ICloudDriveFolder(),
         machineId: String = DeviceIdentity.id,
         isSyncEnabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "syncEnabled") },
         deliver: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }) {
        self.localProviders = localProviders
        self.peerSource = PeerRecordSource(folder: folder, ownMachineId: machineId)
        self.publisher = PeerPublisher(folder: folder, machineId: machineId)
        self.isSyncEnabled = isSyncEnabled
        self.deliver = deliver
    }

    /// The provider feeding the views: local always, peers folded in when sync is on.
    private var provider: UsageProvider {
        isSyncEnabled() ? CombinedProvider(localProviders + [peerSource]) : CombinedProvider(localProviders)
    }

    /// Per-vendor daily series (provider id → days), delivered ready for UI. The
    /// single source for both the headline and the per-vendor break-even.
    func refreshByVendor(completion: @escaping ([String: [DailyUsage]]) -> Void) {
        provider.fetchDailyByVendor { byVendor in self.deliver { completion(byVendor) } }
    }

    /// Day→minute matrix (today + the `lastDays` prior days with data). Providers
    /// return their full matrix; the merge happens first and the window is trimmed
    /// once here, so it stays exact across providers.
    func refreshMatrix(now: Date = Date(), lastDays: Int, completion: @escaping ([String: [MinuteBucket]]) -> Void) {
        provider.fetchDayMinuteMatrix { matrix in
            let trimmed = DayBucket.recentDays(matrix, now: now, count: lastDays)
            self.deliver { completion(trimmed) }
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
