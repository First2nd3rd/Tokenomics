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

    /// One summary per date: summaries sharing a date (the same day on different
    /// machines) are summed, ascending by date. `PeriodReport` treats each entry as
    /// a distinct day, so a report blending machines must merge first. A date with a
    /// single summary passes through unchanged; a merged day is frozen only if every
    /// part was.
    static func mergedByDate(_ days: [DaySnapshot]) -> [DaySnapshot] {
        Dictionary(grouping: days, by: \.date).map { date, parts in
            guard parts.count > 1 else { return parts[0] }
            var total = TokenCounts()
            for part in parts { total.add(part.total) }
            return DaySnapshot(date: date, total: total, cost: parts.reduce(0) { $0 + $1.cost },
                               pricedAt: parts.map(\.pricedAt).max() ?? 0,
                               frozen: parts.allSatisfy(\.frozen),
                               byVendor: PeriodReport.mergeVendors(parts.flatMap(\.byVendor)),
                               byModel: PeriodReport.mergeModels(parts.flatMap(\.byModel)))
        }
        .sorted { $0.date < $1.date }
    }
}
