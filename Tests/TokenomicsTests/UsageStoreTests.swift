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

/// A provider whose record list the test mutates between calls.
private final class GrowingStub: UsageProvider {
    let id: String
    var records: [UsageRecord]
    init(id: String, records: [UsageRecord]) { self.id = id; self.records = records }
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

    @Test("refreshTick derives the same views the per-surface refreshes produce")
    func tickMatchesPerSurfaceViews() async {
        let folder = TestFolder()
        folder.files["tok-peer.ndjson"] = peerFile(
            machineId: "peer", records: [record(.codex, key: "P", input: 50)])
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { true }, deliver: immediate)

        let tick = await withCheckedContinuation { c in
            store.refreshTick(lastDays: 14) { c.resume(returning: $0) }
        }
        let byVendor = await withCheckedContinuation { c in
            store.refreshByVendor { c.resume(returning: $0) }
        }
        let machines = await withCheckedContinuation { c in
            store.refreshMachines { c.resume(returning: $0) }
        }

        #expect(tick.byVendor == byVendor)
        #expect(tick.machines.map(\.id) == machines.map(\.id))
        #expect(tick.machines.map(\.todayTokens) == machines.map(\.todayTokens))
        let combinedTokens = tick.matrixCombined.values.flatMap { $0 }.reduce(0) { $0 + $1.counts.total }
        let localTokens = tick.matrixLocal.values.flatMap { $0 }.reduce(0) { $0 + $1.counts.total }
        #expect(combinedTokens == 60)     // 10 local + 50 peer
        #expect(localTokens == 10)        // local stream keeps peers out
    }

    @Test("refreshTick excludes peers and machines when sync is off")
    func tickSyncGating() async {
        let folder = TestFolder()
        folder.files["tok-peer.ndjson"] = peerFile(
            machineId: "peer", records: [record(.codex, key: "P", input: 50)])
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: folder, machineId: "own",
                               isSyncEnabled: { false }, deliver: immediate)

        let tick = await withCheckedContinuation { c in
            store.refreshTick(lastDays: 14) { c.resume(returning: $0) }
        }
        #expect(tick.byVendor["codex"] == nil)
        #expect(tick.machines.isEmpty)
        let combinedTokens = tick.matrixCombined.values.flatMap { $0 }.reduce(0) { $0 + $1.counts.total }
        #expect(combinedTokens == 10)
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

    @Test("persistLocal runs a real pass at most once per interval; flushLocal is exempt")
    func persistLocalThrottles() async {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let growing = GrowingStub(id: "claude-native", records: [record(.claude, key: "A", input: 1)])
        let store = UsageStore(localProviders: [growing], folder: TestFolder(), archive: archive,
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)
        let t0 = Date()

        // Await (not semaphore-block) so this test never starves the cooperative
        // pool the flush tests' 2s-bounded waits also run on.
        await withCheckedContinuation { c in store.persistLocal(now: t0) { c.resume() } }
        #expect(archive.allRecords().contains { $0.key == "A" })

        // A minute later: gated — the new record must NOT be ingested yet.
        growing.records.append(record(.claude, key: "B", input: 2))
        await withCheckedContinuation { c in
            store.persistLocal(now: t0.addingTimeInterval(60)) { c.resume() }
        }
        #expect(!archive.allRecords().contains { $0.key == "B" })

        // Past the interval: a real pass runs again.
        await withCheckedContinuation { c in
            store.persistLocal(now: t0.addingTimeInterval(301)) { c.resume() }
        }
        #expect(archive.allRecords().contains { $0.key == "B" })

        // Quit-time flush ignores the gate entirely.
        growing.records.append(record(.claude, key: "C", input: 3))
        store.flushLocal()
        #expect(archive.allRecords().contains { $0.key == "C" })
    }

    @Test("a report covering today reads today from the live stream, not the archive")
    func reportUsesLiveToday() async {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: TestFolder(), archive: archive,
                               snapshots: nil,           // real SnapshotStore would leak this Mac's data in
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)

        // The archive is EMPTY and no persist ran — today must come from the logs.
        let report = await withCheckedContinuation { c in
            store.report(period: .day, anchor: Date()) { c.resume(returning: $0) }
        }
        #expect(report?.total.total == 10)
        #expect(af.files.isEmpty)          // and a reload never writes the archive
    }

    @Test("live today supersedes the archive's (possibly inflated) copy of today")
    func liveTodayBeatsArchivedToday() async {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        // The archive holds a stale, LARGER variant of the same turn (streamed
        // intermediate that a later log rewrite corrected down).
        archive.ingest([record(.claude, key: "L", input: 999)])
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: TestFolder(), archive: archive,
                               snapshots: nil,
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)

        let report = await withCheckedContinuation { c in
            store.report(period: .day, anchor: Date()) { c.resume(returning: $0) }
        }
        #expect(report?.total.total == 10)  // the menu bar's number, not 999
    }

    @Test("report reuses the last tick's snapshot instead of refetching")
    func reportReusesTickSnapshot() async {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let growing = GrowingStub(id: "claude-native", records: [record(.claude, key: "A", input: 10)])
        let store = UsageStore(localProviders: [growing], folder: TestFolder(), archive: archive,
                               snapshots: nil,
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)

        _ = await withCheckedContinuation { c in
            store.refreshTick(lastDays: 14) { c.resume(returning: $0) }
        }
        // New usage lands after the tick; the report must show the TICK's snapshot
        // (what the menu bar rendered), not a fresher refetch.
        growing.records.append(record(.claude, key: "B", input: 5))
        let report = await withCheckedContinuation { c in
            store.report(period: .day, anchor: Date()) { c.resume(returning: $0) }
        }
        #expect(report?.total.total == 10)
    }

    @Test("a day report buckets today's live records by hour")
    func dayReportHourlyFromLive() async {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: TestFolder(), archive: archive,
                               snapshots: nil,
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)

        let report = await withCheckedContinuation { c in
            store.report(period: .day, anchor: Date()) { c.resume(returning: $0) }
        }
        let hourly = report?.hourly
        #expect(hourly?.count == 24)
        #expect(hourly?.reduce(0) { $0 + $1.total } == 10)     // all buckets sum to the day
        let hour = Calendar.current.component(.hour, from: Date())
        #expect(hourly?[hour].total == 10)                     // and land in the current hour
    }

    @Test("a past-day report buckets its archive records by hour")
    func dayReportHourlyFromArchive() async {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        var r = record(.claude, key: "Y", input: 30)
        r = UsageRecord(source: r.source, key: r.key, epoch: Int(yesterday.timeIntervalSince1970),
                        input: r.input, output: 0, cacheCreation: 0, cacheRead: 0, model: r.model)
        archive.ingest([r])
        let local = [RecordStub(id: "claude-native", records: [])]
        let store = UsageStore(localProviders: local, folder: TestFolder(), archive: archive,
                               snapshots: nil,
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)

        let report = await withCheckedContinuation { c in
            store.report(period: .day, anchor: yesterday) { c.resume(returning: $0) }
        }
        #expect(report?.total.total == 30)
        #expect(report?.hourly?.reduce(0) { $0 + $1.total } == 30)
        let hour = Calendar.current.component(.hour, from: yesterday)
        #expect(report?.hourly?[hour].total == 30)
    }

    @Test("a report for a past period reads the archive as-is, no ingest")
    func pastReportSkipsIngest() async {
        let af = MemoryArchiveFolder()
        let archive = UsageArchive(folder: af, machineId: "own", displayName: { "own" }, appVersion: "0")
        let local = [RecordStub(id: "claude-native", records: [record(.claude, key: "L", input: 10)])]
        let store = UsageStore(localProviders: local, folder: TestFolder(), archive: archive,
                               snapshots: nil,           // real SnapshotStore would leak this Mac's data in
                               machineId: "own", isSyncEnabled: { false }, isArchiveEnabled: { true },
                               deliver: immediate)

        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let report = await withCheckedContinuation { c in
            store.report(period: .month, anchor: lastMonth) { c.resume(returning: $0) }
        }
        #expect(report?.total.total == 0)
        #expect(af.files.isEmpty)          // untouched — past periods never trigger a write
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
