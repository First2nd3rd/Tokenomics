import CryptoKit
import Foundation

/// A per-file parse cache keyed by (mtime, size): a source file is re-parsed only
/// when it changes on disk, so recurring refreshes stay cheap once warm. Parsed
/// records persist under a cache directory with ONE file per source file, so a
/// refresh persists only the sources that actually changed (typically just the
/// live session's log) instead of rewriting the whole cache. A full rewrite per
/// tick previously dirtied ~2 GB/day and tripped macOS's disk-writes limit.
///
/// Generic over the record type each provider stores. Each cache file holds one
/// JSON object per source file, so load memory stays bounded by the largest
/// single source, same as the previous one-NDJSON-line-per-source layout.
///
/// All access is serialized on an internal queue, so a provider can call
/// `records(for:parse:)` from any background thread without further locking.
final class FileRecordCache<Record: Codable> {
    private let directoryName: String       // carries the format version, e.g. "records-v4"
    private let legacyFiles: [String]       // superseded cache artifacts, deleted on first load
    private let saveThrottle: TimeInterval  // don't touch the on-disk cache more often than this
    private let queue: DispatchQueue

    private var fileCache: [String: Cached] = [:]
    /// (mtime, size) as currently persisted per source path. Save compares against
    /// this to write only changed entries and delete entries whose source is gone;
    /// it also carries over saves skipped by the throttle to the next opportunity.
    private var persisted: [String: Stamp] = [:]
    private var didLoadDisk = false
    private var lastSavedAt = Date.distantPast

    init(cacheDirectoryName: String, queueLabel: String,
         saveThrottle: TimeInterval = 120, legacyFiles: [String] = []) {
        self.directoryName = cacheDirectoryName
        self.legacyFiles = legacyFiles
        self.saveThrottle = saveThrottle
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    /// All parsed records for `files`, re-parsing (via `parse`) only those whose
    /// mtime/size changed since last seen; unchanged files reuse cached records.
    /// Serialized internally.
    func records(for files: [URL], parse: (URL) -> [Record]) -> [Record] {
        queue.sync {
            if !didLoadDisk {
                loadDisk()
                removeLegacyFiles()
                didLoadDisk = true
            }

            let fm = FileManager.default
            var next: [String: Cached] = [:]
            var out: [Record] = []

            for file in files {
                let path = file.path
                let attrs = try? fm.attributesOfItem(atPath: path)
                // Whole-second epoch (Int) so it round-trips exactly through JSON,
                // unlike a Double Date; paired with size it reliably detects appends.
                let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
                let size = (attrs?[.size] as? Int) ?? -1

                let cached: Cached
                if let hit = fileCache[path], hit.mtime == mtime, hit.size == size {
                    cached = hit
                } else {
                    cached = Cached(mtime: mtime, size: size, records: parse(file))
                }
                next[path] = cached
                out.append(contentsOf: cached.records)
            }
            fileCache = next

            saveChangesIfDue()
            return out
        }
    }

    // MARK: - Persistence

    /// Cached parse result for one file, valid while its mtime + size are unchanged.
    private struct Cached: Codable {
        let mtime: Int
        let size: Int
        let records: [Record]
        enum CodingKeys: String, CodingKey { case mtime = "t", size = "s", records = "rs" }
    }

    private struct Stamp: Equatable {
        let mtime: Int
        let size: Int
        init(_ c: Cached) { mtime = c.mtime; size = c.size }
        init(mtime: Int, size: Int) { self.mtime = mtime; self.size = size }
    }

    /// One cache file = one source file's parse result.
    private struct DiskLine: Codable {
        let f: String       // source file path
        let t: Int          // mtime (epoch seconds)
        let s: Int          // size
        let rs: [Record]
    }

    private var diskDirectory: URL? {
        AppPaths.caches()?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Cache file for one source path: SHA256-prefix of the path. A 64-bit prefix
    /// collision would only make two sources share a slot — the mtime/size check
    /// then treats the loser as changed and re-parses; never wrong data.
    private static func cacheFileName(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func loadDisk() {
        guard let dir = diskDirectory,
              let items = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        for url in items where url.pathExtension == "json" {
            autoreleasepool {
                guard let data = try? Data(contentsOf: url),
                      let line = try? decoder.decode(DiskLine.self, from: data) else { return }
                fileCache[line.f] = Cached(mtime: line.t, size: line.s, records: line.rs)
                persisted[line.f] = Stamp(mtime: line.t, size: line.s)
            }
        }
    }

    /// Write cache files for sources whose persisted stamp is stale, delete cache
    /// files for sources that disappeared, throttled to one pass per `saveThrottle`.
    private func saveChangesIfDue() {
        guard Date().timeIntervalSince(lastSavedAt) > saveThrottle else { return }
        guard let dir = diskDirectory else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        var wrote = false
        for (path, cached) in fileCache where persisted[path] != Stamp(cached) {
            autoreleasepool {
                let line = DiskLine(f: path, t: cached.mtime, s: cached.size, rs: cached.records)
                guard let data = try? encoder.encode(line) else { return }
                let url = dir.appendingPathComponent(Self.cacheFileName(for: path))
                guard (try? data.write(to: url, options: .atomic)) != nil else { return }
                persisted[path] = Stamp(cached)
                wrote = true
            }
        }
        for path in persisted.keys.filter({ fileCache[$0] == nil }) {
            try? fm.removeItem(at: dir.appendingPathComponent(Self.cacheFileName(for: path)))
            persisted.removeValue(forKey: path)
            wrote = true
        }
        if wrote { lastSavedAt = Date() }
    }

    /// Delete superseded cache artifacts (old single-NDJSON caches and their
    /// atomic-write temp leftovers). Runs once, on first disk load.
    private func removeLegacyFiles() {
        guard !legacyFiles.isEmpty, let caches = AppPaths.caches(),
              let items = try? FileManager.default.contentsOfDirectory(
                  at: caches, includingPropertiesForKeys: nil) else { return }
        for url in items where legacyFiles.contains(where: { url.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
