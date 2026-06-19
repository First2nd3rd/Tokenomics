import Foundation
import CryptoKit

/// The single atomic usage record shared by every provider (Claude, Codex, …) and
/// every transport (the local parse cache today; peer files synced across machines
/// next).
///
/// One record = one billable event's token usage, tagged with its absolute UTC
/// instant. The local calendar day / minute and the cost are derived at READ time
/// (see `DayBucket`, `PricingStore`), never baked in — so the same record stays
/// correct under any timezone or price table, on any machine.
///
/// Every provider parses its own log format down to this identical shape, so the
/// on-disk cache lines are byte-for-byte the same schema across sources and a
/// cross-machine union is just concatenation followed by `Dedup.collapse`.
///
/// `key` is the cross-machine dedup identity: the same event seen anywhere hashes
/// to the same key, so unioning records from several machines and collapsing by key
/// is idempotent. `nil` means the source line carried no stable identity (a Claude
/// line missing message.id/requestId) and the record is always counted.
struct UsageRecord: Codable, Equatable, Hashable {
    let source: UsageSource
    let key: String?
    let epoch: Int            // UTC seconds since 1970
    let input: Int
    let output: Int
    let cacheCreation: Int    // Codex has no cache-creation concept ⇒ always 0
    let cacheRead: Int
    let model: String?

    // Compact coding keys keep the persisted cache small. `v` (vendor) carries
    // `source` so it can't collide with the cache wrapper's `s` (file size).
    enum CodingKeys: String, CodingKey {
        case source = "v", key = "k", epoch = "ts",
             input = "i", output = "o", cacheCreation = "w", cacheRead = "r", model = "m"
    }
}

/// Which agent produced a record. Raw values are the compact on-disk tags.
enum UsageSource: String, Codable, Equatable, Hashable {
    case claude = "c"
    case codex = "x"
}

/// Cross-source dedup shared by every provider and (next) the cross-machine union.
enum Dedup {
    /// 12-byte SHA-256 prefix of the `:`-joined components, base64 — compact and
    /// collision-free in practice (~1e-17 at a million messages). Deterministic, so
    /// the same logical event hashes identically on any machine.
    static func key(_ components: String...) -> String {
        let digest = SHA256.hash(data: Data(components.joined(separator: ":").utf8))
        return Data(digest.prefix(12)).base64EncodedString()
    }

    /// Collapse duplicates: among records sharing a key, keep the one with the
    /// largest output (a streamed Claude turn is logged repeatedly with a growing
    /// output; Codex's per-event records each carry a unique key, so all survive).
    /// Keyless records can't be deduped and are kept individually. Order-independent.
    static func collapse(_ records: [UsageRecord]) -> [UsageRecord] {
        var best: [String: UsageRecord] = [:]
        var keyless: [UsageRecord] = []
        for record in records {
            if let key = record.key {
                if let existing = best[key], existing.output >= record.output { continue }
                best[key] = record
            } else {
                keyless.append(record)
            }
        }
        return Array(best.values) + keyless
    }
}
