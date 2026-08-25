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

/// One calendar month's rollup inside the all-time report: totals plus the same
/// per-vendor / per-model splits a `DaySnapshot` carries, so the monthly trend chart
/// and the lifetime break-even derive from one shape.
struct MonthUsage: Codable, Equatable, Identifiable {
    let month: String           // "2026-06"
    let counts: TokenCounts
    let cost: Double
    let byVendor: [VendorUsage]
    let byModel: [ModelUsage]
    var id: String { month }
    var tokens: Int { counts.total }
}

/// A fully-aggregated usage report for one period (day / week / month / all time),
/// computed from archived records. Pure and `Codable` so the same value drives the
/// view and any export. This Mac only — see the report UI for the cross-machine caveat.
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
    /// Hour-of-day buckets (24), day period only — the single-day intraday chart.
    let hourly: [TokenCounts]?

    /// One fixed intraday slot of one day (3-hour slots today). `slot` indexes
    /// within the day, so a bucket's place on the axis is (day, slot).
    struct SlotBucket: Codable, Equatable {
        let day: String         // ISO day key, "2026-07-28"
        let slot: Int           // 0-based slot within the day
        let counts: TokenCounts

        /// Chart axis identity: day + slot, ordered lexically (slot count ≤ 9).
        var axisKey: String { "\(day)#\(slot)" }
    }

    /// PER-HOUR slots spanning the whole period (week period only) — the chart's
    /// click-to-toggle higher-density view. Carried at hour resolution so the view
    /// can regroup to any density without a reload; empty slots included, so the
    /// series is continuous across the week.
    let fine: [SlotBucket]?

    /// Calendar-month rollups, ascending and gapless from the first recorded month
    /// through the current one — silent months carry zero entries so the monthly
    /// trend charts keep a truthful time axis (all-time period only). Like
    /// `hourly`/`fine`, a period-specific extra the other granularities leave nil.
    let months: [MonthUsage]?

    /// Distinct calendar weeks with any usage (all-time period only) — the activity
    /// strip's per-week average, precomputed off the render path.
    let activeWeeks: Int?

    /// Merge per-hour slots into `hours`-wide slots (a divisor of 24). Pure — the
    /// week chart's density stepper calls this on every change.
    static func regroup(_ hourly: [SlotBucket], hours: Int) -> [SlotBucket] {
        guard hours > 1 else { return hourly }
        var merged: [String: [Int: TokenCounts]] = [:]
        for bucket in hourly {
            merged[bucket.day, default: [:]][bucket.slot / hours, default: TokenCounts()].add(bucket.counts)
        }
        return merged.keys.sorted().flatMap { day in
            merged[day]!.keys.sorted().map { SlotBucket(day: day, slot: $0, counts: merged[day]![$0]!) }
        }
    }

    /// Build a report from per-day summaries spanning at least this period and the
    /// previous one — the unit that blends frozen snapshots with live-computed days.
    /// Everything derives under `calendar`'s timezone.
    static func make(daySummaries: [DaySnapshot], period: ReportPeriod, anchor: Date,
                     now: Date = Date(), calendar: Calendar = .current,
                     hourly: [TokenCounts]? = nil, fine: [SlotBucket]? = nil) -> PeriodReport {
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
                            pricesFrozen: pricesFrozen, hourly: hourly, fine: fine,
                            months: nil, activeWeeks: nil)
    }

    /// Build the all-time report: every day summary there is, plus calendar-month
    /// rollups. No previous period, no projection — the delta and projection fields
    /// stay empty and the view leads with the activity heatmap instead.
    static func makeAllTime(daySummaries: [DaySnapshot], now: Date = Date(),
                            calendar: Calendar = .current) -> PeriodReport {
        let todayKey = DayBucket.dayKey(now, calendar: calendar)
        let summaries = daySummaries.filter { $0.date <= todayKey }.sorted { $0.date < $1.date }

        var total = TokenCounts()
        var cost = 0.0
        for day in summaries { total.add(day.total); cost += day.cost }

        let byVendor = Self.mergeVendors(summaries.flatMap(\.byVendor))
        let byModel = Self.mergeModels(summaries.flatMap(\.byModel))

        let days = summaries.map { d in
            DailyUsage(date: d.date, inputTokens: d.total.input, outputTokens: d.total.output,
                       cacheCreationTokens: d.total.cacheCreation, cacheReadTokens: d.total.cacheRead,
                       totalTokens: d.total.total, totalCost: d.cost, models: d.byModel.map(\.model).sorted())
        }

        // Elapsed span: first recorded day through today, inclusive.
        var totalDays = 0
        if let firstKey = summaries.first?.date, let first = Self.date(fromDayKey: firstKey, calendar: calendar) {
            totalDays = (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0) + 1
        }

        // Month rollups, then filled gapless through the current month — a silent
        // month must occupy its slot on the (categorical) chart axis, not vanish.
        var rolled: [String: MonthUsage] = [:]
        for (month, group) in Dictionary(grouping: summaries, by: { String($0.date.prefix(7)) }) {
            var counts = TokenCounts()
            var monthCost = 0.0
            for day in group { counts.add(day.total); monthCost += day.cost }
            rolled[month] = MonthUsage(month: month, counts: counts, cost: monthCost,
                                       byVendor: Self.mergeVendors(group.flatMap(\.byVendor)),
                                       byModel: Self.mergeModels(group.flatMap(\.byModel)))
        }
        var months: [MonthUsage] = []
        if let firstKey = summaries.first?.date, let first = Self.date(fromDayKey: firstKey, calendar: calendar) {
            let endKey = DayBucket.monthKey(now, calendar: calendar)
            var cursor = calendar.dateInterval(of: .month, for: first)?.start ?? first
            var key = DayBucket.monthKey(cursor, calendar: calendar)
            while key <= endKey {
                months.append(rolled[key] ?? MonthUsage(month: key, counts: TokenCounts(), cost: 0,
                                                        byVendor: [], byModel: []))
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
                key = DayBucket.monthKey(cursor, calendar: calendar)
            }
        }

        // Distinct calendar weeks with usage, for the strip's per-week average.
        var weekStarts = Set<String>()
        for day in days {
            guard let date = Self.date(fromDayKey: day.date, calendar: calendar),
                  let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            else { continue }
            weekStarts.insert(DayBucket.dayKey(start, calendar: calendar))
        }

        return PeriodReport(period: .all, key: "all", title: "All Time", isCurrent: true,
                            total: total, cost: cost, byVendor: byVendor, byModel: byModel, days: days,
                            activeDays: summaries.count, totalDays: totalDays,
                            busiestDay: days.max { $0.totalTokens < $1.totalTokens },
                            dailyAverage: summaries.isEmpty ? 0 : total.total / summaries.count,
                            longestStreak: Self.longestStreak(days.map(\.date), calendar: calendar),
                            previousTokens: 0, previousCost: 0,
                            projectedTokens: nil, projectedCost: nil,
                            pricesFrozen: summaries.filter { $0.date < todayKey }.allSatisfy(\.frozen),
                            hourly: nil, fine: nil, months: months, activeWeeks: weekStarts.count)
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
