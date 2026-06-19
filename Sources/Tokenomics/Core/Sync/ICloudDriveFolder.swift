import Foundation

/// `PeerFolder` backed by the user's iCloud Drive.
///
/// Writes plain files under CloudDocs — NO app container, entitlement, or iCloud
/// capability; a non-sandboxed app may write there directly and iCloud's daemons
/// sync the files to the user's other Macs. `directoryURL` is nil when iCloud Drive
/// is unavailable (not signed in / iCloud Drive off), so the feature degrades to
/// local-only rather than failing.
///
/// Reads gate on the ubiquitous download status so an undownloaded placeholder is
/// never parsed as an empty/partial file; writes go through `NSFileCoordinator` with
/// atomic replacement so a peer never sees a half-written file.
struct ICloudDriveFolder: PeerFolder {
    /// Re-resolved on each access, so the feature activates when the user signs into
    /// iCloud without needing an app relaunch. nil ⇒ iCloud Drive unavailable.
    var directoryURL: URL? { Self.resolveDirectory() }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Tokenomics/peers`, or nil when
    /// the CloudDocs root is absent. Does NOT create the subdir — only the publish
    /// path needs it writable (see `writeOwnFile`), so a read cycle never writes here.
    private static func resolveDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloudDocs = home.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDir), isDir.boolValue
        else { return nil }

        return cloudDocs.appendingPathComponent("Tokenomics/peers", isDirectory: true)
    }

    func peerFileURLs() -> [URL] {
        guard let dir = directoryURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "ndjson" }
    }

    func readData(at url: URL) -> Data? {
        // Pull down an undownloaded placeholder; a no-op when already current.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        // If it isn't materialized yet, skip this cycle — the caller retains the
        // file's last-known records so the total doesn't flicker to zero.
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           values.ubiquitousItemDownloadingStatus == .notDownloaded {
            return nil
        }
        return coordinatedRead(url)
    }

    func writeOwnFile(_ data: Data, machineId: String) throws {
        guard let dir = directoryURL else { throw CocoaError(.fileNoSuchFile) }
        // Create the subdir only on the publish path; a failure here (e.g. TCC denial)
        // surfaces as a thrown error instead of being silently swallowed on read.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try coordinatedWrite(data, to: dir.appendingPathComponent(peerFileName(forMachine: machineId)))
    }

    func removeOwnFile(machineId: String) {
        guard let dir = directoryURL else { return }
        let url = dir.appendingPathComponent(peerFileName(forMachine: machineId))
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }

    // MARK: - File coordination

    private func coordinatedRead(_ url: URL) -> Data? {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var data: Data?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordError) { src in
            data = try? Data(contentsOf: src)
        }
        return data
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { dst in
            do { try data.write(to: dst, options: .atomic) } catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }
}
