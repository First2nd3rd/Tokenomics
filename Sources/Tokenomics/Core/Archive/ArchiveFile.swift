import Foundation

/// On-disk format for one archive segment: a manifest header line followed by
/// `UsageRecord` NDJSON lines — the SAME record schema as the parse cache and peer
/// files, so a segment is byte-compatible and merging is concatenate-then-collapse.
///
/// Unlike the parse cache (a mirror of the current logs that drops records once
/// Claude rotates a file away) the archive is durable: segments live in Application
/// Support and are only ever rewritten wholesale, never pruned to follow the logs.
///
/// Versioning is `major.minor`: a reader skips a segment whose MAJOR is newer than it
/// understands (it can't be trusted), but still reads a newer MINOR — added optional
/// fields are simply ignored — so introducing a field never orphans existing history.
enum ArchiveFile {
    static let schemaMajor = 1
    static let schemaMinor = 0
    static var schemaVersion: String { "\(schemaMajor).\(schemaMinor)" }

    /// The segment's first line. Carries enough to attribute and label the segment
    /// without scanning its records. `month` is only a routing hint — the report
    /// re-buckets records by the current timezone at read time, never trusting it.
    struct Manifest: Codable, Equatable {
        let schemaVersion: String   // "major.minor"
        let machineId: String
        let displayName: String
        let appVersion: String
        let updatedAt: Int          // UTC epoch seconds
        let recordCount: Int
        let month: String           // "YYYY-MM"

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "sv", machineId = "id", displayName = "name",
                 appVersion = "app", updatedAt = "at", recordCount = "n", month = "ym"
        }
    }

    struct Contents {
        let manifest: Manifest
        let records: [UsageRecord]
    }

    /// Major component of a "major.minor" string, or nil if unparseable.
    static func major(of version: String) -> Int? {
        Int(version.split(separator: ".").first.map(String.init) ?? "")
    }

    /// Serialize a segment. Records are written WITHOUT a machine tag (it lives once
    /// in the manifest, as in `PeerFile`); the local archive's records are all this
    /// machine's, so a reader leaves `machine` nil — the local convention.
    static func encode(records: [UsageRecord], month: String, machineId: String,
                       displayName: String, appVersion: String, updatedAt: Int) -> Data {
        let manifest = Manifest(schemaVersion: schemaVersion, machineId: machineId,
                                displayName: displayName, appVersion: appVersion,
                                updatedAt: updatedAt, recordCount: records.count, month: month)
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

    /// Parse a segment. Returns nil when the manifest is missing/undecodable or its
    /// MAJOR schema is newer than this build supports. Unparseable record lines
    /// (including a torn final line) are skipped, not fatal — the atomic whole-file
    /// writer means a reader never actually sees a torn line, but we stay defensive.
    static func decode(_ data: Data) -> Contents? {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let headerData = lines.first,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(headerData)),
              let major = major(of: manifest.schemaVersion), major <= schemaMajor
        else { return nil }

        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        for lineData in lines.dropFirst() {
            if let record = try? decoder.decode(UsageRecord.self, from: Data(lineData)) {
                records.append(record)
            }
        }
        return Contents(manifest: manifest, records: records)
    }
}
