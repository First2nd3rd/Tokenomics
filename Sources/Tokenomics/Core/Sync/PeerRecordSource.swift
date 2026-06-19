import Foundation

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

    private struct CachedPeer {
        let machineId: String
        let publishedAt: Int
        let records: [UsageRecord]
    }

    private let folder: PeerFolder
    private let ownMachineId: String
    private let lock = NSLock()
    private var lastKnown: [String: CachedPeer] = [:]   // file path -> last good read

    init(folder: PeerFolder, ownMachineId: String = DeviceIdentity.id) {
        self.folder = folder
        self.ownMachineId = ownMachineId
    }

    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.readPeers())
        }
    }

    /// Read + union all peer files (own excluded, one newest file per machine),
    /// retaining last-known records for files that are momentarily unreadable.
    func readPeers() -> [UsageRecord] {
        let urls = folder.peerFileURLs()
        var present = Set<String>()
        var newestByMachine: [String: CachedPeer] = [:]

        for url in urls {
            let path = url.path
            present.insert(path)

            let peer: CachedPeer
            if let data = folder.readData(at: url), let contents = PeerFile.decode(data) {
                peer = CachedPeer(machineId: contents.manifest.machineId,
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
            // Among files claiming the same machine, keep only the newest.
            if let existing = newestByMachine[peer.machineId], existing.publishedAt >= peer.publishedAt { continue }
            newestByMachine[peer.machineId] = peer
        }

        // Drop memory of files that are gone for good.
        lock.lock()
        lastKnown = lastKnown.filter { present.contains($0.key) }
        lock.unlock()

        return newestByMachine.values.flatMap { $0.records }
    }
}
