import Foundation

/// A per-file parse cache keyed by (mtime, size): a source file is re-parsed only
/// when it changes on disk, so recurring refreshes stay cheap once warm. Parsed
/// records persist to an NDJSON file (one line per source file) so a cold start
/// reuses the previous scan instead of re-reading every log.
///
/// Generic over the record type each provider stores. Streaming the NDJSON
/// line-by-line keeps load memory bounded — decoding one giant JSON object instead
/// builds a ~30x intermediate tree (measured: a 4 MB file → ~120 MB peak).
///
/// All access is serialized on an internal queue, so a provider can call
/// `records(for:parse:)` from any background thread without further locking.
final class FileRecordCache<Record: Codable> {
    private let diskFileName: String        // carries the format version, e.g. "records-v1.ndjson"
    private let saveThrottle: TimeInterval  // don't rewrite the on-disk cache more often than this
    private let queue: DispatchQueue

    private var fileCache: [String: Cached] = [:]
    private var didLoadDisk = false
    private var lastSavedAt = Date.distantPast

    init(diskFileName: String, queueLabel: String, saveThrottle: TimeInterval = 120) {
        self.diskFileName = diskFileName
        self.saveThrottle = saveThrottle
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }

    /// All parsed records for `files`, re-parsing (via `parse`) only those whose
    /// mtime/size changed since last seen; unchanged files reuse cached records.
    /// Serialized internally.
    func records(for files: [URL], parse: (URL) -> [Record]) -> [Record] {
        queue.sync {
            if !didLoadDisk {
                fileCache = loadDisk() ?? [:]
                didLoadDisk = true
            }

            let fm = FileManager.default
            var next: [String: Cached] = [:]
            var out: [Record] = []
            var changed = false

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
                    changed = true
                }
                next[path] = cached
                out.append(contentsOf: cached.records)
            }
            if next.count != fileCache.count { changed = true }   // files removed
            fileCache = next

            if changed, Date().timeIntervalSince(lastSavedAt) > saveThrottle {
                saveDisk(next)
                lastSavedAt = Date()
            }
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

    /// One NDJSON line = one source file's parse result.
    private struct DiskLine: Codable {
        let f: String       // source file path
        let t: Int          // mtime (epoch seconds)
        let s: Int          // size
        let rs: [Record]
    }

    private var diskURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = caches.appendingPathComponent("me.stfang.tokenomics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(diskFileName)
    }

    private func loadDisk() -> [String: Cached]? {
        guard let url = diskURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        var cache: [String: Cached] = [:]
        LineReader.forEachLine(of: url) { lineData in
            guard let line = try? decoder.decode(DiskLine.self, from: lineData) else { return }
            cache[line.f] = Cached(mtime: line.t, size: line.s, records: line.rs)
        }
        return cache.isEmpty ? nil : cache
    }

    private func saveDisk(_ files: [String: Cached]) {
        guard let url = diskURL else { return }
        let encoder = JSONEncoder()
        var out = Data()
        for (path, cached) in files {
            autoreleasepool {
                let line = DiskLine(f: path, t: cached.mtime, s: cached.size, rs: cached.records)
                if let encoded = try? encoder.encode(line) {
                    out.append(encoded)
                    out.append(0x0A)
                }
            }
        }
        try? out.write(to: url, options: .atomic)
    }
}
