import Foundation
import Combine

/// One 5-minute bucket of the intraday rate chart.
struct RatePoint: Identifiable {
    let id: Int          // bucket start minute (0,5,10,…)
    let hour: Double     // x position in hours (startMinute / 60)
    let tokens: Int
}

/// Observable state the popover's SwiftUI view renders. Updated by AppDelegate on
/// each refresh; the view reacts via @Published.
final class DashboardModel: ObservableObject {
    @Published var headline: String = "Loading…"
    @Published var subtitle: String = ""
    @Published var rate5min: [RatePoint] = []
    @Published var nowHour: Double = 24      // local hour-of-day, drives the x-axis extent

    private static let bucketMinutes = 5

    /// Collapse 1440 per-minute token counts into 5-minute buckets for the chart.
    func updateRate(fromMinuteTokens minutes: [Int]) {
        guard minutes.count == 1440 else { rate5min = []; return }
        var points: [RatePoint] = []
        points.reserveCapacity(1440 / Self.bucketMinutes)
        var start = 0
        while start < 1440 {
            let end = min(start + Self.bucketMinutes, 1440)
            let sum = minutes[start..<end].reduce(0, +)
            points.append(RatePoint(id: start, hour: Double(start) / 60.0, tokens: sum))
            start += Self.bucketMinutes
        }
        rate5min = points
    }
}
