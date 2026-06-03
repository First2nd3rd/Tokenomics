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

    /// Grouped full count for the dropdown: 72,889,694.
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func cost(_ c: Double) -> String {
        String(format: "$%.2f", c)
    }

    /// Day-over-day delta as "▲ 18%" / "▼ 5%". Nil when there's no baseline.
    static func deltaPct(_ current: Int, vs base: Int) -> String? {
        guard base > 0 else { return nil }
        let pct = (Double(current) - Double(base)) / Double(base) * 100
        let arrow = pct >= 0 ? "▲" : "▼"
        return String(format: "%@ %.0f%%", arrow, abs(pct))
    }
}
