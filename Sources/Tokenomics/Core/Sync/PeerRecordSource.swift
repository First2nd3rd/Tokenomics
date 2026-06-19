import Foundation

/// Lightweight metadata about a peer's published file, for the by-machine view and
/// status line. Captured on each read alongside the records.
struct PeerInfo {
    let machineId: String
    let displayName: String
    let publishedAt: Int     // UTC epoch of the peer's last publish
}

/// A usage source backed by peers' published files. Returns every peer's records
/// (each tagged with its machine), SKIPPING this machine's own file — identified by
/// the manifest id, so a renamed or iCloud-conflict copy of our own file is excluded.
///
/// Files are coalesced by machine id, keeping only the newest (largest
/// `publishedAt`): an iCloud conflict copy of a PEER's file ("tok-<id> 2.ndjson")
/// carries the same id, so without this it would be read alongside the original and
/// double-count that peer's keyless records (keyed records collapse safely; keyless
/// ones don't). When a file is transiently unreadable (an undownloaded placeholder),
/// its last-known contents are retained so the total doesn't flicker to zero.
///
/// It is just another `UsageProvider`: its records join the union and the single
/// global `Dedup.collapse` runs over local + peer records together — so even if a
/// peer also carries one of our turns (a mirror-synced dotfile), it's counted once.
final class PeerRecordSource: UsageProvider {
    let id = "peers"

    /// Ignore a peer that hasn't published within this window (a retired / long-off
    /// Mac), so it drops out of the totals and the by-machine view instead of
    /// lingering forever. The file itself stays in iCloud until that Mac retracts it.
    static let staleAfter: TimeInterval = 7 * 86_400

    private struct CachedPeer {
        let machineId: String
        let displayName: String
        let publishedAt: Int
        let records: [UsageRecord]
    }

    private let folder: PeerFolder
    private let ownMachineId: String
    private let lock = NSLock()
    private var lastKnown: [String: CachedPeer] = [:]   // file path -> last good read
    private var lastInfos: [PeerInfo] = []              // peers seen on the last read

    init(folder: PeerFolder, ownMachineId: String = DeviceIdentity.id) {
        self.folder = folder
        self.ownMachineId = ownMachineId
    }

    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.readPeers())
        }
    }

    /// Metadata (id, name, last-publish time) for the peers seen on the last read —
    /// drives the by-machine view's names + "synced N ago". Read after `readPeers`.
    func peerInfos() -> [PeerInfo] {
        lock.lock(); defer { lock.unlock() }
        return lastInfos
    }

    /// Read + union all peer files (own excluded, one newest file per machine),
    /// retaining last-known records for files that are momentarily unreadable.
    func readPeers(now: Date = Date()) -> [UsageRecord] {
        let urls = folder.peerFileURLs()
        let staleCutoff = Int(now.timeIntervalSince1970 - Self.staleAfter)
        var present = Set<String>()
        var newestByMachine: [String: CachedPeer] = [:]

        for url in urls {
            let path = url.path
            present.insert(path)

            let peer: CachedPeer
            if let data = folder.readData(at: url), let contents = PeerFile.decode(data) {
                peer = CachedPeer(machineId: contents.manifest.machineId,
                                  displayName: contents.manifest.displayName,
                                  publishedAt: contents.manifest.publishedAt,
                                  records: contents.records)
                lock.lock(); lastKnown[path] = peer; lock.unlock()
            } else {
                // Unreadable this cycle (placeholder / mid-download): fall back.
                lock.lock(); let prev = lastKnown[path]; lock.unlock()
                guard let prev else { continue }
                peer = prev
            }

            if peer.machineId == ownMachineId { continue }   // our own file / its conflict copy
            if peer.publishedAt < staleCutoff { continue }   // GC: silent > 7 days, ignore it
            // Among files claiming the same machine, keep only the newest.
            if let existing = newestByMachine[peer.machineId], existing.publishedAt >= peer.publishedAt { continue }
            newestByMachine[peer.machineId] = peer
        }

        lock.lock()
        lastKnown = lastKnown.filter { present.contains($0.key) }    // drop files gone for good
        lastInfos = newestByMachine.values.map {
            PeerInfo(machineId: $0.machineId, displayName: $0.displayName, publishedAt: $0.publishedAt)
        }
        lock.unlock()

        return newestByMachine.values.flatMap { $0.records }
    }
}
