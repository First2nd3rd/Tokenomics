import Foundation

/// One finalized day's usage, pre-aggregated: totals by type, cost, and per-vendor /
/// per-model breakdowns. This is BOTH the unit persisted in `snapshots.ndjson` and
/// the unit a `PeriodReport` aggregates — a day computed live from the archive and a
/// day read from a snapshot have the identical shape, so the report blends them.
///
/// `cost` is frozen at `pricedAt` when `frozen` is true (a stored snapshot keeps the
/// historical cost even after prices change); when false the day was recomputed live
/// at current prices. Token counts are always reproducible from the archive — only
/// the frozen cost is unique to the snapshot.
struct DaySnapshot: Codable, Equatable, Identifiable {
    let date: String            // "2026-06-15"
    let total: TokenCounts
    let cost: Double
    let pricedAt: Int           // UTC epoch the cost was computed at
    let frozen: Bool            // true = from a stored snapshot; false = recomputed live
    let byVendor: [VendorUsage]
    let byModel: [ModelUsage]

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date = "d", total = "t", cost = "c", pricedAt = "pa",
             frozen = "f", byVendor = "v", byModel = "m"
    }
}
