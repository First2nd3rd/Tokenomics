import SwiftUI
import Charts

/// Chart building blocks shared between the popover dashboard and the report window.
/// Sizes are passed in (never GeometryReader, which confuses NSPopover content
/// sizing) so each surface renders its charts natively at its own width.
enum ChartKit {
    /// One token-type band: stack order (bottom→top), color, and how to read it from
    /// a `TokenCounts`. Drives the stacked rate area, the daily bars, and the legend.
    struct TokenBand: Identifiable {
        let name: String
        let color: Color
        let value: (TokenCounts) -> Int
        var id: String { name }
    }

    static let tokenBands: [TokenBand] = [
        TokenBand(name: "Cache read",  color: .blue,   value: { $0.cacheRead }),
        TokenBand(name: "Cache write", color: .teal,   value: { $0.cacheCreation }),
        TokenBand(name: "Input",       color: .green,  value: { $0.input }),
        TokenBand(name: "Output",      color: .orange, value: { $0.output }),
    ]

    /// Legend chips for the token-type bands.
    static func tokenLegend() -> some View {
        HStack(spacing: 12) {
            ForEach(tokenBands) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(band.color).frame(width: 8, height: 8)
                    Text(band.name)
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    /// A y-axis that labels ticks with compact token counts.
    static func tokenAxis() -> some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let t = value.as(Int.self) { Text(Format.tokensShort(t)) } }
        }
    }

    /// Pin a y-axis to start at 0 with a little headroom (floor 1), so a flat series
    /// sits at the bottom instead of being auto-centered.
    static func yUpper(_ peak: Int) -> Int { max(Int(Double(peak) * 1.08), 1) }

    /// Stacked daily bars (by token type) for an explicit set of days, at `width`.
    static func dailyBars(_ days: [DailyUsage], width: CGFloat, height: CGFloat = 130) -> some View {
        Chart {
            ForEach(days, id: \.date) { day in
                ForEach(tokenBands) { band in
                    BarMark(x: .value("Day", day.date),
                            y: .value("Tokens", band.value(day.counts)))
                        .foregroundStyle(by: .value("Type", band.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: tokenBands.map(\.name), range: tokenBands.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yUpper(days.map(\.totalTokens).max() ?? 0))
        .chartXAxis {
            AxisMarks(values: sparseLabels(days)) { value in
                AxisValueLabel { if let d = value.as(String.self) { Text(Format.shortMonthDay(d)) } }
            }
        }
        .chartYAxis { tokenAxis() }
        .frame(width: width, height: height)
    }

    /// Stacked hour-of-day bars (by token type) for one day's 24 buckets, at `width`.
    static func hourlyBars(_ hours: [TokenCounts], width: CGFloat, height: CGFloat = 130) -> some View {
        Chart {
            ForEach(Array(hours.enumerated()), id: \.offset) { hour, counts in
                ForEach(tokenBands) { band in
                    BarMark(x: .value("Hour", String(format: "%02d", hour)),
                            y: .value("Tokens", band.value(counts)))
                        .foregroundStyle(by: .value("Type", band.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: tokenBands.map(\.name), range: tokenBands.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yUpper(hours.map(\.total).max() ?? 0))
        .chartXAxis {
            AxisMarks(values: ["00", "06", "12", "18"]) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(String.self) { Text("\(h):00") } }
            }
        }
        .chartYAxis { tokenAxis() }
        .frame(width: width, height: height)
    }

    /// ~6 evenly spaced day keys to label so a month of bars doesn't crowd the axis.
    private static func sparseLabels(_ days: [DailyUsage]) -> [String] {
        guard !days.isEmpty else { return [] }
        let step = max(1, days.count / 6)
        return stride(from: 0, to: days.count, by: step).map { days[$0].date }
    }

    /// A horizontal proportion bar (share of a max) at `width`.
    static func proportionBar(fraction: Double, color: Color, width: CGFloat, height: CGFloat = 6) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: width, height: height)
            Capsule().fill(color)
                .frame(width: max(2, width * CGFloat(min(1, max(0, fraction)))), height: height)
        }
        .frame(width: width, height: height)
    }
}
