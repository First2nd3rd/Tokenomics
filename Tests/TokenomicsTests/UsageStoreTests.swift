import Testing
import Foundation
@testable import Tokenomics

/// An in-memory PeerFolder with a write counter.
private final class TestFolder: PeerFolder {
    var directoryURL: URL? = URL(fileURLWithPath: "/t")
    var files: [String: Data] = [:]
    private(set) var writeCount = 0

    func peerFileURLs() -> [URL] { files.keys.sorted().map { URL(fileURLWithPath: "/t/\($0)") } }
    func readData(at url: URL) -> Data? { files[url.lastPathComponent] }
    func writeOwnFile(_ data: Data, machineId: String) throws {
        files[peerFileName(forMachine: machineId)] = data
        writeCount += 1
    }

    func removeOwnFile(machineId: String) {
        files.removeValue(forKey: peerFileName(forMachine: machineId))
    }
}

/// A provider that returns a fixed record list.
private struct RecordStub: UsageProvider {
    let id: String
    let records: [UsageRecord]
    func fetchRecords(completion: @escaping ([UsageRecord]) -> Void) { completion(records) }
}

@Suite("UsageStore wiring")
struct UsageStoreTests {

    /// Deliver synchronously (no main-queue hop) so tests stay deterministic.
    private let immediate: (@escaping () -> Void) -> Void = { $0() }

    private func run<T>(_ work: (@escaping (T) -> Void) -> Void) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var out: T!
        work { out = $0; semaphore.signal() }
        semaphore.wait()
        return out
    }

    private func record(_ source: UsageSource, key: String, input: Int) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: Int(Date().timeIntervalSince1970),
                    input: input, output: 0, cacheCreation: 0, cacheRead: 0, model: "m")
    }

    private func peerFile(machineId: String, records: [UsageRecord]) -> Data {
        PeerFile.encode(records: records, machineId: machineId, displayName: machineId,
                        appVersion: "0", publishedAt: Int(Date().timeIntervalSince1970), windowDays: 90)
    }

    @Test("byVendor folds in peers only when sync is enabled")
    func byVendorPeerGating() {
        let folder = TestFolder()
        folder.files["tok-peer.ndjson"] = peerFile(
            machineId: "peer", records: [record(.codex, key: "P", input: 50)])
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]

        var enabled = false
        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { enabled }, deliver: immediate)

        let off: [String: [DailyUsage]] = run { store.refreshByVendor(completion: $0) }
        #expect(off["codex"] == nil)                          // peers excluded when off
        #expect(off["claude-native"]?.first?.inputTokens == 10)

        enabled = true
        let on: [String: [DailyUsage]] = run { store.refreshByVendor(completion: $0) }
        #expect(on["codex"]?.first?.inputTokens == 50)        // peer folded in when on
        #expect(on["claude-native"]?.first?.inputTokens == 10)
    }

    @Test("the matrix folds peers into combined but keeps local-only separate")
    func matrixPeerGating() {
        let folder = TestFolder()
        folder.files["tok-peer.ndjson"] = peerFile(
            machineId: "peer", records: [record(.codex, key: "P", input: 50)])
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]

        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { true }, deliver: immediate)
        let (combined, localMatrix): ([String: [MinuteBucket]], [String: [MinuteBucket]]) =
            run { done in store.refreshMatrix(lastDays: 14) { c, l in done((c, l)) } }
        let combinedTokens = combined.values.flatMap { $0 }.reduce(0) { $0 + $1.counts.total }
        let localTokens = localMatrix.values.flatMap { $0 }.reduce(0) { $0 + $1.counts.total }
        #expect(combinedTokens == 60)     // 10 local + 50 peer (full-day chart + cumulative)
        #expect(localTokens == 10)        // local only — the live chart's true height
    }

    @Test("flushPublish writes this machine's file only when sync is enabled")
    func publishGating() {
        let folder = TestFolder()
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]

        var enabled = false
        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { enabled }, deliver: immediate)

        store.flushPublish()
        #expect(folder.writeCount == 0)                       // disabled → never touches iCloud
        enabled = true
        store.flushPublish()
        #expect(folder.writeCount == 1)                       // enabled → writes own file
    }

    @Test("refreshMachines summarizes this Mac + peers for today")
    func machineSummaries() {
        let folder = TestFolder()
        folder.files["tok-peer.ndjson"] = peerFile(
            machineId: "peer", records: [record(.codex, key: "P", input: 50)])
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { true }, deliver: immediate)

        let machines: [MachineSummary] = run { store.refreshMachines(now: Date(), completion: $0) }
        #expect(machines.count == 2)
        let byId = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0) })
        #expect(byId["own"]?.todayTokens == 10)
        #expect(byId["own"]?.isLocal == true)
        #expect(byId["peer"]?.todayTokens == 50)
        #expect(byId["peer"]?.isLocal == false)
        #expect(byId["peer"]?.name == "peer")          // from the peer's manifest
    }

    @Test("refreshMachines is empty when sync is off")
    func machineSummariesOff() {
        let folder = TestFolder()
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { false }, deliver: immediate)
        let machines: [MachineSummary] = run { store.refreshMachines(now: Date(), completion: $0) }
        #expect(machines.isEmpty)
    }

    @Test("retractOwnFile deletes this machine's published file")
    func retractDeletesOwnFile() {
        let folder = TestFolder()
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { true }, deliver: immediate)
        store.flushPublish()
        #expect(folder.files["tok-own.ndjson"] != nil)

        store.retractOwnFile()
        #expect(folder.files["tok-own.ndjson"] == nil)        // peers will drop this Mac next cycle
    }

    @Test("persistLocal folds local records into the archive when archiving is on")
    func persistLocalArchives() {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: TestFolder(), archive: archive,
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)
        store.flushLocal()   // synchronous
        #expect(archive.allRecords().contains { $0.key == "L" })
    }

    @Test("persistLocal writes nothing to the archive when archiving is off")
    func persistLocalArchiveGating() {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: TestFolder(), archive: archive,
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { false },
                               deliver: immediate)
        store.flushLocal()
        #expect(af.files.isEmpty)
    }

    @Test("the published file contains only this machine's records, not peers'")
    func publishesOwnRecordsOnly() throws {
        let folder = TestFolder()
        folder.files["tok-peer.ndjson"] = peerFile(
            machineId: "peer", records: [record(.codex, key: "P", input: 50)])
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]

        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { true }, deliver: immediate)
        store.flushPublish()

        let data = try #require(folder.files["tok-own.ndjson"])
        let contents = try #require(PeerFile.decode(data))
        #expect(contents.records.count == 1)                  // only the local record
        #expect(contents.records.first?.key == "L")
    }
}
