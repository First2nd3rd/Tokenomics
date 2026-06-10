import Foundation
import Combine

/// One bucket of a rate chart: counts by type + per-model totals. `x` is in the
/// owning chart's unit — hours-of-day for the full-day chart, minutes-ago
/// (negative → 0 = now) for the live sliding window.
struct RatePoint: Identifiable {
    let id: Int
    let x: Double
    let counts: TokenCounts
    let byModel: [String: Int]

    var total: Int { counts.total }
}

/// Observable state the popover's SwiftUI view renders. Updated by AppDelegate on
/// each refresh; the view reacts via @Published.
final class DashboardModel: ObservableObject {
    @Published var headline: String = "Loading…"
    @Published var subtitle: String = ""
    @Published var models: [String] = []
    @Published var rate5min: [RatePoint] = []
    /// The last hour at 1-minute resolution; the whole series shifts left each
    /// refresh (x = minutes ago, −59…0).
    @Published var rateLive: [RatePoint] = []

    // Cumulative chart lines.
    @Published var cumToday: [CumPoint] = []
    @Published var cumTypical: [CumPoint] = []
    @Published var cumPredicted: [CumPoint] = []

    // Per-vendor subscription break-even (this month).
    @Published var breakEven: [VendorBreakEven] = []

    // Recent days for the daily stacked-by-type bar chart (ascending by date).
    @Published var dailyBars: [DailyUsage] = []

    private static let bucketMinutes = 5

    /// Collapse per-minute token counts into 5-minute buckets up to `nowMinute`.
    /// Earlier buckets sit at their start minute; the in-progress final bucket is
    /// plotted at `now` (its value is the partial sum since the last 5-min mark),
    /// so the chart's right edge tracks the current time and advances each refresh.
    func updateRate(today: [MinuteBucket], nowMinute: Int) {
        guard today.count == 1440 else { rate5min = []; return }
        let cap = min(max(nowMinute, 0), 1439)
        var points: [RatePoint] = []
        var start = 0
        while start <= cap {
            let end = min(start + Self.bucketMinutes, 1440)
            var agg = MinuteBucket()
            for m in start..<end { agg.add(today[m]) }   // future minutes are empty ⇒ partial bucket
            let atMinute = (start + Self.bucketMinutes > cap) ? cap : start
            points.append(RatePoint(id: start, x: Double(atMinute) / 60.0,
                                    counts: agg.counts, byModel: agg.byModel))
            start += Self.bucketMinutes
        }
        rate5min = points
    }

    /// Map the sliding window (oldest → now) onto minutes-ago positions, so the
    /// newest bucket sits at 0 and everything drifts left as time passes.
    func updateLive(window: [MinuteBucket]) {
        let n = window.count
        rateLive = window.enumerated().map { i, bucket in
            RatePoint(id: i, x: Double(i - (n - 1)), counts: bucket.counts, byModel: bucket.byModel)
        }
    }
}
