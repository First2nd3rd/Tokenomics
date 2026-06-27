import Foundation

/// On-disk format for the daily-snapshot store: a manifest header line followed by
/// one `DaySnapshot` NDJSON line per finalized day, ascending. Mirrors `ArchiveFile`
/// / `PeerFile`. The whole thing is tiny (~0.5–0.8 KB/day), so it's a single file
/// rewritten wholesale — and readable enough to double as a backup artifact.
enum SnapshotFile {
    /// Bump when the manifest or `DaySnapshot` schema changes incompatibly.
    static let schemaVersion = 1

    struct Manifest: Codable, Equatable {
        let schemaVersion: Int
        let machineId: String
        let updatedAt: Int          // UTC epoch
        let dayCount: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "sv", machineId = "id", updatedAt = "at", dayCount = "n"
        }
    }

    static func encode(_ days: [DaySnapshot], machineId: String, updatedAt: Int) -> Data {
        let manifest = Manifest(schemaVersion: schemaVersion, machineId: machineId,
                                updatedAt: updatedAt, dayCount: days.count)
        let encoder = JSONEncoder()
        var out = Data()
        if let header = try? encoder.encode(manifest) {
            out.append(header)
            out.append(0x0A)
        }
        for day in days {
            if let line = try? encoder.encode(day) {
                out.append(line)
                out.append(0x0A)
            }
        }
        return out
    }

    /// Returns nil when the manifest is missing/undecodable or its `schemaVersion` is
    /// newer than this build. Unparseable day lines are skipped, not fatal.
    static func decode(_ data: Data) -> [DaySnapshot]? {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let headerData = lines.first,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(headerData)),
              manifest.schemaVersion <= schemaVersion
        else { return nil }

        let decoder = JSONDecoder()
        var days: [DaySnapshot] = []
        for lineData in lines.dropFirst() {
            if let day = try? decoder.decode(DaySnapshot.self, from: Data(lineData)) {
                days.append(day)
            }
        }
        return days
    }
}
