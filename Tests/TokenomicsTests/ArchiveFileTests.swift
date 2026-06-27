import Testing
import Foundation
@testable import Tokenomics

@Suite("ArchiveFile")
struct ArchiveFileTests {

    private func rec(_ source: UsageSource, key: String?, input: Int = 0, output: Int = 0,
                     model: String? = nil, epoch: Int = 1_750_000_000) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: epoch, input: input, output: output,
                    cacheCreation: 0, cacheRead: 0, model: model)
    }

    private func encodeSample(_ records: [UsageRecord], month: String = "2026-06") -> Data {
        ArchiveFile.encode(records: records, month: month, machineId: "mac-A",
                           displayName: "My Mac", appVersion: "0.1.0", updatedAt: 1_750_000_123)
    }

    @Test("round-trips the manifest and records")
    func roundTrip() throws {
        let records = [
            rec(.claude, key: "A", input: 10, output: 5, model: "opus"),
            rec(.codex, key: "X:0", input: 4, output: 1, model: "gpt-5"),
        ]
        let contents = try #require(ArchiveFile.decode(encodeSample(records)))
        #expect(contents.manifest.machineId == "mac-A")
        #expect(contents.manifest.displayName == "My Mac")
        #expect(contents.manifest.month == "2026-06")
        #expect(contents.manifest.schemaVersion == ArchiveFile.schemaVersion)
        #expect(contents.manifest.recordCount == 2)
        #expect(contents.records.count == 2)
        #expect(contents.records.allSatisfy { $0.machine == nil })   // local convention
        #expect(contents.records.first?.input == 10)
    }

    @Test("skips a segment whose MAJOR schema is newer than supported")
    func skipsNewerMajor() throws {
        let future = ArchiveFile.Manifest(schemaVersion: "\(ArchiveFile.schemaMajor + 1).0", machineId: "m",
                                          displayName: "d", appVersion: "9", updatedAt: 1,
                                          recordCount: 0, month: "2026-06")
        var data = try JSONEncoder().encode(future)
        data.append(0x0A)
        #expect(ArchiveFile.decode(data) == nil)
    }

    @Test("still reads a segment whose MINOR schema is newer (added fields ignored)")
    func readsNewerMinor() throws {
        // Same major, higher minor — a forward-compatible writer added optional fields.
        let newerMinor = ArchiveFile.Manifest(schemaVersion: "\(ArchiveFile.schemaMajor).\(ArchiveFile.schemaMinor + 7)",
                                              machineId: "m", displayName: "d", appVersion: "9",
                                              updatedAt: 1, recordCount: 1, month: "2026-06")
        var data = try JSONEncoder().encode(newerMinor)
        data.append(0x0A)
        data.append(try JSONEncoder().encode(rec(.claude, key: "A", input: 3).with(machine: nil)))
        data.append(0x0A)
        let contents = try #require(ArchiveFile.decode(data))
        #expect(contents.records.count == 1)
        #expect(contents.records.first?.input == 3)
    }

    @Test("returns nil when the first line is not a manifest")
    func nilWithoutManifest() throws {
        let data = try JSONEncoder().encode(rec(.claude, key: "A", input: 1))
        #expect(ArchiveFile.decode(data) == nil)
    }

    @Test("skips unparseable record lines without failing the whole segment")
    func skipsGarbageLines() throws {
        var data = encodeSample([rec(.claude, key: "A", input: 1, model: "m")])
        data.append(Data("this is not json\n".utf8))
        data.append(try JSONEncoder().encode(rec(.codex, key: "X:0", input: 2, model: "g").with(machine: nil)))
        data.append(0x0A)
        let contents = try #require(ArchiveFile.decode(data))
        #expect(contents.records.count == 2)
    }

    @Test("tolerates an empty appVersion (swift run / swift test have no Info.plist)")
    func emptyAppVersion() throws {
        let data = ArchiveFile.encode(records: [rec(.claude, key: "A", input: 1)], month: "2026-06",
                                      machineId: "m", displayName: "d", appVersion: "", updatedAt: 1)
        let contents = try #require(ArchiveFile.decode(data))
        #expect(contents.manifest.appVersion == "")
    }

    @Test("returns nil for empty data")
    func nilForEmpty() {
        #expect(ArchiveFile.decode(Data()) == nil)
    }

    @Test("decodes a frozen v1 record line — guards the shared UsageRecord schema")
    func goldenV1RecordLine() throws {
        // A byte-frozen v1 line. UsageRecord is the shared persisted shape of cache,
        // peer, AND archive; if a future edit can no longer decode this, years of
        // archives become unreadable. Any new field MUST stay Optional.
        let golden = Data(#"{"v":"c","k":"A","ts":1750000000,"i":10,"o":5,"w":2,"r":3,"m":"opus"}"#.utf8)
        let record = try #require(try? JSONDecoder().decode(UsageRecord.self, from: golden))
        #expect(record.source == .claude)
        #expect(record.key == "A")
        #expect(record.epoch == 1_750_000_000)
        #expect(record.input == 10)
        #expect(record.output == 5)
        #expect(record.cacheCreation == 2)
        #expect(record.cacheRead == 3)
        #expect(record.model == "opus")
        #expect(record.machine == nil)
    }
}
