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
    static func daily(_ records: [UsageRecord], calendar: Calendar = .current) -> [DailyUsage] {
        aggregateByDay(Dedup.collapse(records), calendar: calendar)
    }

    /// Per-vendor daily series (provider id → days), deduped across the whole union.
    /// Collapse runs once over the union; the per-source split happens afterward, so
    /// a duplicate that appears under two sources is still removed before splitting.
    static func byVendor(_ records: [UsageRecord], calendar: Calendar = .current) -> [String: [DailyUsage]] {
        byVendor(collapsed: Dedup.collapse(records), calendar: calendar)
    }

    /// Same, for records the caller ALREADY collapsed — the per-tick refresh dedups
    /// the union once and shares it across every same-tick view.
    static func byVendor(collapsed: [UsageRecord], calendar: Calendar = .current) -> [String: [DailyUsage]] {
        var out: [String: [DailyUsage]] = [:]
        for (source, recs) in Dictionary(grouping: collapsed, by: { $0.source }) {
            out[vendorId(for: source)] = aggregateByDay(recs, calendar: calendar)
        }
        return out
    }

    /// Per-machine daily series (machine id → days), deduped across the whole union.
    /// A record's `nil` machine means it came from the local Mac (`localMachine`).
    static func byMachine(_ records: [UsageRecord],
                          localMachine: String = DeviceIdentity.id) -> [String: [DailyUsage]] {
        let collapsed = Dedup.collapse(records)
        var out: [String: [DailyUsage]] = [:]
        for (machine, recs) in Dictionary(grouping: collapsed, by: { $0.machine ?? localMachine }) {
            out[machine] = aggregateByDay(recs)
        }
        return out
    }

    /// Per-model totals (tokens by type + cost), deduped across the union, sorted by
    /// tokens descending. The `<synthetic>` placeholder model is excluded, matching
    /// the daily aggregator. Cost is per-record at read-time prices, then summed.
    static func byModel(_ records: [UsageRecord]) -> [ModelUsage] {
        var acc: [String: ModelAccumulator] = [:]
        for r in Dedup.collapse(records) {
            guard let model = r.model, model != "<synthetic>" else { continue }
            acc[model, default: ModelAccumulator()].add(r)
        }
        return acc
            .map { $0.value.makeModelUsage(model: $0.key) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// One `DaySnapshot` per day with usage, deduped across the union. Each carries
    /// the day's totals, cost (at current prices), and per-vendor / per-model splits —
    /// the unit both the report and the snapshot writer consume. `frozen` tags whether
    /// the caller is persisting these as historical (true) or computing live (false).
    static func daySummaries(_ records: [UsageRecord], pricedAt: Int, frozen: Bool,
                             calendar: Calendar = .current) -> [DaySnapshot] {
        let byDay = Dictionary(grouping: Dedup.collapse(records, foldKeyless: true)) {
            DayBucket.day(epoch: $0.epoch, calendar: calendar)
        }
        return byDay.map { day, recs in
            var total = TokenCounts()
            for r in recs {
                total.add(input: r.input, output: r.output, cacheCreation: r.cacheCreation, cacheRead: r.cacheRead)
            }
            let byVendor: [VendorUsage] = Vendor.allCases.compactMap { vendor in
                let vrecs = recs.filter { vendorId(for: $0.source) == vendor.providerID }
                guard !vrecs.isEmpty else { return nil }
                var counts = TokenCounts()
                for r in vrecs {
                    counts.add(input: r.input, output: r.output, cacheCreation: r.cacheCreation, cacheRead: r.cacheRead)
                }
                return VendorUsage(vendor: vendor.displayName, counts: counts, cost: cost(vrecs))
            }
            return DaySnapshot(date: day, total: total, cost: cost(recs), pricedAt: pricedAt,
                               frozen: frozen, byVendor: byVendor, byModel: byModel(recs))
        }
        .sorted { $0.date < $1.date }
    }

    /// Total read-time cost of a record set (per-record pricing, summed). Unknown
    /// models (e.g. `<synthetic>`) price to $0.
    static func cost(_ records: [UsageRecord]) -> Double {
        var total = 0.0
        for r in records {
            if let pricing = PricingStore.shared.pricing(for: r.model) {
                total += pricing.cost(input: r.input, output: r.output,
                                      cacheCreation: r.cacheCreation, cacheRead: r.cacheRead)
            }
        }
        return total
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

    /// Combined and LOCAL-ONLY day→minute matrices in one pass. The live last-hour
    /// chart draws the local series at true height plus a (combined − local) peer
    /// overlay — a record's `nil` machine is the local Mac. The peer overlay therefore
    /// lags naturally: a not-yet-synced recent minute has combined == local ⇒ 0.
    static func splitDayMinuteMatrix(_ records: [UsageRecord])
        -> (combined: [String: [MinuteBucket]], local: [String: [MinuteBucket]]) {
        splitDayMinuteMatrix(collapsed: Dedup.collapse(records))
    }

    /// Same, for records the caller ALREADY collapsed (see `byVendor(collapsed:)`).
    static func splitDayMinuteMatrix(collapsed: [UsageRecord])
        -> (combined: [String: [MinuteBucket]], local: [String: [MinuteBucket]]) {
        var combined: [String: [MinuteBucket]] = [:]
        var local: [String: [MinuteBucket]] = [:]
        for r in collapsed {
            let (day, minute) = DayBucket.dayMinute(epoch: r.epoch)
            combined[day, default: Array(repeating: MinuteBucket(), count: 1440)][minute]
                .add(input: r.input, output: r.output,
                     cacheCreation: r.cacheCreation, cacheRead: r.cacheRead, model: r.model)
            if r.machine == nil {
                local[day, default: Array(repeating: MinuteBucket(), count: 1440)][minute]
                    .add(input: r.input, output: r.output,
                         cacheCreation: r.cacheCreation, cacheRead: r.cacheRead, model: r.model)
            }
        }
        return (combined, local)
    }

    // MARK: - Internal

    /// Group ALREADY-collapsed records into per-day totals. Caller collapses first.
    private static func aggregateByDay(_ collapsed: [UsageRecord], calendar: Calendar = .current) -> [DailyUsage] {
        var byDay: [String: DayAccumulator] = [:]
        for r in collapsed {
            byDay[DayBucket.day(epoch: r.epoch, calendar: calendar), default: DayAccumulator()].add(r)
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

/// One model's running totals (tokens by type + read-time cost).
private struct ModelAccumulator {
    var counts = TokenCounts()
    var cost = 0.0

    mutating func add(_ r: UsageRecord) {
        counts.add(input: r.input, output: r.output, cacheCreation: r.cacheCreation, cacheRead: r.cacheRead)
        if let pricing = PricingStore.shared.pricing(for: r.model) {
            cost += pricing.cost(input: r.input, output: r.output,
                                 cacheCreation: r.cacheCreation, cacheRead: r.cacheRead)
        }
    }

    func makeModelUsage(model: String) -> ModelUsage {
        ModelUsage(model: model, counts: counts, cost: cost)
    }
}
