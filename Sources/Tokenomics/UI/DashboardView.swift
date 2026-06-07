import SwiftUI
import Charts

/// The popover contents: a headline figure, today's intraday token-rate chart, and
/// a cumulative chart with the typical-day reference and an end-of-day prediction.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var onRefresh: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    @AppStorage("rateChartStyle") private var rateStyle: RateChartStyle = .line

    /// End the x-axis at "now" (the last bucket's position), so there's no empty
    /// tail and the right edge advances each refresh.
    private var rateUpperBound: Double {
        guard let now = model.rate5min.last?.hour else { return 1 }
        return min(24, max(0.5, now + 0.04))
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

            sectionLabel(rateTitle)
            rateChart
            if rateStyle == .stacked { rateLegend }
            else if rateStyle == .model { modelLegend }

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

    // MARK: - Rate chart (intraday, smooth stack by token type)

    private struct Band {
        let name: String
        let color: Color
        let value: (RatePoint) -> Int
    }

    /// Stack order (bottom → top) + colors; also drives the legend.
    private static let bands: [Band] = [
        Band(name: "Cache read",  color: .blue,   value: { $0.counts.cacheRead }),
        Band(name: "Cache write", color: .teal,   value: { $0.counts.cacheCreation }),
        Band(name: "Input",       color: .green,  value: { $0.counts.input }),
        Band(name: "Output",      color: .orange, value: { $0.counts.output }),
    ]

    private var rateTitle: String {
        model.models.isEmpty ? "Today · tokens / 5 min"
                             : "Today · " + model.models.joined(separator: ", ")
    }

    @ViewBuilder private var rateChart: some View {
        switch rateStyle {
        case .line:    lineRateChart
        case .stacked: stackedRateChart
        case .model:   modelRateChart
        }
    }

    /// Default: a single accent line over a faint area fill (the total per bucket).
    private var lineRateChart: some View {
        Chart(model.rate5min) { point in
            AreaMark(x: .value("Time", point.hour), y: .value("Tokens", point.total))
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    .linearGradient(
                        colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.10)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            LineMark(x: .value("Time", point.hour), y: .value("Tokens", point.total))
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: 0...rateUpperBound)
        .chartXAxis { hourAxis }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 84)
    }

    /// Optional: a smooth area stacked by token type (cache-read usually dominates).
    private var stackedRateChart: some View {
        Chart(model.rate5min) { point in
            ForEach(Self.bands, id: \.name) { band in
                AreaMark(x: .value("Time", point.hour), y: .value("Tokens", band.value(point)))
                    .foregroundStyle(by: .value("Type", band.name))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(domain: Self.bands.map(\.name), range: Self.bands.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: 0...rateUpperBound)
        .chartXAxis { hourAxis }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 84)
    }

    private var rateLegend: some View {
        HStack(spacing: 12) {
            ForEach(Self.bands, id: \.name) { band in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(band.color).frame(width: 8, height: 8)
                    Text(band.name)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Rate chart (by model)

    private var modelColorOrder: [ModelColors.Entry] { ModelColors.assign(model.models) }

    private var modelRateChart: some View {
        let order = modelColorOrder
        return Chart(model.rate5min) { point in
            ForEach(order) { entry in
                AreaMark(x: .value("Time", point.hour),
                         y: .value("Tokens", point.byModel[entry.model] ?? 0))
                    .foregroundStyle(by: .value("Model", entry.model))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(domain: order.map(\.model), range: order.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: 0...rateUpperBound)
        .chartXAxis { hourAxis }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 84)
    }

    private var modelLegend: some View {
        HStack(spacing: 12) {
            ForEach(modelColorOrder) { entry in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(entry.color).frame(width: 8, height: 8)
                    Text(ModelColors.shortName(entry.model))
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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
        .frame(width: 380, height: 84)
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
