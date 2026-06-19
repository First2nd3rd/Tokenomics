import Foundation

/// Turns a flat stream of `UsageRecord` (the local providers' records today; peer
/// records too, later) into the views the app renders.
///
/// The cross-machine union is just record concatenation; correctness comes from a
/// SINGLE `Dedup.collapse` here, BEFORE any aggregation — never from merging
/// already-aggregated per-source/per-machine totals, which can't re-dedup and would
/// double-count a turn that reached two sources (e.g. a mirror-synced dotfile).
///
/// Everything is derived at READ time: the local day/minute under the current
/// timezone (`DayBucket`) and cost under the current price table (`PricingStore`),
/// so the same records stay correct across timezones, price updates, and machines.
enum UsageAggregator {

    /// The break-even view keys vendors by the originating provider's id; keep this
    /// mapping stable — `Vendor.providerID` depends on these exact strings.
    static func vendorId(for source: UsageSource) -> String {
        switch source {
        case .claude: return "claude-native"
        case .codex:  return "codex"
        }
    }

    /// Combined per-day totals (deduped across the whole union), sorted by date.
    static func daily(_ records: [UsageRecord]) -> [DailyUsage] {
        aggregateByDay(Dedup.collapse(records))
    }

    /// Per-vendor daily series (provider id → days), deduped across the whole union.
    /// Collapse runs once over the union; the per-source split happens afterward, so
    /// a duplicate that appears under two sources is still removed before splitting.
    static func byVendor(_ records: [UsageRecord]) -> [String: [DailyUsage]] {
        let collapsed = Dedup.collapse(records)
        var out: [String: [DailyUsage]] = [:]
        for (source, recs) in Dictionary(grouping: collapsed, by: { $0.source }) {
            out[vendorId(for: source)] = aggregateByDay(recs)
        }
        return out
    }

    /// Day → [1440] per-minute buckets (by type + by model), deduped across the union.
    static func dayMinuteMatrix(_ records: [UsageRecord]) -> [String: [MinuteBucket]] {
        var byDay: [String: [MinuteBucket]] = [:]
        for r in Dedup.collapse(records) {
            let (day, minute) = DayBucket.dayMinute(epoch: r.epoch)
            byDay[day, default: Array(repeating: MinuteBucket(), count: 1440)][minute]
                .add(input: r.input, output: r.output,
                     cacheCreation: r.cacheCreation, cacheRead: r.cacheRead, model: r.model)
        }
        return byDay
    }

    // MARK: - Internal

    /// Group ALREADY-collapsed records into per-day totals. Caller collapses first.
    private static func aggregateByDay(_ collapsed: [UsageRecord]) -> [DailyUsage] {
        var byDay: [String: DayAccumulator] = [:]
        for r in collapsed {
            byDay[DayBucket.day(epoch: r.epoch), default: DayAccumulator()].add(r)
        }
        return byDay
            .map { $0.value.makeDailyUsage(date: $0.key) }
            .sorted { $0.date < $1.date }
    }
}

/// One day's running totals. Cost is per-record (each model has its own prices) and
/// computed at read time, then summed.
private struct DayAccumulator {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var cost = 0.0
    var models = Set<String>()

    mutating func add(_ r: UsageRecord) {
        input += r.input
        output += r.output
        cacheCreation += r.cacheCreation
        cacheRead += r.cacheRead
        if let model = r.model, model != "<synthetic>" { models.insert(model) }
        if let pricing = PricingStore.shared.pricing(for: r.model) {
            cost += pricing.cost(input: r.input, output: r.output,
                                 cacheCreation: r.cacheCreation, cacheRead: r.cacheRead)
        }
    }

    func makeDailyUsage(date: String) -> DailyUsage {
        DailyUsage(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            totalTokens: input + output + cacheCreation + cacheRead,
            totalCost: cost,
            models: models.sorted()
        )
    }
}
