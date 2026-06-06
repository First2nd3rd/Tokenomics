import SwiftUI
import Charts

/// The popover contents: a headline figure plus today's intraday token-rate chart
/// (5-minute buckets across the local day).
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var onRefresh: () -> Void
    var onQuit: () -> Void

    /// X-axis grows with the day (a little past "now"), with a minimum morning
    /// window and a 24h cap.
    private var chartUpperBound: Double {
        min(24, max(3, model.nowHour + 0.3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Today · tokens / 5 min")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Chart(model.rate5min) { point in
                AreaMark(
                    x: .value("Hour", point.hour),
                    y: .value("Tokens", point.tokens)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            .chartXScale(domain: 0...chartUpperBound)
            .chartXAxis {
                AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21, 24]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let h = value.as(Double.self) { Text("\(Int(h))") }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let t = value.as(Int.self) { Text(Format.tokensShort(t)) }
                    }
                }
            }
            .frame(width: 380, height: 170)

            HStack {
                Button("Refresh", action: onRefresh)
                Spacer()
                Button("Quit", action: onQuit)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 412)
    }
}
