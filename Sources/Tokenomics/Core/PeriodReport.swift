import Foundation

/// One model's contribution to a report (tokens by type + read-time cost).
struct ModelUsage: Codable, Equatable, Identifiable {
    let model: String
    let counts: TokenCounts
    let cost: Double
    var id: String { model }
    var tokens: Int { counts.total }
}

/// One vendor's contribution to a report (Claude / GPT).
struct VendorUsage: Codable, Equatable, Identifiable {
    let vendor: String          // display name, "Claude" / "GPT"
    let counts: TokenCounts
    let cost: Double
    var id: String { vendor }
    var tokens: Int { counts.total }
}

/// A fully-aggregated usage report for one period (day / week / month), computed from
/// archived records. Pure and `Codable` so the same value drives the view and any
/// export. This Mac only — see the report UI for the cross-machine caveat.
struct PeriodReport: Codable, Equatable {
    let period: ReportPeriod
    let key: String             // the period's stable id ("2026-06")
    let title: String           // human title ("June 2026")
    let isCurrent: Bool         // the period is still in progress (contains `now`)

    let total: TokenCounts
    let cost: Double
    let byVendor: [VendorUsage]
    let byModel: [ModelUsage]   // sorted by tokens, descending
    let days: [DailyUsage]      // only days with usage, ascending — the bar series

    let activeDays: Int         // days with any usage
    let totalDays: Int          // calendar days in the period (elapsed only, if current)
    let busiestDay: DailyUsage?
    let dailyAverage: Int       // tokens ÷ active days
    let longestStreak: Int      // longest run of consecutive active days

    let previousTokens: Int     // the prior period's total, for the delta
    let previousCost: Double
    let projectedTokens: Int?   // end-of-period projection (in-progress week/month only)
    let projectedCost: Double?
    let pricesFrozen: Bool      // every completed day's cost came from a frozen snapshot

    /// Build a report from per-day summaries spanning at least this period and the
    /// previous one — the unit that blends frozen snapshots with live-computed days.
    /// Everything derives under `calendar`'s timezone.
    static func make(daySummaries: [DaySnapshot], period: ReportPeriod, anchor: Date,
                     now: Date = Date(), calendar: Calendar = .current) -> PeriodReport {
        let range = period.range(containing: anchor, calendar: calendar)
        let prior = period.previous(range, calendar: calendar)
        // ISO day keys order lexically, so range membership is a string compare.
        let startKey = DayBucket.dayKey(range.start, calendar: calendar)
        let endKey = DayBucket.dayKey(range.end, calendar: calendar)             // exclusive
        let priorStartKey = DayBucket.dayKey(prior.start, calendar: calendar)
        let priorEndKey = DayBucket.dayKey(prior.end, calendar: calendar)
        let todayKey = DayBucket.dayKey(now, calendar: calendar)

        let inPeriod = daySummaries.filter { $0.date >= startKey && $0.date < endKey }
            .sorted { $0.date < $1.date }
        let inPrior = daySummaries.filter { $0.date >= priorStartKey && $0.date < priorEndKey }

        var total = TokenCounts()
        var cost = 0.0
        for day in inPeriod { total.add(day.total); cost += day.cost }

        let byVendor = Self.mergeVendors(inPeriod.flatMap(\.byVendor))
        let byModel = Self.mergeModels(inPeriod.flatMap(\.byModel))

        let days = inPeriod.map { d in
            DailyUsage(date: d.date, inputTokens: d.total.input, outputTokens: d.total.output,
                       cacheCreationTokens: d.total.cacheCreation, cacheReadTokens: d.total.cacheRead,
                       totalTokens: d.total.total, totalCost: d.cost, models: d.byModel.map(\.model).sorted())
        }

        let isCurrent = range.contains(now)
        let fullDays = range.dayCount(calendar: calendar)
        let elapsed = min(fullDays, max(1, (calendar.dateComponents([.day], from: range.start, to: now).day ?? 0) + 1))
        let totalDays = isCurrent ? elapsed : fullDays

        let activeDays = inPeriod.count
        let busiestDay = days.max { $0.totalTokens < $1.totalTokens }
        let dailyAverage = activeDays > 0 ? total.total / activeDays : 0
        let longestStreak = Self.longestStreak(days.map(\.date), calendar: calendar)

        let previousTokens = inPrior.reduce(0) { $0 + $1.total.total }
        let previousCost = inPrior.reduce(0) { $0 + $1.cost }

        // End-of-period projection — only while a multi-day period is still running
        // (a single day is already projected intraday in the menu bar). Projected as
        // completed days so far + a trailing 7-day average for the days left: a
        // same-period linear extrapolation whipsaws (day 1 of a month shows 31× one
        // day's usage, then decays every day), while the trailing window is stable
        // across day boundaries. Floored at the current total — a quiet week never
        // projects the period below what it already holds.
        var projectedTokens: Int?
        var projectedCost: Double?
        if isCurrent, period != .day, elapsed < fullDays {
            let trailingDays = 7
            let windowStart = calendar.date(byAdding: .day, value: -trailingDays, to: now) ?? now
            let windowStartKey = DayBucket.dayKey(windowStart, calendar: calendar)
            let window = daySummaries.filter { $0.date >= windowStartKey && $0.date < todayKey }
            let tokenRate = Double(window.reduce(0) { $0 + $1.total.total }) / Double(trailingDays)
            let costRate = window.reduce(0.0) { $0 + $1.cost } / Double(trailingDays)

            let today = inPeriod.first { $0.date == todayKey }
            let daysLeftIncludingToday = Double(fullDays - elapsed + 1)
            let completedTokens = Double(total.total - (today?.total.total ?? 0))
            let completedCost = cost - (today?.cost ?? 0)
            projectedTokens = max(Int(completedTokens + tokenRate * daysLeftIncludingToday), total.total)
            projectedCost = max(completedCost + costRate * daysLeftIncludingToday, cost)
        }

        // Costs are "frozen" (historical, not re-priced) when every completed day in
        // the period came from a stored snapshot. Today is always live and excluded.
        let pricesFrozen = inPeriod.filter { $0.date < todayKey }.allSatisfy(\.frozen)

        return PeriodReport(period: period, key: range.key, title: range.title, isCurrent: isCurrent,
                            total: total, cost: cost, byVendor: byVendor, byModel: byModel, days: days,
                            activeDays: activeDays, totalDays: totalDays, busiestDay: busiestDay,
                            dailyAverage: dailyAverage, longestStreak: longestStreak,
                            previousTokens: previousTokens, previousCost: previousCost,
                            projectedTokens: projectedTokens, projectedCost: projectedCost,
                            pricesFrozen: pricesFrozen)
    }

    /// Convenience: build from raw records (live cost, nothing frozen). Used by tests
    /// and as the report's fallback when no snapshot is available.
    static func make(records: [UsageRecord], period: ReportPeriod, anchor: Date,
                     now: Date = Date(), calendar: Calendar = .current) -> PeriodReport {
        let summaries = UsageAggregator.daySummaries(records, pricedAt: Int(now.timeIntervalSince1970),
                                                     frozen: false, calendar: calendar)
        return make(daySummaries: summaries, period: period, anchor: anchor, now: now, calendar: calendar)
    }

    /// Sum per-vendor counts + cost across days, sorted by tokens descending.
    private static func mergeVendors(_ entries: [VendorUsage]) -> [VendorUsage] {
        var counts: [String: TokenCounts] = [:]
        var costs: [String: Double] = [:]
        for e in entries {
            counts[e.vendor, default: TokenCounts()].add(e.counts)
            costs[e.vendor, default: 0] += e.cost
        }
        return counts.map { VendorUsage(vendor: $0.key, counts: $0.value, cost: costs[$0.key] ?? 0) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// Sum per-model counts + cost across days, sorted by tokens descending.
    private static func mergeModels(_ entries: [ModelUsage]) -> [ModelUsage] {
        var counts: [String: TokenCounts] = [:]
        var costs: [String: Double] = [:]
        for e in entries {
            counts[e.model, default: TokenCounts()].add(e.counts)
            costs[e.model, default: 0] += e.cost
        }
        return counts.map { ModelUsage(model: $0.key, counts: $0.value, cost: costs[$0.key] ?? 0) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// The period's days rolled up into calendar weeks — one `DailyUsage` per week,
    /// keyed by the week's START day, summing counts + cost and unioning model
    /// lists. Edge weeks that only partly overlap the period sum just the days the
    /// period holds. Feeds the month view's weekly bars through the same chart the
    /// daily series uses.
    func weeklyRollup(calendar: Calendar = .current) -> [DailyUsage] {
        var byWeek: [String: [DailyUsage]] = [:]
        for day in days {
            guard let date = Self.date(fromDayKey: day.date, calendar: calendar),
                  let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            else { continue }
            byWeek[DayBucket.dayKey(weekStart, calendar: calendar), default: []].append(day)
        }
        return byWeek.map { start, group in
            var input = 0, output = 0, cacheCreation = 0, cacheRead = 0, total = 0
            var cost = 0.0
            var models = Set<String>()
            for d in group {
                input += d.inputTokens; output += d.outputTokens
                cacheCreation += d.cacheCreationTokens; cacheRead += d.cacheReadTokens
                total += d.totalTokens; cost += d.totalCost
                models.formUnion(d.models)
            }
            return DailyUsage(date: start, inputTokens: input, outputTokens: output,
                              cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead,
                              totalTokens: total, totalCost: cost, models: models.sorted())
        }
        .sorted { $0.date < $1.date }
    }

    /// Reconstruct a "yyyy-MM-dd" day key into a Date under `calendar`, so day and
    /// week boundaries match how the keys were made.
    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Longest run of consecutive calendar days among the given day keys ("yyyy-MM-dd").
    /// Keys are reconstructed via `calendar` so day boundaries match how they were made.
    static func longestStreak(_ dayKeys: [String], calendar: Calendar = .current) -> Int {
        let dates = dayKeys.compactMap { Self.date(fromDayKey: $0, calendar: calendar) }.sorted()
        guard !dates.isEmpty else { return 0 }
        var longest = 1, current = 1
        for i in 1..<dates.count {
            if let next = calendar.date(byAdding: .day, value: 1, to: dates[i - 1]),
               calendar.isDate(next, inSameDayAs: dates[i]) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }
}
