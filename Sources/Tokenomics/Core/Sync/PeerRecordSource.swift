import Foundation

/// A usage source backed by peers' published files. Returns every peer's records
/// (each tagged with its machine), SKIPPING this machine's own file — identified by
/// the manifest id, so a renamed or iCloud-conflict copy of our own file is still
/// excluded. When a file is transiently unreadable (an undownloaded iCloud
/// placeholder), its last-known records are retained so the headline total doesn't
/// flicker to zero, then recover, every refresh.
///
/// It is just another `UsageProvider`: its records join the union and the single
/// global `Dedup.collapse` runs over local + peer records together — so even if a
/// peer also carries one of our turns (a mirror-synced dotfile), it's counted once.
final class PeerRecordSource: UsageProvider {
    let id = "peers"

    private let folder: PeerFolder
    private let ownMachineId: String
    private let lock = NSLock()
    private var lastKnown: [String: [UsageRecord]] = [:]   // file path -> records

    init(folder: PeerFolder, ownMachineId: String = DeviceIdentity.id) {
        self.folder = folder
        self.ownMachineId = ownMachineId
    }

    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            completion(self.readPeers())
        }
    }

    /// Read + union all peer files (own excluded), retaining last-known records for
    /// files that are momentarily unreadable.
    func readPeers() -> [UsageRecord] {
        let urls = folder.peerFileURLs()
        var all: [UsageRecord] = []
        var present = Set<String>()

        for url in urls {
            let path = url.path
            present.insert(path)

            if let data = folder.readData(at: url), let contents = PeerFile.decode(data) {
                if contents.manifest.machineId == ownMachineId { continue }   // our own file
                lock.lock(); lastKnown[path] = contents.records; lock.unlock()
                all.append(contentsOf: contents.records)
            } else {
                // Unreadable this cycle (placeholder / mid-download): keep last-known.
                lock.lock()
                if let prev = lastKnown[path] { all.append(contentsOf: prev) }
                lock.unlock()
            }
        }

        // Drop memory of files that are gone for good.
        lock.lock()
        lastKnown = lastKnown.filter { present.contains($0.key) }
        lock.unlock()
        return all
    }
}
