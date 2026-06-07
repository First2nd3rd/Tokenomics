import Testing
import Foundation
@testable import Tokenomics

/// A trivial Codable record used to exercise the generic cache.
private struct Rec: Codable, Equatable, Hashable {
    let v: Int
}

/// Thread-safe counter that records how many times the parse closure ran,
/// and which file paths it was invoked for. The cache serializes calls on an
/// internal queue, but swift-testing runs separate tests in parallel, so we
/// keep each box local to a single test and guard mutation with a lock to be safe.
private final class ParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _paths: [String] = []

    func record(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        _calls += 1
        _paths.append(path)
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _paths
    }
}

/// Per-test scratch space: a unique temp directory holding source files plus a
/// unique on-disk cache file name. Cleaned up explicitly at the end of each test.
private struct Scratch {
    let dir: URL
    let diskFileName: String

    init() {
        let unique = "FileRecordCacheTests-\(UUID().uuidString)"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(unique, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        diskFileName = "records-\(UUID().uuidString).ndjson"
    }

    /// Writes `text` to `name` inside the scratch dir and returns its URL.
    @discardableResult
    func writeFile(_ name: String, _ text: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try? text.data(using: .utf8)!.write(to: url, options: .atomic)
        return url
    }

    /// Appends bytes to an existing file so both size and (typically) mtime change.
    func append(_ name: String, _ text: String) {
        let url = dir.appendingPathComponent(name)
        let existing = (try? Data(contentsOf: url)) ?? Data()
        let combined = existing + text.data(using: .utf8)!
        try? combined.write(to: url, options: .atomic)
        bumpModificationDate(url)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// Forces an mtime change. mtime is stored at whole-second resolution in the
    /// cache, so an append that happens within the same wall-clock second would
    /// otherwise leave mtime identical; size still differs, but we bump mtime to
    /// make the change unambiguous and deterministic.
    func bumpModificationDate(_ url: URL) {
        let future = Date().addingTimeInterval(5)
        try? FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)
    }

    /// The on-disk cache path the production code computes:
    /// caches dir + "me.stfang.tokenomics" + diskFileName.
    var diskCacheURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return caches
            .appendingPathComponent("me.stfang.tokenomics", isDirectory: true)
            .appendingPathComponent(diskFileName)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
        if let disk = diskCacheURL {
            try? FileManager.default.removeItem(at: disk)
        }
    }
}

@Suite("FileRecordCache")
struct FileRecordCacheTests {

    @Test("cold call parses each source file exactly once and returns all records")
    func coldCallParsesEachFileOnce() throws {
        // Arrange
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let a = scratch.writeFile("a.json", "1")
        let b = scratch.writeFile("b.json", "2")
        let counter = ParseCounter()
        let cache = FileRecordCache<Rec>(
            diskFileName: scratch.diskFileName,
            queueLabel: "test.cold"
        )

        // Act
        let out = cache.records(for: [a, b]) { url in
            counter.record(url.path)
            return [Rec(v: url == a ? 1 : 2)]
        }

        // Assert
        #expect(counter.calls == 2)
        #expect(Set(counter.paths) == Set([a.path, b.path]))
        #expect(out == [Rec(v: 1), Rec(v: 2)])
    }

    @Test("second call with unchanged files does not re-parse and returns same records")
    func unchangedFilesReuseCache() throws {
        // Arrange
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let a = scratch.writeFile("a.json", "1")
        let b = scratch.writeFile("b.json", "2")
        let counter = ParseCounter()
        let cache = FileRecordCache<Rec>(
            diskFileName: scratch.diskFileName,
            queueLabel: "test.warm"
        )
        let parse: (URL) -> [Rec] = { url in
            counter.record(url.path)
            return [Rec(v: url == a ? 1 : 2)]
        }
        let first = cache.records(for: [a, b], parse: parse)

        // Act
        let second = cache.records(for: [a, b], parse: parse)

        // Assert
        #expect(counter.calls == 2)         // unchanged across the second call
        #expect(second == first)
    }

    @Test("changing one file re-parses only that file and keeps the other cached")
    func changedFileReparsesOnlyItself() throws {
        // Arrange
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let a = scratch.writeFile("a.json", "1")
        let b = scratch.writeFile("b.json", "2")
        let counter = ParseCounter()
        let cache = FileRecordCache<Rec>(
            diskFileName: scratch.diskFileName,
            queueLabel: "test.changed"
        )
        // parse returns a value derived from the file's current size so we can
        // observe the re-parse picking up the appended bytes.
        let parse: (URL) -> [Rec] = { url in
            counter.record(url.path)
            let size = (try? Data(contentsOf: url))?.count ?? 0
            return [Rec(v: size)]
        }
        _ = cache.records(for: [a, b], parse: parse)
        #expect(counter.calls == 2)

        // Act: change only "a.json" so its size + mtime differ.
        scratch.append("a.json", "XYZ")
        let out = cache.records(for: [a, b], parse: parse)

        // Assert: exactly one additional parse, and it was for "a".
        #expect(counter.calls == 3)
        #expect(counter.paths.filter { $0 == a.path }.count == 2)
        #expect(counter.paths.filter { $0 == b.path }.count == 1)
        // "a.json" grew from 1 byte to 4 bytes; "b.json" stayed at 1 byte.
        #expect(out == [Rec(v: 4), Rec(v: 1)])
    }

    @Test("removing a file drops its records from the result")
    func removedFileDropsRecords() throws {
        // Arrange
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let a = scratch.writeFile("a.json", "1")
        let b = scratch.writeFile("b.json", "2")
        let counter = ParseCounter()
        let cache = FileRecordCache<Rec>(
            diskFileName: scratch.diskFileName,
            queueLabel: "test.removed"
        )
        let parse: (URL) -> [Rec] = { url in
            counter.record(url.path)
            return [Rec(v: url == a ? 1 : 2)]
        }
        _ = cache.records(for: [a, b], parse: parse)

        // Act: drop "b" from the requested set and remove it from disk.
        scratch.remove("b.json")
        let out = cache.records(for: [a], parse: parse)

        // Assert: only "a"'s records remain; no new parse needed for "a".
        #expect(out == [Rec(v: 1)])
        #expect(counter.calls == 2)
    }

    @Test("a new cache instance with the same diskFileName loads records from disk without re-parsing")
    func diskRoundTripAvoidsReparse() throws {
        // Arrange
        let scratch = Scratch()
        defer { scratch.cleanup() }
        let a = scratch.writeFile("a.json", "1")
        let b = scratch.writeFile("b.json", "2")

        // Populate and persist via the first instance. lastSavedAt starts at
        // distantPast, so this cold (changed == true) call writes to disk.
        let firstCounter = ParseCounter()
        let firstCache = FileRecordCache<Rec>(
            diskFileName: scratch.diskFileName,
            queueLabel: "test.disk.first"
        )
        let firstOut = firstCache.records(for: [a, b]) { url in
            firstCounter.record(url.path)
            return [Rec(v: url == a ? 1 : 2)]
        }
        #expect(firstCounter.calls == 2)

        // Sanity: the on-disk cache file the production code targets now exists.
        let diskURL = try #require(scratch.diskCacheURL)
        #expect(FileManager.default.fileExists(atPath: diskURL.path))

        // Act: a brand-new instance with the SAME diskFileName, files unchanged.
        let secondCounter = ParseCounter()
        let secondCache = FileRecordCache<Rec>(
            diskFileName: scratch.diskFileName,
            queueLabel: "test.disk.second"
        )
        let secondOut = secondCache.records(for: [a, b]) { url in
            secondCounter.record(url.path)
            return [Rec(v: url == a ? 1 : 2)]
        }

        // Assert: loaded from disk, so parse was never invoked, and the records
        // round-tripped intact. NDJSON line order is dictionary order, so compare
        // as sets to stay deterministic.
        #expect(secondCounter.calls == 0)
        #expect(Set(secondOut) == Set(firstOut))
        #expect(Set(secondOut) == Set([Rec(v: 1), Rec(v: 2)]))
    }
}
