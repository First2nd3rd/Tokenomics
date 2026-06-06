import Foundation

/// Converts a UTC ISO-8601 timestamp to a local "yyyy-MM-dd" day key — the same
/// local-timezone bucketing ccusage uses. Shared by every provider.
enum DayBucket {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func localDay(from timestamp: String) -> String? {
        guard let date = parse(timestamp) else { return nil }
        return dayFormatter.string(from: date)
    }

    /// Local calendar-day key like "2026-06-03", matching ccusage's `period`.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Local day key plus minute-of-day (0…1439) for intraday bucketing.
    static func localDayMinute(from timestamp: String) -> (day: String, minute: Int)? {
        guard let date = parse(timestamp) else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return (dayFormatter.string(from: date), minute)
    }

    private static func parse(_ timestamp: String) -> Date? {
        isoFractional.date(from: timestamp) ?? isoPlain.date(from: timestamp)
    }

    /// Keep today plus the `count` most recent prior days from a day→minute matrix.
    static func recentDays(_ matrix: [String: [Int]], now: Date, count: Int) -> [String: [Int]] {
        let today = dayKey(now)
        let keep = matrix.keys.filter { $0 <= today }.sorted().suffix(count + 1)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0, matrix[$0]!) })
    }
}
