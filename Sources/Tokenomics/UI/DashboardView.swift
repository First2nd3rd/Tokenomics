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
    /// Which page of the second-chart deck is showing (0 = cumulative, 1 = daily bars).
    @AppStorage("secondChartPage") private var deckPage = 0
    private static let deckPageCount = 2

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

            sectionLabel(deckTitle)
            deckChart
                .contentShape(Rectangle())
                .onTapGesture { deckPage = (deckPage + 1) % Self.deckPageCount }
            deckFooter

            if !visiblePayback.isEmpty {
                sectionLabel("This month · subscription payback")
                ForEach(visiblePayback) { paybackRow($0) }
            }

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
        let value: (TokenCounts) -> Int
    }

    /// Stack order (bottom → top) + colors; drives the legend and both the intraday
    /// stacked area and the daily bars (keyed off TokenCounts so both can share it).
    private static let bands: [Band] = [
        Band(name: "Cache read",  color: .blue,   value: { $0.cacheRead }),
        Band(name: "Cache write", color: .teal,   value: { $0.cacheCreation }),
        Band(name: "Input",       color: .green,  value: { $0.input }),
        Band(name: "Output",      color: .orange, value: { $0.output }),
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
                AreaMark(x: .value("Time", point.hour), y: .value("Tokens", band.value(point.counts)))
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

    // MARK: - Second-chart deck (cumulative ⇄ daily bars)

    private var deckTitle: String {
        deckPage == 1 ? "Daily · tokens by type · last \(model.dailyBars.count)d"
                      : "Cumulative · today vs typical → projected"
    }

    @ViewBuilder private var deckChart: some View {
        if deckPage == 1 { dailyBarChart } else { cumulativeChart }
    }

    /// Page dots, plus the type legend while the bars are showing.
    private var deckFooter: some View {
        HStack(spacing: 8) {
            if deckPage == 1 { rateLegend }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                ForEach(0..<Self.deckPageCount, id: \.self) { page in
                    Circle()
                        .fill(page == deckPage ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                        .onTapGesture { deckPage = page }
                }
            }
        }
        .frame(width: 380)
    }

    // MARK: - Daily bar chart (stacked by token type)

    private var dailyBarChart: some View {
        Chart {
            ForEach(model.dailyBars, id: \.date) { day in
                ForEach(Self.bands, id: \.name) { band in
                    BarMark(
                        x: .value("Day", day.date),
                        y: .value("Tokens", band.value(day.counts))
                    )
                    .foregroundStyle(by: .value("Type", band.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: Self.bands.map(\.name), range: Self.bands.map(\.color))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: sparseBarLabels) { value in
                AxisValueLabel {
                    if let day = value.as(String.self) { Text(Format.shortMonthDay(day)) }
                }
            }
        }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 84)
    }

    /// ~4 evenly spaced day keys to label, so 14 bars don't crowd the axis.
    private var sparseBarLabels: [String] {
        let days = model.dailyBars
        guard !days.isEmpty else { return [] }
        let step = max(1, days.count / 4)
        return stride(from: 0, to: days.count, by: step).map { days[$0].date }
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

    // MARK: - Break-even (this month, per vendor)

    /// Show a vendor only when there's something to say: a subscription to break
    /// even against, or real API spend this month.
    private var visiblePayback: [VendorBreakEven] {
        model.breakEven.filter { $0.monthlyFee != nil || $0.monthToDateCost > 0 }
    }

    private func paybackRow(_ be: VendorBreakEven) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(be.vendor.displayName).font(.caption).fontWeight(.medium)
                Spacer()
                if let m = be.multiple {
                    Text(Format.multiple(m))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(m >= 1 ? Color.green : .primary)
                } else {
                    Text("API").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let progress = be.progress {
                paybackBar(progress: progress, brokeEven: (be.multiple ?? 0) >= 1, vendor: be.vendor)
            }
            Text(paybackDetail(be)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 380, alignment: .leading)
    }

    /// Fixed-width bar (no GeometryReader — that confuses NSPopover's content
    /// sizing and pushes the popover off-screen).
    private func paybackBar(progress: Double, brokeEven: Bool, vendor: Vendor) -> some View {
        let track: CGFloat = 380
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.15)).frame(width: track, height: 6)
            Capsule()
                .fill(brokeEven ? Color.green : vendorColor(vendor))
                .frame(width: max(2, track * CGFloat(progress)), height: 6)
        }
        .frame(width: track, height: 6)
    }

    private func paybackDetail(_ be: VendorBreakEven) -> String {
        let cost = Format.cost(be.monthToDateCost)
        guard let fee = be.monthlyFee else { return "\(cost) this month · API" }
        var line = "\(cost) / \(Format.cost(fee)) this month"
        if let day = be.brokeEvenOn { line += " · broke even \(Format.shortMonthDay(day))" }
        return line
    }

    /// Vendor color, taken from the same palette as the by-model rate chart so the
    /// two surfaces match (Claude orange, GPT teal).
    private func vendorColor(_ vendor: Vendor) -> Color {
        ModelColors.color(for: vendor == .claude ? "claude" : "gpt")
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
