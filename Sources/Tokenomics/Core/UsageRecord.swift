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
    /// Which machine produced this record. `nil` = the local machine (we never
    /// persist our own id in the cache); set to a peer's id when read from a peer
    /// file. Optional + omitted-when-nil, so existing caches decode unchanged.
    let machine: String?

    init(source: UsageSource, key: String?, epoch: Int, input: Int, output: Int,
         cacheCreation: Int, cacheRead: Int, model: String?, machine: String? = nil) {
        self.source = source
        self.key = key
        self.epoch = epoch
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.model = model
        self.machine = machine
    }

    /// Sum of all four token components — the collapse tie-breaker.
    var totalTokens: Int { input + output + cacheCreation + cacheRead }

    /// A copy tagged with `machine` — used when stamping a peer file's records with
    /// the publisher's id at read time.
    func with(machine: String?) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: epoch, input: input, output: output,
                    cacheCreation: cacheCreation, cacheRead: cacheRead, model: model, machine: machine)
    }

    // Compact coding keys keep the persisted cache small. `v` (vendor) carries
    // `source` so it can't collide with the cache wrapper's `s` (file size); `h`
    // (host) carries the machine and is omitted for local (nil) records.
    enum CodingKeys: String, CodingKey {
        case source = "v", key = "k", epoch = "ts",
             input = "i", output = "o", cacheCreation = "w", cacheRead = "r", model = "m",
             machine = "h"
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
    /// Equal outputs tie-break on total tokens, so a corrected parse of the same
    /// event (same output, more cache-read) supersedes an archived older one.
    /// Order-independent.
    ///
    /// Keyless records (a Claude line with no message.id/requestId) have no stable
    /// identity. By default they are all kept — the live path counts every one. With
    /// `foldKeyless`, they collapse by `syntheticKey` (their event shape) instead, so
    /// re-presenting the same keyless line is idempotent. The durable archive needs
    /// this because a wholesale segment rewrite must not multiply keyless records.
    static func collapse(_ records: [UsageRecord], foldKeyless: Bool = false) -> [UsageRecord] {
        var best: [String: UsageRecord] = [:]
        var keyless: [UsageRecord] = []
        for record in records {
            let identity = record.key ?? (foldKeyless ? syntheticKey(record) : nil)
            if let identity {
                if let existing = best[identity],
                   (existing.output, existing.totalTokens) >= (record.output, record.totalTokens) { continue }
                best[identity] = record
            } else {
                keyless.append(record)
            }
        }
        return Array(best.values) + keyless
    }

    /// Shape-based identity for a keyless record. The `"kl"` salt keeps it out of the
    /// real-key namespace, so it can only ever fold one keyless record into another.
    static func syntheticKey(_ r: UsageRecord) -> String {
        key("kl", r.source.rawValue, String(r.epoch), String(r.input), String(r.output),
            String(r.cacheCreation), String(r.cacheRead), r.model ?? "")
    }
}
