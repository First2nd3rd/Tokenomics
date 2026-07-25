import Foundation

/// The two stacked menu-bar lines. Top is always today's total tokens; the
/// bottom slot is LIVE: while usage is flowing it shows how much the last
/// refresh added ("+1.2M"), and when nothing new arrived it falls back to
/// today's cost ("$326"). Pure — the delta is computed by the caller from two
/// consecutive refresh totals (nil on launch, day rollover, or recounts).
enum StatusLine {
    struct Lines: Equatable {
        let top: String
        let bottom: String
    }

    static func make(totalTokens: Int?, cost: Double?, delta: Int?) -> Lines {
        guard let totalTokens, let cost else { return Lines(top: "—", bottom: "") }
        let bottom: String
        if let delta, delta > 0 {
            bottom = "+" + Format.tokensShort(delta)
        } else {
            bottom = Format.costCompact(cost)
        }
        return Lines(top: Format.tokensShort(totalTokens), bottom: bottom)
    }
}
