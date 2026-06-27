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

    /// Build a report for the period containing `anchor`. `records` are the archive's
    /// already-collapsed records spanning at least this period and the previous one.
    /// Everything derives at read time under `calendar`'s timezone and current prices.
    static func make(records: [UsageRecord], period: ReportPeriod, anchor: Date,
                     now: Date = Date(), calendar: Calendar = .current) -> PeriodReport {
        let range = period.range(containing: anchor, calendar: calendar)
        let prior = period.previous(range, calendar: calendar)

        let periodRecords = records.filter { range.contains(epoch: $0.epoch) }
        let priorRecords = records.filter { prior.contains(epoch: $0.epoch) }

        let days = UsageAggregator.daily(periodRecords, calendar: calendar)
        let total = days.reduce(into: TokenCounts()) { $0.add($1.counts) }
        let cost = days.reduce(0) { $0 + $1.totalCost }

        let vendorSeries = UsageAggregator.byVendor(periodRecords, calendar: calendar)
        let byVendor: [VendorUsage] = Vendor.allCases.compactMap { vendor in
            guard let vdays = vendorSeries[vendor.providerID], !vdays.isEmpty else { return nil }
            return VendorUsage(vendor: vendor.displayName,
                               counts: vdays.reduce(into: TokenCounts()) { $0.add($1.counts) },
                               cost: vdays.reduce(0) { $0 + $1.totalCost })
        }

        let byModel = UsageAggregator.byModel(periodRecords)

        let isCurrent = range.contains(now)
        let fullDays = range.dayCount(calendar: calendar)
        let elapsed = min(fullDays, max(1, (calendar.dateComponents([.day], from: range.start, to: now).day ?? 0) + 1))
        let totalDays = isCurrent ? elapsed : fullDays

        let activeDays = days.count
        let busiestDay = days.max { $0.totalTokens < $1.totalTokens }
        let dailyAverage = activeDays > 0 ? total.total / activeDays : 0
        let longestStreak = Self.longestStreak(days.map(\.date), calendar: calendar)

        let priorDays = UsageAggregator.daily(priorRecords, calendar: calendar)
        let previousTokens = priorDays.reduce(0) { $0 + $1.totalTokens }
        let previousCost = priorDays.reduce(0) { $0 + $1.totalCost }

        // Linear end-of-period projection — only while a multi-day period is still
        // running (a single day is already projected intraday in the menu bar).
        var projectedTokens: Int?
        var projectedCost: Double?
        if isCurrent, period != .day, elapsed < fullDays {
            let factor = Double(fullDays) / Double(elapsed)
            projectedTokens = Int(Double(total.total) * factor)
            projectedCost = cost * factor
        }

        return PeriodReport(period: period, key: range.key, title: range.title, isCurrent: isCurrent,
                            total: total, cost: cost, byVendor: byVendor, byModel: byModel, days: days,
                            activeDays: activeDays, totalDays: totalDays, busiestDay: busiestDay,
                            dailyAverage: dailyAverage, longestStreak: longestStreak,
                            previousTokens: previousTokens, previousCost: previousCost,
                            projectedTokens: projectedTokens, projectedCost: projectedCost)
    }

    /// Longest run of consecutive calendar days among the given day keys ("yyyy-MM-dd").
    /// Keys are reconstructed via `calendar` so day boundaries match how they were made.
    static func longestStreak(_ dayKeys: [String], calendar: Calendar = .current) -> Int {
        let dates = dayKeys.compactMap { key -> Date? in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }.sorted()
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
