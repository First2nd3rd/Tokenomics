import Foundation

/// The storage seam for the durable archive: a directory of monthly segment files.
/// A plain Application Support directory backs the app; tests inject a temp dir. Like
/// the peer seam, correctness (record-level dedup) lives ABOVE this layer, so the
/// seam only has to move bytes — and whole-file writes are atomic.
protocol ArchiveFolder {
    /// The backing directory, or nil when unavailable (Application Support
    /// unreachable) — the feature then no-ops rather than crashing.
    var directoryURL: URL? { get }

    /// URLs of all archive segment files present.
    func segmentURLs() -> [URL]

    func readData(at url: URL) -> Data?

    /// Atomically (re)write one month's whole segment (temp file + rename). A crash
    /// can only damage the temp file; the previously-good segment is never torn.
    func writeSegment(_ data: Data, month: String) throws
}

/// Segment file name for a month key ("YYYY-MM"), e.g. "archive-2026-06.ndjson".
func archiveSegmentName(forMonth month: String) -> String { "archive-\(month).ndjson" }

/// The "YYYY-MM" month embedded in a segment file name, or nil if it isn't one.
func archiveMonth(fromSegmentName name: String) -> String? {
    let prefix = "archive-", suffix = ".ndjson"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
    let month = name.dropFirst(prefix.count).dropLast(suffix.count)
    return month.isEmpty ? nil : String(month)
}

/// A plain on-disk directory; default substrate for the archive and for tests.
struct LocalArchiveFolder: ArchiveFolder {
    let directoryURL: URL?

    /// Backed by an explicit directory (tests pass a temp dir).
    init(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directoryURL = dir
    }

    /// The app's durable archive dir under Application Support; nil if unreachable.
    init?() {
        guard let dir = AppPaths.applicationSupport("archive") else { return nil }
        self.directoryURL = dir
    }

    func segmentURLs() -> [URL] {
        guard let dir = directoryURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { archiveMonth(fromSegmentName: $0.lastPathComponent) != nil }
    }

    func readData(at url: URL) -> Data? { try? Data(contentsOf: url) }

    func writeSegment(_ data: Data, month: String) throws {
        guard let dir = directoryURL else { throw CocoaError(.fileNoSuchFile) }
        try data.write(to: dir.appendingPathComponent(archiveSegmentName(forMonth: month)), options: .atomic)
    }
}
