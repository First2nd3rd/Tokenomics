import Foundation

/// Turns a raw `UsageSnapshot` into the figures the menu bar shows: whether today
/// has data, the headline day, a run-rate end-of-day projection, and a
/// recent-average anchor. Pure and deterministic given `(snapshot, now)`.
struct Dashboard {
    /// Below this fraction of the day elapsed, a run-rate projection is too
    /// volatile to be meaningful (a burst right after midnight would extrapolate
    /// to an absurd daily total). ~01:55 local.
    private static let minProjectableFraction = 0.08

    /// How many prior days feed the "recent average" anchor.
    private static let averageWindow = 7

    let isToday: Bool               // whether `headline` is actually today
    let headline: DailyUsage?       // today ?? most recent day (the big number)
    let projectedTokens: Int?       // run-rate end-of-day estimate
    let projectedCost: Double?
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

        // Run-rate projection — only when the headline is actually today and enough
        // of the day has elapsed.
        let fraction = fractionOfDayElapsed(now, calendar: calendar)
        var projTokens: Int?
        var projCost: Double?
        if isToday, let t = todayEntry,
           fraction >= minProjectableFraction, t.totalTokens > 0 {
            let raw = Double(t.totalTokens) / fraction
            projTokens = raw < Double(Int.max) ? Int(raw) : Int.max
            projCost = t.totalCost / fraction
        }

        return Dashboard(
            isToday: isToday,
            headline: headline,
            projectedTokens: projTokens,
            projectedCost: projCost,
            avgTokens: avgTokens
        )
    }

    /// Fraction (0...1) of the local day elapsed at `now`.
    static func fractionOfDayElapsed(_ now: Date, calendar: Calendar) -> Double {
        // Use the calendar day's actual duration so DST 23h/25h days stay correct;
        // a failed lookup returns 0, which disables projection via the guard above.
        guard let interval = calendar.dateInterval(of: .day, for: now) else { return 0 }
        let elapsed = now.timeIntervalSince(interval.start)
        return min(max(elapsed / interval.duration, 0), 1)
    }
}
