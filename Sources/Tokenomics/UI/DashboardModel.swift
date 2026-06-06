import Foundation
import Combine

/// One 5-minute bucket of the intraday rate chart, split by token type.
struct RatePoint: Identifiable {
    let id: Int          // bucket start minute (0,5,10,…)
    let hour: Double     // x position in hours
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int

    var total: Int { input + output + cacheCreation + cacheRead }
}

/// Observable state the popover's SwiftUI view renders. Updated by AppDelegate on
/// each refresh; the view reacts via @Published.
final class DashboardModel: ObservableObject {
    @Published var headline: String = "Loading…"
    @Published var subtitle: String = ""
    @Published var models: [String] = []
    @Published var rate5min: [RatePoint] = []

    // Cumulative chart lines.
    @Published var cumToday: [CumPoint] = []
    @Published var cumTypical: [CumPoint] = []
    @Published var cumPredicted: [CumPoint] = []

    private static let bucketMinutes = 5

    /// Collapse per-minute token counts into 5-minute buckets up to `nowMinute`.
    /// Earlier buckets sit at their start minute; the in-progress final bucket is
    /// plotted at `now` (its value is the partial sum since the last 5-min mark),
    /// so the chart's right edge tracks the current time and advances each refresh.
    func updateRate(today: [TokenCounts], nowMinute: Int) {
        guard today.count == 1440 else { rate5min = []; return }
        let cap = min(max(nowMinute, 0), 1439)
        var points: [RatePoint] = []
        var start = 0
        while start <= cap {
            let end = min(start + Self.bucketMinutes, 1440)
            var agg = TokenCounts()
            for m in start..<end { agg.add(today[m]) }   // future minutes are 0 ⇒ partial bucket
            let atMinute = (start + Self.bucketMinutes > cap) ? cap : start
            points.append(RatePoint(id: start, hour: Double(atMinute) / 60.0,
                                    input: agg.input, output: agg.output,
                                    cacheCreation: agg.cacheCreation, cacheRead: agg.cacheRead))
            start += Self.bucketMinutes
        }
        rate5min = points
    }
}
