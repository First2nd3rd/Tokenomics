import Testing
import Foundation
@testable import Tokenomics

@Suite("PeerFile")
struct PeerFileTests {

    private func rec(_ source: UsageSource, key: String?, input: Int = 0, output: Int = 0,
                     model: String? = nil) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: 1_750_000_000, input: input, output: output,
                    cacheCreation: 0, cacheRead: 0, model: model)
    }

    private func encodeSample(records: [UsageRecord], machineId: String = "mac-A") -> Data {
        PeerFile.encode(records: records, machineId: machineId, displayName: "My Mac",
                        appVersion: "0.1.0", publishedAt: 1_750_000_123, windowDays: 90)
    }

    @Test("round-trips the manifest and records")
    func roundTrip() throws {
        let records = [
            rec(.claude, key: "A", input: 10, output: 5, model: "opus"),
            rec(.codex, key: "X:0", input: 4, output: 1, model: "gpt-5"),
        ]
        let contents = try #require(PeerFile.decode(encodeSample(records: records)))
        #expect(contents.manifest.machineId == "mac-A")
        #expect(contents.manifest.displayName == "My Mac")
        #expect(contents.manifest.schemaVersion == PeerFile.schemaVersion)
        #expect(contents.manifest.recordCount == 2)
        #expect(contents.records.count == 2)
        #expect(contents.records.allSatisfy { $0.machine == "mac-A" })   // stamped from manifest
        #expect(contents.records.first?.input == 10)
    }

    @Test("stamps records with the manifest machine id, overriding any prior tag")
    func stampsMachine() throws {
        // A record that already carried a (different) machine tag must come back as
        // the publisher's id — the manifest is the single source of truth.
        let tagged = rec(.claude, key: "A", input: 1, model: "m").with(machine: "stale")
        let contents = try #require(PeerFile.decode(encodeSample(records: [tagged], machineId: "mac-B")))
        #expect(contents.records.first?.machine == "mac-B")
    }

    @Test("skips a file whose schemaVersion is newer than supported")
    func skipsNewerSchema() throws {
        let future = PeerFile.Manifest(schemaVersion: PeerFile.schemaVersion + 1, machineId: "m",
                                       displayName: "d", appVersion: "9", publishedAt: 1,
                                       recordCount: 0, windowDays: 90)
        var data = try JSONEncoder().encode(future)
        data.append(0x0A)
        #expect(PeerFile.decode(data) == nil)
    }

    @Test("returns nil when the first line is not a manifest")
    func nilWithoutManifest() throws {
        // A bare record line with no manifest header.
        let data = try JSONEncoder().encode(rec(.claude, key: "A", input: 1))
        #expect(PeerFile.decode(data) == nil)
    }

    @Test("skips unparseable record lines without failing the whole file")
    func skipsGarbageLines() throws {
        var data = encodeSample(records: [rec(.claude, key: "A", input: 1, model: "m")])
        data.append(Data("this is not json\n".utf8))
        data.append(try JSONEncoder().encode(rec(.codex, key: "X:0", input: 2, model: "g")))
        data.append(0x0A)
        let contents = try #require(PeerFile.decode(data))
        #expect(contents.records.count == 2)   // the two valid records; garbage dropped
    }

    @Test("returns nil for empty data")
    func nilForEmpty() {
        #expect(PeerFile.decode(Data()) == nil)
    }
}
