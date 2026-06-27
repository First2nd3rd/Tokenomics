import Foundation

/// The durable, log-rotation-surviving record store.
///
/// The parse cache mirrors the current logs and drops whatever Claude rotates away;
/// the archive keeps every record it has ever observed, in monthly segments under
/// Application Support, so a report stays correct long after the source logs are
/// gone. Segments are pure storage — the month boundary is just log rotation, not a
/// report period; analysis reads across whatever range it needs.
///
/// This is the READ + storage core. Idempotent ingest and first-run backfill build
/// on top of it.
final class UsageArchive {
    private let folder: ArchiveFolder

    init(folder: ArchiveFolder) { self.folder = folder }

    /// Months ("YYYY-MM") that have a segment on disk, ascending.
    func availableMonths() -> [String] {
        folder.segmentURLs()
            .compactMap { archiveMonth(fromSegmentName: $0.lastPathComponent) }
            .sorted()
    }

    /// Collapsed records across the given months. Reading the segments and collapsing
    /// ONCE (keyless folded too) yields each unique event exactly once, regardless of
    /// superseded streamed-output lines a wholesale rewrite may have left behind.
    func records(forMonths months: [String]) -> [UsageRecord] {
        guard let dir = folder.directoryURL else { return [] }
        var raw: [UsageRecord] = []
        for month in months {
            let url = dir.appendingPathComponent(archiveSegmentName(forMonth: month))
            guard let data = folder.readData(at: url),
                  let contents = ArchiveFile.decode(data) else { continue }
            raw.append(contentsOf: contents.records)
        }
        return Dedup.collapse(raw, foldKeyless: true)
    }

    /// Convenience: every record in the archive, collapsed. O(all history) — for
    /// diagnostics and tests, not the per-report read path.
    func allRecords() -> [UsageRecord] { records(forMonths: availableMonths()) }
}
