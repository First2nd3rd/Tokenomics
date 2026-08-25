import Foundation

/// One vendor's month-to-date value: how much API-equivalent cost has accrued
/// this calendar month against the user's subscription fee for that vendor.
/// Pure and deterministic given its inputs.
struct VendorBreakEven: Identifiable {
    let vendor: Vendor
    let basis: CostBasis
    let monthToDateCost: Double      // API-equivalent USD spent this month
    let brokeEvenOn: String?         // day the running cost first reached the fee (nil: not yet / API)

    var id: String { vendor.rawValue }
    var monthlyFee: Double? { basis.monthlyFee }

    /// cost ÷ fee — how many times over the subscription has paid for itself.
    /// nil for API (no fee to break even against).
    var multiple: Double? {
        guard let fee = monthlyFee, fee > 0 else { return nil }
        return monthToDateCost / fee
    }

    /// 0…1 progress toward break-even (capped at 1). nil for API.
    var progress: Double? {
        multiple.map { min(1.0, $0) }
    }
}

/// One vendor's lifetime value: total API-equivalent cost across all recorded
/// months against the subscription fee paid each of those months. The fee side
/// assumes the CURRENT plan held since the vendor's first recorded month — the
/// stored basis has no start date or history, so this is the honest approximation
/// (the view notes it). Pure and deterministic given its inputs.
struct VendorLifetime: Identifiable {
    let vendor: Vendor
    let basis: CostBasis
    let totalCost: Double            // API-equivalent USD across all recorded months
    let monthsCount: Int             // vendor's first active month → current month, inclusive

    var id: String { vendor.rawValue }
    var monthlyFee: Double? { basis.monthlyFee }

    /// Total subscription spend over the span. nil for API.
    var totalFees: Double? { monthlyFee.map { $0 * Double(monthsCount) } }

    /// cost ÷ all fees paid — how many times over the subscription has paid for
    /// itself across its lifetime. nil for API or before any recorded month.
    var multiple: Double? {
        guard let fees = totalFees, fees > 0 else { return nil }
        return totalCost / fees
    }

    /// 0…1 progress toward lifetime break-even (capped at 1). nil for API.
    var progress: Double? { multiple.map { min(1.0, $0) } }
}

/// Builds the per-vendor break-even from each vendor's daily series and the user's
/// chosen cost basis. "This month" is the current local calendar month.
enum BreakEven {
    static func compute(perVendor: [String: [DailyUsage]],
                        now: Date,
                        claude: CostBasis,
                        gpt: CostBasis,
                        calendar: Calendar = .current) -> [VendorBreakEven] {
        let monthPrefix = String(DayBucket.dayKey(now, calendar: calendar).prefix(7))   // "yyyy-MM"

        func make(_ vendor: Vendor, _ basis: CostBasis) -> VendorBreakEven {
            let days = (perVendor[vendor.providerID] ?? [])
                .filter { $0.date.hasPrefix(monthPrefix) }
                .sorted { $0.date < $1.date }
            let cost = days.reduce(0) { $0 + $1.totalCost }

            var brokeEven: String?
            if case .subscription(let fee) = basis, fee > 0 {
                var running = 0.0
                for day in days {
                    running += day.totalCost
                    if running >= fee { brokeEven = day.date; break }
                }
            }
            return VendorBreakEven(vendor: vendor, basis: basis,
                                   monthToDateCost: cost, brokeEvenOn: brokeEven)
        }

        return [make(.claude, claude), make(.gpt, gpt)]
    }

    /// Lifetime break-even from the all-time report's monthly rollups: each vendor's
    /// total cost against fee × months since ITS OWN first recorded month (vendors
    /// adopted at different times each get a fair span).
    static func lifetime(months: [MonthUsage], now: Date,
                         claude: CostBasis, gpt: CostBasis,
                         calendar: Calendar = .current) -> [VendorLifetime] {
        let currentMonth = DayBucket.monthKey(now, calendar: calendar)

        func ordinal(_ monthKey: String) -> Int? {
            let parts = monthKey.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return parts[0] * 12 + (parts[1] - 1)
        }

        func make(_ vendor: Vendor, _ basis: CostBasis) -> VendorLifetime {
            var totalCost = 0.0
            var firstMonth: String?
            for month in months {
                guard let usage = month.byVendor.first(where: { $0.vendor == vendor.displayName })
                else { continue }
                totalCost += usage.cost
                if firstMonth == nil { firstMonth = month.month }
            }
            var span = 0
            if let firstMonth, let first = ordinal(firstMonth), let current = ordinal(currentMonth) {
                span = max(1, current - first + 1)
            }
            return VendorLifetime(vendor: vendor, basis: basis,
                                  totalCost: totalCost, monthsCount: span)
        }

        return [make(.claude, claude), make(.gpt, gpt)]
    }
}
