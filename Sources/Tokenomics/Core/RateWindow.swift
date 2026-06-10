import Foundation

/// Builds the sliding "last N minutes" window for the real-time rate chart from a
/// day-keyed minute matrix, stitching across the local midnight boundary (the tail
/// of yesterday + the head of today). Pure and deterministic given `(matrix, now)`.
enum RateWindow {
    /// The last `count` minute buckets ending at — and including — the current
    /// minute. Days missing from the matrix contribute empty buckets, so the
    /// result always has exactly `count` elements (index `count-1` == "now").
    static func lastMinutes(matrix: [String: [MinuteBucket]],
                            now: Date,
                            count: Int,
                            calendar: Calendar = .current) -> [MinuteBucket] {
        guard count > 0 else { return [] }
        let empty = [MinuteBucket]()

        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let nowMinute = min(1439, (comps.hour ?? 0) * 60 + (comps.minute ?? 0))

        func dayMinutes(_ date: Date) -> [MinuteBucket] {
            let day = matrix[DayBucket.dayKey(date, calendar: calendar)] ?? empty
            return day.count == 1440 ? day : Array(repeating: MinuteBucket(), count: 1440)
        }

        let today = dayMinutes(now)
        let start = nowMinute - count + 1
        if start >= 0 {
            return Array(today[start...nowMinute])
        }

        // Window crosses local midnight: take the tail of yesterday first.
        // (On a DST-shifted 23h/25h day the stitch is off by the shift — acceptable
        // for a cosmetic rate chart.)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map(dayMinutes)
            ?? Array(repeating: MinuteBucket(), count: 1440)
        return Array(yesterday[(1440 + start)...]) + Array(today[0...nowMinute])
    }
}
