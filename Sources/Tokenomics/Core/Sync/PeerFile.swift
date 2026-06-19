import Foundation

/// The wire format for one machine's published usage: a manifest header line
/// followed by `UsageRecord` NDJSON lines — the SAME record schema the local cache
/// uses. One file per machine, single-writer, so there is never a write conflict.
///
/// Forward-compatible: a reader skips a file whose `schemaVersion` is newer than it
/// understands rather than mis-decoding it. Records are published WITHOUT a machine
/// field (it lives once in the manifest); the reader stamps each record with the
/// manifest's machine id, so the aggregator can group by machine.
enum PeerFile {
    /// Bump when the manifest or record schema changes incompatibly.
    static let schemaVersion = 1

    /// Manifest (the file's first line). `machineId` / `publishedAt` let a reader
    /// attribute and age a peer without scanning its records.
    struct Manifest: Codable, Equatable {
        let schemaVersion: Int
        let machineId: String
        let displayName: String
        let appVersion: String
        let publishedAt: Int        // UTC epoch seconds
        let recordCount: Int
        let windowDays: Int         // how many days of history this file carries

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "sv", machineId = "id", displayName = "name",
                 appVersion = "app", publishedAt = "at", recordCount = "n", windowDays = "win"
        }
    }

    struct Contents {
        let manifest: Manifest
        let records: [UsageRecord]   // each stamped with manifest.machineId
    }

    /// Serialize `records` for publication. Any per-record machine tag is stripped
    /// (redundant with the manifest); the reader re-stamps on decode.
    static func encode(records: [UsageRecord], machineId: String, displayName: String,
                       appVersion: String, publishedAt: Int, windowDays: Int) -> Data {
        let manifest = Manifest(schemaVersion: schemaVersion, machineId: machineId,
                                displayName: displayName, appVersion: appVersion,
                                publishedAt: publishedAt, recordCount: records.count, windowDays: windowDays)
        let encoder = JSONEncoder()
        var out = Data()
        if let header = try? encoder.encode(manifest) {
            out.append(header)
            out.append(0x0A)
        }
        for record in records {
            if let line = try? encoder.encode(record.with(machine: nil)) {
                out.append(line)
                out.append(0x0A)
            }
        }
        return out
    }

    /// Parse a peer file. Returns nil when the manifest is missing/undecodable or its
    /// `schemaVersion` is newer than this build supports. Records are tagged with the
    /// manifest's machine id; unparseable record lines are skipped, not fatal.
    static func decode(_ data: Data) -> Contents? {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let headerData = lines.first,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(headerData)),
              manifest.schemaVersion <= schemaVersion
        else { return nil }

        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        for lineData in lines.dropFirst() {
            if let record = try? decoder.decode(UsageRecord.self, from: Data(lineData)) {
                records.append(record.with(machine: manifest.machineId))
            }
        }
        return Contents(manifest: manifest, records: records)
    }
}
