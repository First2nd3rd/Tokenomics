import Foundation

/// Turns a raw `UsageSnapshot` into the figures the menu bar shows: whether today
/// has data, the headline day, and a recent-average anchor. The end-of-day
/// projection comes from `IntradayCurve` (the same curve drawn in the popover), so
/// the headline number and the chart agree. Pure and deterministic given
/// `(snapshot, now)`.
struct Dashboard {
    /// How many prior days feed the "recent average" anchor.
    private static let averageWindow = 7

    let isToday: Bool               // whether `headline` is actually today
    let headline: DailyUsage?       // today ?? most recent day (the big number)
    let avgTokens: Int?             // mean over up to `averageWindow` prior days

    static func make(from snapshot: UsageSnapshot,
                     now: Date,
                     calendar: Calendar = .current) -> Dashboard {
        let days = snapshot.days    // sorted ascending by date
        let todayKey = DayBucket.dayKey(now, calendar: calendar)

        let todayEntry = days.last(where: { $0.date == todayKey })
        let headline = todayEntry ?? days.last
        let isToday = todayEntry != nil

        // Recent average excludes the headline day itself.
        let prior = days.filter { $0.date != headline?.date }
        let window = Array(prior.suffix(averageWindow))
        let avgTokens = window.isEmpty
            ? nil : window.reduce(0) { $0 + $1.totalTokens } / window.count

        return Dashboard(isToday: isToday, headline: headline, avgTokens: avgTokens)
    }
}
