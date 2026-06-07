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
}
