import Foundation

/// Time bucketing shared by every provider. Records are stored against their
/// absolute UTC instant; the local calendar day / minute is computed at READ time
/// under the current timezone, so a timezone change re-buckets correctly instead
/// of leaving stale, baked-in day labels in the cache.
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

    /// Parse a UTC ISO-8601 timestamp to its absolute instant (timezone-independent).
    static func date(from timestamp: String) -> Date? {
        isoFractional.date(from: timestamp) ?? isoPlain.date(from: timestamp)
    }

    /// Local calendar-day key like "2026-06-03" for a `Date`, matching ccusage's `period`.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Local day key for a UTC epoch (seconds), under `calendar`'s timezone.
    static func day(epoch: Int, calendar: Calendar = .current) -> String {
        dayKey(Date(timeIntervalSince1970: TimeInterval(epoch)), calendar: calendar)
    }

    /// Local calendar-month key like "2026-06" for a `Date`.
    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Local month key for a UTC epoch (seconds), under `calendar`'s timezone.
    static func month(epoch: Int, calendar: Calendar = .current) -> String {
        monthKey(Date(timeIntervalSince1970: TimeInterval(epoch)), calendar: calendar)
    }

    /// Month keys ("YYYY-MM") from `from`'s month through `to`'s month, inclusive —
    /// the archive segments a date range touches.
    static func monthsSpanning(from: Date, to: Date, calendar: Calendar = .current) -> [String] {
        guard from <= to else { return [] }
        var months: [String] = []
        var cursor = calendar.dateInterval(of: .month, for: from)?.start ?? from
        let last = calendar.dateInterval(of: .month, for: to)?.start ?? to
        while cursor <= last {
            months.append(monthKey(cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    /// Local day key + minute-of-day (0…1439) for a UTC epoch, under `calendar`.
    /// Computed fresh each call so it tracks the current timezone.
    static func dayMinute(epoch: Int, calendar: Calendar = .current) -> (day: String, minute: Int) {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return (day, (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    /// Keep today plus the `count` most recent prior days from a day-keyed matrix.
    static func recentDays<T>(_ matrix: [String: [T]], now: Date, count: Int) -> [String: [T]] {
        let today = dayKey(now)
        let keep = matrix.keys.filter { $0 <= today }.sorted().suffix(count + 1)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0, matrix[$0]!) })
    }
}
