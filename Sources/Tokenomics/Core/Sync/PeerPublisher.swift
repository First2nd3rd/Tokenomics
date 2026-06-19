import Foundation

/// Publishes THIS machine's records to the shared folder as one NDJSON file. Writes
/// only when the record set changed AND a throttle interval has elapsed, so it never
/// churns iCloud on an idle refresh. Failures are swallowed — publishing is additive
/// and must not break the local refresh.
final class PeerPublisher {
    private let folder: PeerFolder
    private let machineId: String
    private let displayName: () -> String
    private let appVersion: String
    private let windowDays: Int
    private let throttle: TimeInterval

    private let lock = NSLock()
    private var lastFingerprint: Int?
    private var lastPublishedAt = Date.distantPast

    init(folder: PeerFolder,
         machineId: String = DeviceIdentity.id,
         displayName: @escaping () -> String = { DeviceIdentity.displayName() },
         appVersion: String = PeerPublisher.bundleVersion,
         windowDays: Int = 90,
         throttle: TimeInterval = 120) {
        self.folder = folder
        self.machineId = machineId
        self.displayName = displayName
        self.appVersion = appVersion
        self.windowDays = windowDays
        self.throttle = throttle
    }

    /// Publish `localRecords` (this machine's records) if they changed since the last
    /// publish and the throttle has elapsed. `force` (used at app quit) bypasses the
    /// throttle but still respects only-on-change, so a quit with no new usage writes
    /// nothing. `now` is injectable for tests. Returns whether a file was written.
    @discardableResult
    func publishIfNeeded(localRecords: [UsageRecord], now: Date = Date(), force: Bool = false) -> Bool {
        let cutoff = Int(now.timeIntervalSince1970) - windowDays * 86_400
        let windowed = localRecords.filter { $0.epoch >= cutoff }
        let fingerprint = Self.fingerprint(windowed)

        // First call after launch: seed the baseline from our already-published file,
        // so a relaunch with unchanged data writes nothing ("no update ⇒ don't touch
        // iCloud"). Done OUTSIDE the lock — currentlyPublishedFingerprint does blocking
        // iCloud I/O, and the lock must never be held across I/O or concurrent publishes
        // would wedge behind it.
        lock.lock(); let needsSeed = lastFingerprint == nil; lock.unlock()
        if needsSeed {
            let seeded = currentlyPublishedFingerprint()
            lock.lock(); if lastFingerprint == nil { lastFingerprint = seeded }; lock.unlock()
        }

        lock.lock()
        let unchanged = fingerprint == lastFingerprint
        let tooSoon = !force && now.timeIntervalSince(lastPublishedAt) < throttle
        lock.unlock()
        guard !unchanged, !tooSoon else { return false }

        let data = PeerFile.encode(records: windowed, machineId: machineId,
                                   displayName: displayName(), appVersion: appVersion,
                                   publishedAt: Int(now.timeIntervalSince1970), windowDays: windowDays)
        do {
            try folder.writeOwnFile(data, machineId: machineId)
            lock.lock(); lastFingerprint = fingerprint; lastPublishedAt = now; lock.unlock()
            return true
        } catch {
            return false   // degrade silently
        }
    }

    /// Delete this machine's published file (when the user turns sync off) and reset
    /// the change baseline, so re-enabling later republishes from scratch.
    func retract() {
        folder.removeOwnFile(machineId: machineId)
        lock.lock()
        lastFingerprint = nil
        lastPublishedAt = .distantPast
        lock.unlock()
    }

    // MARK: - Helpers

    /// Fingerprint of our already-published file, used to seed the change baseline so a
    /// relaunch with unchanged data doesn't rewrite. nil when no file exists yet.
    private func currentlyPublishedFingerprint() -> Int? {
        guard let url = folder.directoryURL?.appendingPathComponent(peerFileName(forMachine: machineId)),
              let data = folder.readData(at: url),
              let contents = PeerFile.decode(data)
        else { return nil }
        return Self.fingerprint(contents.records)
    }

    /// Order-independent fingerprint of the record set; changes when records are added
    /// or their token counts grow. Deterministic (no per-process hash seed), so it is
    /// comparable across calls within a process.
    static func fingerprint(_ records: [UsageRecord]) -> Int {
        var total = 0, maxEpoch = 0
        for r in records {
            total = total &+ r.input &+ r.output &+ r.cacheCreation &+ r.cacheRead
            maxEpoch = max(maxEpoch, r.epoch)
        }
        return records.count &* 1_000_003 &+ total &+ maxEpoch
    }

    static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
