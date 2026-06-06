import Foundation

/// Turns a raw `UsageSnapshot` into the numbers the menu bar (and, later, the
/// widget) actually display: today's running total, a run-rate projection for
/// end-of-day, and recent-average anchors for comparison.
///
/// Pure and deterministic given `(snapshot, now)`, so it is trivially testable
/// and reusable across every presentation surface.
struct Dashboard {
    /// Below this fraction of the day elapsed, a run-rate projection is too
    /// volatile to be meaningful (e.g. one burst right after midnight would
    /// extrapolate to an absurd daily total). ~01:55 local.
    private static let minProjectableFraction = 0.08

    /// How many prior days feed the "recent average" anchor.
    private static let averageWindow = 7

    let today: DailyUsage?          // entry whose date == local today, if any
    let isToday: Bool               // whether `headline` is actually today
    let headline: DailyUsage?       // today ?? most recent day (the big number)
    let previousDay: DailyUsage?    // most recent day before `headline`

    let dayFraction: Double         // 0...1 of the local day elapsed
    let projectedTokens: Int?       // run-rate end-of-day estimate
    let projectedCost: Double?

    let avgTokens: Int?             // mean over up to `averageWindow` prior days
    let avgCost: Double?

    static func make(from snapshot: UsageSnapshot,
                     now: Date,
                     calendar: Calendar = .current) -> Dashboard {
        let days = snapshot.days    // sorted ascending by date
        let todayKey = dayKey(now, calendar: calendar)

        let todayEntry = days.last(where: { $0.date == todayKey })
        let headline = todayEntry ?? days.last
        let isToday = todayEntry != nil

        // The day immediately before the headline entry (gap-tolerant: takes the
        // previous entry in the data, which may skip days with no usage).
        var previousDay: DailyUsage?
        if let h = headline,
           let idx = days.firstIndex(where: { $0.date == h.date }), idx > 0 {
            previousDay = days[idx - 1]
        }

        // Recent average excludes the headline day itself.
        let prior = days.filter { $0.date != headline?.date }
        let window = Array(prior.suffix(averageWindow))
        let avgTokens = window.isEmpty
            ? nil : window.reduce(0) { $0 + $1.totalTokens } / window.count
        let avgCost = window.isEmpty
            ? nil : window.reduce(0.0) { $0 + $1.totalCost } / Double(window.count)

        // Run-rate projection — only meaningful when the headline is actually
        // today and enough of the day has elapsed.
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
            today: todayEntry,
            isToday: isToday,
            headline: headline,
            previousDay: previousDay,
            dayFraction: fraction,
            projectedTokens: projTokens,
            projectedCost: projCost,
            avgTokens: avgTokens,
            avgCost: avgCost
        )
    }

    // MARK: - Date helpers

    /// Local calendar-day key like "2026-06-03", matching ccusage's `period`.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
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
