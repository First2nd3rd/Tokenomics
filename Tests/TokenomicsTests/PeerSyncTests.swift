import Testing
import Foundation
@testable import Tokenomics

/// An in-memory PeerFolder with controllable availability + a write counter.
private final class StubFolder: PeerFolder {
    var directoryURL: URL? = URL(fileURLWithPath: "/stub")
    var files: [String: Data] = [:]
    var unavailable: Set<String> = []
    private(set) var writeCount = 0

    func peerFileURLs() -> [URL] { files.keys.sorted().map { URL(fileURLWithPath: "/stub/\($0)") } }

    func readData(at url: URL) -> Data? {
        let name = url.lastPathComponent
        return unavailable.contains(name) ? nil : files[name]
    }

    func writeOwnFile(_ data: Data, machineId: String) throws {
        files[peerFileName(forMachine: machineId)] = data
        writeCount += 1
    }

    func removeOwnFile(machineId: String) {
        files.removeValue(forKey: peerFileName(forMachine: machineId))
    }
}

@Suite("Peer sync")
struct PeerSyncTests {

    private func rec(_ source: UsageSource, key: String?, input: Int = 0, output: Int = 0,
                     epoch: Int = 1_750_000_000, model: String? = nil) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: epoch, input: input, output: output,
                    cacheCreation: 0, cacheRead: 0, model: model)
    }

    private func peerData(machineId: String, records: [UsageRecord], at: Int = 1_750_000_123) -> Data {
        PeerFile.encode(records: records, machineId: machineId, displayName: machineId,
                        appVersion: "0.1.0", publishedAt: at, windowDays: 90)
    }

    // MARK: - PeerRecordSource

    @Test("reads peers' records and skips this machine's own file by manifest id")
    func skipsOwn() throws {
        let folder = StubFolder()
        folder.files["tok-own.ndjson"] = peerData(machineId: "own", records: [rec(.claude, key: "MINE", input: 99)])
        folder.files["tok-peer.ndjson"] = peerData(machineId: "peer", records: [rec(.claude, key: "THEIRS", input: 5)])

        let recs = PeerRecordSource(folder: folder, ownMachineId: "own").readPeers()
        #expect(recs.count == 1)
        #expect(recs.first?.machine == "peer")
        #expect(recs.first?.input == 5)
    }

    @Test("excludes a renamed/conflict copy of our own file by manifest id, not filename")
    func skipsOwnConflictCopy() {
        let folder = StubFolder()
        folder.files["tok-own 2.ndjson"] = peerData(machineId: "own", records: [rec(.claude, key: "MINE", input: 99)])
        #expect(PeerRecordSource(folder: folder, ownMachineId: "own").readPeers().isEmpty)
    }

    @Test("a peer's iCloud conflict copy does not double-count its keyless records")
    func peerConflictCopyNoDoubleCount() {
        let folder = StubFolder()
        let keyless = rec(.claude, key: nil, input: 10, model: "m")   // can't be deduped by key
        folder.files["tok-peer.ndjson"] = peerData(machineId: "peer", records: [keyless], at: 1000)
        folder.files["tok-peer 2.ndjson"] = peerData(machineId: "peer", records: [keyless], at: 1000)  // conflict copy

        let recs = PeerRecordSource(folder: folder, ownMachineId: "own").readPeers()
        #expect(recs.count == 1)            // counted once, not twice
        #expect(recs.first?.input == 10)
    }

    @Test("keeps the newest file when a peer has two by publishedAt")
    func peerKeepsNewestCopy() {
        let folder = StubFolder()
        folder.files["tok-peer.ndjson"] = peerData(
            machineId: "peer", records: [rec(.claude, key: "A", input: 1)], at: 1000)
        folder.files["tok-peer 2.ndjson"] = peerData(
            machineId: "peer", records: [rec(.claude, key: "A", input: 1), rec(.claude, key: "B", input: 2)], at: 2000)

        let recs = PeerRecordSource(folder: folder, ownMachineId: "own").readPeers()
        #expect(recs.count == 2)            // the newer file (publishedAt 2000) wins
    }

    @Test("retains a peer's last-known records when its file is transiently unreadable")
    func retainsLastKnown() {
        let folder = StubFolder()
        folder.files["tok-peer.ndjson"] = peerData(machineId: "peer", records: [rec(.claude, key: "T", input: 7)])
        let source = PeerRecordSource(folder: folder, ownMachineId: "own")

        #expect(source.readPeers().first?.input == 7)        // cycle 1: read fresh
        folder.unavailable.insert("tok-peer.ndjson")
        #expect(source.readPeers().first?.input == 7)        // cycle 2: placeholder → retained
    }

    @Test("drops a peer's contribution once its file is gone")
    func dropsRemoved() {
        let folder = StubFolder()
        folder.files["tok-peer.ndjson"] = peerData(machineId: "peer", records: [rec(.claude, key: "T", input: 7)])
        let source = PeerRecordSource(folder: folder, ownMachineId: "own")

        _ = source.readPeers()
        folder.files.removeValue(forKey: "tok-peer.ndjson")
        #expect(source.readPeers().isEmpty)
    }

    // MARK: - PeerPublisher

    @Test("publishes once, then skips an unchanged or throttled republish")
    func publishThrottle() {
        let folder = StubFolder()
        let pub = PeerPublisher(folder: folder, machineId: "own", displayName: { "Own" },
                                appVersion: "0.1.0", windowDays: 90, throttle: 100)
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)
        let records = [rec(.claude, key: "A", input: 1)]

        #expect(pub.publishIfNeeded(localRecords: records, now: t0) == true)                       // first publish
        #expect(folder.writeCount == 1)
        #expect(pub.publishIfNeeded(localRecords: records, now: t0.addingTimeInterval(200)) == false) // unchanged
        #expect(folder.writeCount == 1)

        let more = records + [rec(.claude, key: "B", input: 2)]
        #expect(pub.publishIfNeeded(localRecords: more, now: t0.addingTimeInterval(50)) == false)  // changed but throttled
        #expect(pub.publishIfNeeded(localRecords: more, now: t0.addingTimeInterval(300)) == true)  // changed + throttle elapsed
        #expect(folder.writeCount == 2)
    }

    @Test("a fresh publisher whose data matches the existing file does not rewrite (no churn across relaunch)")
    func noRewriteAcrossRelaunch() {
        let folder = StubFolder()
        let records = [rec(.claude, key: "A", input: 1)]
        let t = Date(timeIntervalSince1970: 1_750_000_000)

        let first = PeerPublisher(folder: folder, machineId: "own", displayName: { "Own" },
                                  appVersion: "0.1.0", windowDays: 90, throttle: 0)
        #expect(first.publishIfNeeded(localRecords: records, now: t) == true)
        #expect(folder.writeCount == 1)

        // Simulate a relaunch: a brand-new publisher over the same folder + same data.
        let second = PeerPublisher(folder: folder, machineId: "own", displayName: { "Own" },
                                   appVersion: "0.1.0", windowDays: 90, throttle: 0)
        #expect(second.publishIfNeeded(localRecords: records, now: t.addingTimeInterval(10)) == false)
        #expect(folder.writeCount == 1)   // seeded from own file ⇒ unchanged ⇒ no write
    }

    @Test("publishes only records within the window")
    func publishWindow() throws {
        let folder = StubFolder()
        let pub = PeerPublisher(folder: folder, machineId: "own", displayName: { "Own" },
                                appVersion: "0.1.0", windowDays: 30, throttle: 0)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let nowEpoch = Int(now.timeIntervalSince1970)
        let recent = rec(.claude, key: "R", input: 1, epoch: nowEpoch - 5 * 86_400)
        let old = rec(.claude, key: "O", input: 1, epoch: nowEpoch - 60 * 86_400)

        #expect(pub.publishIfNeeded(localRecords: [recent, old], now: now) == true)
        let data = try #require(folder.files["tok-own.ndjson"])
        let published = try #require(PeerFile.decode(data))
        #expect(published.records.count == 1)            // old one dropped by the window
        #expect(published.records.first?.key == "R")
    }

    @Test("a published file round-trips back through PeerRecordSource on another machine")
    func publishThenReadElsewhere() throws {
        let folder = StubFolder()
        let pub = PeerPublisher(folder: folder, machineId: "mac-A", displayName: { "Mac A" },
                                appVersion: "0.1.0", windowDays: 90, throttle: 0)
        // now within the record's window so it isn't filtered out (default rec epoch).
        let now = Date(timeIntervalSince1970: 1_750_000_100)
        #expect(pub.publishIfNeeded(localRecords: [rec(.claude, key: "A", input: 42, model: "m")], now: now) == true)

        // A different machine reads the folder.
        let recs = PeerRecordSource(folder: folder, ownMachineId: "mac-B").readPeers()
        #expect(recs.count == 1)
        #expect(recs.first?.machine == "mac-A")
        #expect(recs.first?.input == 42)
    }
}
