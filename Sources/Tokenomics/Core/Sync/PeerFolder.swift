import Foundation

/// The transport seam for cross-machine sync: a directory of per-machine NDJSON
/// files. iCloud Drive is one implementation; a plain local directory backs tests,
/// and a future SSH/remote drop is just another conformer. Correctness lives ABOVE
/// this layer (record-level dedup), so the seam only has to move bytes.
protocol PeerFolder {
    /// The backing directory, or nil when unavailable (e.g. iCloud off) — the feature
    /// then degrades to local-only rather than failing.
    var directoryURL: URL? { get }

    /// URLs of all peer files currently present.
    func peerFileURLs() -> [URL]

    /// Read a file's bytes, materializing it first if needed; nil if it can't be read
    /// yet (e.g. an undownloaded iCloud placeholder).
    func readData(at url: URL) -> Data?

    /// Atomically (re)write this machine's own file.
    func writeOwnFile(_ data: Data, machineId: String) throws

    /// Best-effort delete of this machine's own file (when the user turns sync off),
    /// so peers stop counting this Mac. Errors are ignored.
    func removeOwnFile(machineId: String)
}

/// One file per machine, named by its id (single-writer ⇒ no write conflicts).
func peerFileName(forMachine id: String) -> String { "tok-\(id).ndjson" }

/// A plain on-disk directory — used by tests and as the substrate the iCloud
/// implementation specializes.
struct LocalFolder: PeerFolder {
    let directoryURL: URL?

    init(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directoryURL = dir
    }

    func peerFileURLs() -> [URL] {
        guard let dir = directoryURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "ndjson" }
    }

    func readData(at url: URL) -> Data? { try? Data(contentsOf: url) }

    func writeOwnFile(_ data: Data, machineId: String) throws {
        guard let dir = directoryURL else { throw CocoaError(.fileNoSuchFile) }
        try data.write(to: dir.appendingPathComponent(peerFileName(forMachine: machineId)), options: .atomic)
    }

    func removeOwnFile(machineId: String) {
        guard let dir = directoryURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(peerFileName(forMachine: machineId)))
    }
}
