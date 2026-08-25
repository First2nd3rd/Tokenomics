import Foundation

/// Display formatting helpers, kept separate so every surface formats alike.
enum Format {
    /// Compact token count for the menu bar: 312k, 72.9M, 1.2B.
    static func tokensShort(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...:
            return String(format: "%.1fB", d / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", d / 1_000_000)
        case 1_000...:
            return String(format: "%.0fk", d / 1_000)
        default:
            return "\(n)"
        }
    }

    static func cost(_ c: Double) -> String {
        String(format: "$%.2f", c)
    }

    /// Narrow cost for the two-line menu bar: cents only matter while they are
    /// the story ($3.28 → $32.6 → $326), and a bare ".0" tail is dropped.
    static func costCompact(_ c: Double) -> String {
        let s: String
        switch c {
        case 100...: s = String(format: "$%.0f", c)
        case 10...:  s = String(format: "$%.1f", c)
        default:     s = String(format: "$%.2f", c)
        }
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// Whole-dollar cost with thousands grouping ("$32,666") for lifetime-scale
    /// figures, where the compact forms drop legibility.
    static func costGrouped(_ c: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = c >= 100 ? 0 : 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return "$" + (formatter.string(from: NSNumber(value: c)) ?? String(format: "%.0f", c))
    }

    /// Payback multiple like "2.3×" (one decimal under 10×, whole number beyond).
    static func multiple(_ x: Double) -> String {
        x >= 10 ? String(format: "%.0f×", x) : String(format: "%.1f×", x)
    }

    private static let isoDayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    /// "2026-06-04" → "Jun 4". Returns the input unchanged if it can't be parsed.
    static func shortMonthDay(_ isoDay: String) -> String {
        guard let date = isoDayParser.date(from: isoDay) else { return isoDay }
        return monthDayFormatter.string(from: date)
    }

    private static let monthParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f
    }()

    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// "2026-06" → "Jun". Returns the input unchanged if it can't be parsed.
    static func shortMonth(_ monthKey: String) -> String {
        guard let date = monthParser.date(from: monthKey) else { return monthKey }
        return monthFormatter.string(from: date)
    }

    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM ’yy"
        return f
    }()

    /// "2026-06" → "Jun ’26", for month axes spanning more than a year, where a
    /// bare month name repeats ambiguously.
    static func shortMonthYear(_ monthKey: String) -> String {
        guard let date = monthParser.date(from: monthKey) else { return monthKey }
        return monthYearFormatter.string(from: date)
    }

    /// "2026-05-20" → "May 20, 2026". Returns the input unchanged if it can't be parsed.
    static func monthDayYear(_ isoDay: String) -> String {
        guard let date = isoDayParser.date(from: isoDay) else { return isoDay }
        return monthDayYearFormatter.string(from: date)
    }

    /// Day-over-day delta as "▲ 18%" / "▼ 5%". Nil when there's no baseline.
    static func deltaPct(_ current: Int, vs base: Int) -> String? {
        guard base > 0 else { return nil }
        let pct = (Double(current) - Double(base)) / Double(base) * 100
        let arrow = pct >= 0 ? "▲" : "▼"
        return String(format: "%@ %.0f%%", arrow, abs(pct))
    }
}
