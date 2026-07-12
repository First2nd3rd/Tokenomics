import SwiftUI
import Charts

/// The popover contents: a headline figure, today's intraday token-rate chart, and
/// a cumulative chart with the typical-day reference and an end-of-day prediction.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var onRefresh: () -> Void
    var onSettings: () -> Void
    var onReport: () -> Void
    var onQuit: () -> Void

    @AppStorage("rateChartStyle") private var rateStyle: RateChartStyle = .line
    /// Which page of the rate-chart deck is showing (0 = live last hour, 1 = full day).
    @AppStorage("rateChartPage") private var ratePage = 0
    private static let ratePageCount = 2
    /// Which page of the second-chart deck is showing (0 = cumulative, 1 = daily bars).
    @AppStorage("secondChartPage") private var deckPage = 0
    private static let deckPageCount = 2

    /// End the x-axis at "now" (the last bucket's position), so there's no empty
    /// tail and the right edge advances each refresh.
    private var rateUpperBound: Double {
        guard let now = model.rate5min.last?.x else { return 1 }
        return min(24, max(0.5, now + 0.04))
    }

    /// Pin a chart's y-axis to start at 0 (so a flat all-zero series sits at the bottom
    /// instead of being auto-centered), with a floor of 1 and a little headroom.
    private func yUpper(_ peak: Int) -> Int { max(Int(Double(peak) * 1.08), 1) }

    private func rateYUpper(_ points: [RatePoint], _ peer: [LivePoint]) -> Int {
        yUpper(max(points.map(\.total).max() ?? 0, peer.map(\.total).max() ?? 0))
    }

    /// Peak across the cumulative today / typical / projected lines.
    private var cumYUpper: Int {
        yUpper(([model.cumToday, model.cumTypical, model.cumPredicted].flatMap { $0 }).map(\.tokens).max() ?? 0)
    }

    /// Peak daily stack height (the four bands sum to the day's total).
    private var dailyYUpper: Int {
        yUpper(model.dailyBars.map(\.totalTokens).max() ?? 0)
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
                .contentShape(Rectangle())
                .onTapGesture { ratePage = (ratePage + 1) % Self.ratePageCount }
            rateFooter

            sectionLabel(deckTitle)
            deckChart
                .contentShape(Rectangle())
                .onTapGesture { deckPage = (deckPage + 1) % Self.deckPageCount }
            deckFooter

            if !visiblePayback.isEmpty {
                sectionLabel("This month · subscription payback")
                ForEach(visiblePayback) { paybackRow($0) }
            }

            if model.machines.count >= 2 {
                sectionLabel("Across \(model.machines.count) Macs · today")
                ForEach(model.machines) { machineRow($0) }
            }

            HStack(spacing: 12) {
                Button("Refresh", action: onRefresh)
                Spacer()
                Button(action: onReport) {
                    Image(systemName: "calendar")
                }
                .help("Reports")
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
        Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }

    // MARK: - Rate chart (intraday, smooth stack by token type)

    private var rateTitle: String {
        if ratePage == 0 { return "Live · last hour · tokens / min" }
        return model.models.isEmpty ? "Today · tokens / 5 min"
                                    : "Today · " + model.models.joined(separator: ", ")
    }

    /// X-scale + labeled marks for one page of the rate deck.
    private struct RateAxis {
        let domain: ClosedRange<Double>
        let marks: [Double]
        let label: (Double) -> String
    }

    private var dayAxis: RateAxis {
        RateAxis(domain: 0...rateUpperBound,
                 marks: [0, 3, 6, 9, 12, 15, 18, 21, 24],
                 label: { "\(Int($0))" })
    }

    /// Minutes-ago axis: the series spans −(n−1)…0, so the newest bucket hugs the
    /// right edge and the whole chart drifts left as time passes.
    private var liveAxis: RateAxis {
        RateAxis(domain: -Double(max(model.rateLive.count, 2) - 1)...0,
                 marks: [-60, -45, -30, -15, 0],
                 label: { $0 == 0 ? "now" : "\(Int($0))m" })
    }

    @ViewBuilder private var rateChart: some View {
        let points = ratePage == 0 ? model.rateLive : model.rate5min
        let peer = ratePage == 0 ? model.rateLivePeer : []
        let axis = ratePage == 0 ? liveAxis : dayAxis
        switch rateStyle {
        case .line:    lineRateChart(points, peer, axis)
        case .stacked: stackedRateChart(points, peer, axis)
        case .model:   modelRateChart(points, peer, axis)
        }
    }

    /// The other Macs' last-hour activity as one light line on top of the local
    /// series — never added to it. Empty on the full-day page and when sync is off.
    @ChartContentBuilder private func peerOverlay(_ peer: [LivePoint]) -> some ChartContent {
        ForEach(peer) { p in
            LineMark(x: .value("Time", p.x), y: .value("Tokens", p.total),
                     series: .value("Series", "Other Macs"))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
    }

    /// Style legend (when the style has one) + the rate deck's page dots. A hidden
    /// legend keeps the row's height when there is nothing to show, so switching
    /// styles or pages never reflows the popover.
    private var rateFooter: some View {
        HStack(spacing: 8) {
            if rateStyle == .stacked { rateLegend }
            else if rateStyle == .model { modelLegend }
            else { rateLegend.hidden() }
            Spacer(minLength: 0)
            pageDots(current: ratePage, count: Self.ratePageCount) { ratePage = $0 }
        }
        .frame(width: 380)
    }

    private func rateXAxis(_ axis: RateAxis) -> some AxisContent {
        AxisMarks(values: axis.marks) { value in
            AxisGridLine()
            AxisValueLabel { if let v = value.as(Double.self) { Text(axis.label(v)) } }
        }
    }

    /// Default: a single accent line over a faint area fill (the total per bucket).
    private func lineRateChart(_ points: [RatePoint], _ peer: [LivePoint], _ axis: RateAxis) -> some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.x), y: .value("Tokens", point.total))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                LineMark(x: .value("Time", point.x), y: .value("Tokens", point.total))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            peerOverlay(peer)
        }
        .chartXScale(domain: axis.domain)
        .chartYScale(domain: 0...rateYUpper(points, peer))
        .chartXAxis { rateXAxis(axis) }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 84)
    }

    /// Optional: a smooth area stacked by token type (cache-read usually dominates).
    private func stackedRateChart(_ points: [RatePoint], _ peer: [LivePoint], _ axis: RateAxis) -> some View {
        Chart {
            ForEach(points) { point in
                ForEach(ChartKit.tokenBands, id: \.name) { band in
                    AreaMark(x: .value("Time", point.x), y: .value("Tokens", band.value(point.counts)))
                        .foregroundStyle(by: .value("Type", band.name))
                        .interpolationMethod(.monotone)
                }
            }
            peerOverlay(peer)
        }
        .chartForegroundStyleScale(domain: ChartKit.tokenBands.map(\.name), range: ChartKit.tokenBands.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: axis.domain)
        .chartYScale(domain: 0...rateYUpper(points, peer))
        .chartXAxis { rateXAxis(axis) }
        .chartYAxis { tokenAxis }
        .frame(width: 380, height: 84)
    }

    private var rateLegend: some View {
        HStack(spacing: 12) {
            ForEach(ChartKit.tokenBands, id: \.name) { band in
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

    private func modelRateChart(_ points: [RatePoint], _ peer: [LivePoint], _ axis: RateAxis) -> some View {
        let order = modelColorOrder
        return Chart {
            ForEach(points) { point in
                ForEach(order) { entry in
                    AreaMark(x: .value("Time", point.x),
                             y: .value("Tokens", point.byModel[entry.model] ?? 0))
                        .foregroundStyle(by: .value("Model", entry.model))
                        .interpolationMethod(.monotone)
                }
            }
            peerOverlay(peer)
        }
        .chartForegroundStyleScale(domain: order.map(\.model), range: order.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: axis.domain)
        .chartYScale(domain: 0...rateYUpper(points, peer))
        .chartXAxis { rateXAxis(axis) }
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

    /// Page dots, plus the type legend while the bars are showing. On the cumulative
    /// page the legend stays as hidden placeholder, so flipping pages never changes
    /// the deck's height (an NSPopover reflow reads as the whole panel jumping).
    private var deckFooter: some View {
        HStack(spacing: 8) {
            if deckPage == 1 { rateLegend } else { rateLegend.hidden() }
            Spacer(minLength: 0)
            pageDots(current: deckPage, count: Self.deckPageCount) { deckPage = $0 }
        }
        .frame(width: 380)
    }

    /// Click a dot to jump to that page (shared by both chart decks).
    private func pageDots(current: Int, count: Int, select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { page in
                Circle()
                    .fill(page == current ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .onTapGesture { select(page) }
            }
        }
    }

    // MARK: - Daily bar chart (stacked by token type)

    private var dailyBarChart: some View {
        Chart {
            ForEach(model.dailyBars, id: \.date) { day in
                ForEach(ChartKit.tokenBands, id: \.name) { band in
                    BarMark(
                        x: .value("Day", day.date),
                        y: .value("Tokens", band.value(day.counts))
                    )
                    .foregroundStyle(by: .value("Type", band.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: ChartKit.tokenBands.map(\.name), range: ChartKit.tokenBands.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...dailyYUpper)
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
        .chartYScale(domain: 0...cumYUpper)
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

    // MARK: - By-machine breakdown (cross-machine sync)

    /// One machine's row: name + today's tokens + a share bar; peers also show
    /// "synced N ago". This Mac is highlighted; peers get a stable hue.
    private func machineRow(_ m: MachineSummary) -> some View {
        let maxTokens = model.machines.map(\.todayTokens).max() ?? 0
        let track: CGFloat = 380
        let frac = maxTokens > 0 ? CGFloat(m.todayTokens) / CGFloat(maxTokens) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(m.name).font(.caption).fontWeight(m.isLocal ? .semibold : .regular)
                if m.isLocal { Text("this Mac").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text(Format.tokensShort(m.todayTokens)).font(.caption).foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15)).frame(width: track, height: 6)
                Capsule().fill(machineColor(m)).frame(width: max(2, track * frac), height: 6)
            }
            if !m.isLocal {
                Text(lastSeenText(m.lastSeen)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 380, alignment: .leading)
    }

    /// This Mac uses the accent; each peer gets a stable hue from its id.
    private func machineColor(_ m: MachineSummary) -> Color {
        if m.isLocal { return .accentColor }
        let seed = m.id.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hue: Double(seed % 360) / 360.0, saturation: 0.5, brightness: 0.72)
    }

    private func lastSeenText(_ epoch: Int) -> String {
        let secs = Int(Date().timeIntervalSince1970) - epoch
        if secs < 90 { return "synced just now" }
        if secs < 3_600 { return "synced \(secs / 60)m ago" }
        if secs < 86_400 { return "synced \(secs / 3_600)h ago" }
        return "synced \(secs / 86_400)d ago"
    }

    // MARK: - Shared axes

    private var tokenAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let t = value.as(Int.self) { Text(Format.tokensShort(t)) } }
        }
    }
}
