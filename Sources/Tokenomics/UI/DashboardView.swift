import SwiftUI
import Charts

/// The popover contents: a headline figure, today's intraday token-rate chart, and
/// a cumulative chart with the typical-day reference and an end-of-day prediction.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var onRefresh: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    /// The rate chart's x-axis grows with the day (a little past "now"), min 3h, 24h cap.
    private var rateUpperBound: Double {
        min(24, max(3, model.nowHour + 0.3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            sectionLabel("Today · tokens / 5 min")
            rateChart

            sectionLabel("Cumulative · today vs typical → projected")
            cumulativeChart

            HStack(spacing: 12) {
                Button("Refresh", action: onRefresh)
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button("Quit", action: onQuit)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 404)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: - Rate chart (intraday, area)

    private var rateChart: some View {
        Chart(model.rate5min) { point in
            AreaMark(x: .value("Hour", point.hour), y: .value("Tokens", point.tokens))
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .chartXScale(domain: 0...rateUpperBound)
        .chartXAxis { hourAxis }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 92)
    }

    // MARK: - Cumulative chart (today / typical / predicted)

    private var cumulativeChart: some View {
        Chart {
            ForEach(model.cumTypical) { p in
                LineMark(x: .value("Hour", p.hour), y: .value("Tokens", p.tokens),
                         series: .value("Series", "Typical"))
                    .foregroundStyle(Color.gray.opacity(0.45))
                    .interpolationMethod(.monotone)
            }
            ForEach(model.cumPredicted) { p in
                LineMark(x: .value("Hour", p.hour), y: .value("Tokens", p.tokens),
                         series: .value("Series", "Projected"))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .interpolationMethod(.monotone)
            }
            ForEach(model.cumToday) { p in
                LineMark(x: .value("Hour", p.hour), y: .value("Tokens", p.tokens),
                         series: .value("Series", "Today"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))") } }
            }
        }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 92)
    }

    // MARK: - Shared axes

    private var hourAxis: some AxisContent {
        AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21, 24]) { value in
            AxisGridLine()
            AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))") } }
        }
    }

    private var tokenAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let t = value.as(Int.self) { Text(Format.tokensShort(t)) } }
        }
    }
}
