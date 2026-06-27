import Foundation

/// Turns a raw `UsageSnapshot` into the figures the menu bar shows. The headline is
/// ALWAYS today (a zero day when there's no usage yet), so the big number never
/// silently shows a past day; `lastActive` carries the most recent day that did have
/// usage, for a "last active …" subtitle on a quiet day. The end-of-day projection
/// comes from `IntradayCurve` (the same curve drawn in the popover), so the headline
/// number and the chart agree. Pure and deterministic given `(snapshot, now)`.
struct Dashboard {
    /// How many prior days feed the "recent average" anchor.
    private static let averageWindow = 7

    let hasUsageToday: Bool         // whether today has any tokens yet
    let headline: DailyUsage?       // ALWAYS today (zero if idle); nil only with no data at all
    let lastActive: DailyUsage?     // most recent PRIOR day with usage (subtitle context when idle today)
    let avgTokens: Int?             // mean over up to `averageWindow` prior days (today excluded)

    static func make(from snapshot: UsageSnapshot,
                     now: Date,
                     calendar: Calendar = .current) -> Dashboard {
        let days = snapshot.days    // sorted ascending by date
        let todayKey = DayBucket.dayKey(now, calendar: calendar)

        let todayEntry = days.last(where: { $0.date == todayKey })
        let hasUsageToday = (todayEntry?.totalTokens ?? 0) > 0

        // Headline is always "today": the real entry, or a zero day so the number is
        // honest instead of quietly showing yesterday. nil only when there's no data.
        let headline: DailyUsage?
        if let todayEntry {
            headline = todayEntry
        } else if days.isEmpty {
            headline = nil
        } else {
            headline = DailyUsage(date: todayKey, inputTokens: 0, outputTokens: 0,
                                  cacheCreationTokens: 0, cacheReadTokens: 0,
                                  totalTokens: 0, totalCost: 0, models: [])
        }

        // Most recent PRIOR day that actually had usage — shown as "last active …"
        // when today is still empty.
        let lastActive = days.last(where: { $0.date != todayKey && $0.totalTokens > 0 })

        // Recent average excludes today (in progress / empty).
        let prior = days.filter { $0.date != todayKey }
        let window = Array(prior.suffix(averageWindow))
        let avgTokens = window.isEmpty
            ? nil : window.reduce(0) { $0 + $1.totalTokens } / window.count

        return Dashboard(hasUsageToday: hasUsageToday, headline: headline,
                         lastActive: lastActive, avgTokens: avgTokens)
    }
}
