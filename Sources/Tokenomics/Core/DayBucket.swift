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
        guard let date = isoFractional.date(from: timestamp) ?? isoPlain.date(from: timestamp)
        else { return nil }
        return dayFormatter.string(from: date)
    }
}
