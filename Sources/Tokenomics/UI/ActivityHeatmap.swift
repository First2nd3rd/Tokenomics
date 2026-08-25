import SwiftUI

/// GitHub-contribution-style activity heatmap: one 7×53 grid of day cells painted
/// from an `ActivityGrid`. Fixed metrics sized to the settings window's detail
/// column (like every chart, no GeometryReader).
struct ActivityHeatmap: View {
    let grid: ActivityGrid

    private static let cell: CGFloat = 7
    private static let gap: CGFloat = 2
    private static let pitch = cell + gap
    private static let weekdayLabelWidth: CGFloat = 12
    /// Columns close to the right edge would push their month label out of frame
    /// (a 9pt "May" ending inside the grid still fits at weekCount − 3).
    private static let lastLabeledColumn = ActivityGrid.weekCount - 3

    /// The intensity ramp: an "empty" wash plus four accent steps, legible on both
    /// light and dark backgrounds.
    static func color(level: Int) -> Color {
        switch level {
        case 1: return .accentColor.opacity(0.25)
        case 2: return .accentColor.opacity(0.45)
        case 3: return .accentColor.opacity(0.70)
        case 4: return .accentColor
        default: return .secondary.opacity(0.14)
        }
    }

    /// One day cell — a flat wash, no outline (a tried hairline border on empty
    /// cells read too heavy in both appearances; user-rejected).
    static func square(level: Int) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(color(level: level))
            .frame(width: cell, height: cell)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            monthLabels
            HStack(alignment: .top, spacing: Self.gap) {
                weekdayLabels
                ForEach(Array(grid.columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: Self.gap) {
                        ForEach(Array(column.enumerated()), id: \.offset) { _, cell in
                            if let cell {
                                Self.square(level: cell.level)
                                    .help(cell.tokens > 0
                                          ? "\(Format.shortMonthDay(cell.day)) · \(Format.tokensShort(cell.tokens)) tokens"
                                          : "\(Format.shortMonthDay(cell.day)) · no usage")
                            } else {
                                Color.clear.frame(width: Self.cell, height: Self.cell)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Month names floated over the column where each month's 1st lands.
    private var monthLabels: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 10)
            ForEach(grid.monthLabels.keys.sorted().filter { $0 <= Self.lastLabeledColumn },
                    id: \.self) { column in
                Text(grid.monthLabels[column] ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: Self.weekdayLabelWidth + Self.gap + CGFloat(column) * Self.pitch)
            }
        }
    }

    private var weekdayLabels: some View {
        VStack(spacing: Self.gap) {
            ForEach(Array(grid.rowLabels.enumerated()), id: \.offset) { _, label in
                Text(label ?? "")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.weekdayLabelWidth, height: Self.cell, alignment: .leading)
            }
        }
    }

    /// The "Less ▢▢▢▢▢ More" ramp key, placed by the caller alongside its captions.
    static func legend() -> some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach(0..<5, id: \.self) { level in square(level: level) }
            Text("More")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}
