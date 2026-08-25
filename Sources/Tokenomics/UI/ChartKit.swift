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

    /// Stacked fixed-slot bars across several days (the week chart's high-density
    /// alternate), with an axis label at each day's first slot.
    static func slotBars(_ buckets: [PeriodReport.SlotBucket], width: CGFloat,
                         height: CGFloat = 130) -> some View {
        Chart {
            ForEach(buckets, id: \.axisKey) { bucket in
                ForEach(tokenBands) { band in
                    BarMark(x: .value("Slot", bucket.axisKey),
                            y: .value("Tokens", band.value(bucket.counts)))
                        .foregroundStyle(by: .value("Type", band.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: tokenBands.map(\.name), range: tokenBands.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yUpper(buckets.map(\.counts.total).max() ?? 0))
        .chartXAxis {
            AxisMarks(values: buckets.filter { $0.slot == 0 }.map(\.axisKey)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let key = value.as(String.self), let day = key.split(separator: "#").first {
                        Text(Format.shortMonthDay(String(day)))
                    }
                }
            }
        }
        .chartYAxis { tokenAxis() }
        .frame(width: width, height: height)
    }

    /// Stacked monthly bars (by token type) for the all-time trend, at `width`.
    static func monthlyBars(_ months: [MonthUsage], width: CGFloat, height: CGFloat = 130) -> some View {
        Chart {
            ForEach(months) { month in
                ForEach(tokenBands) { band in
                    BarMark(x: .value("Month", month.month),
                            y: .value("Tokens", band.value(month.counts)))
                        .foregroundStyle(by: .value("Type", band.name))
                }
            }
        }
        .chartForegroundStyleScale(domain: tokenBands.map(\.name), range: tokenBands.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yUpper(months.map(\.tokens).max() ?? 0))
        .chartXAxis { monthAxis(months) }
        .chartYAxis { tokenAxis() }
        .frame(width: width, height: height)
    }

    /// The monthly by-model chart's prepared series: the top models across the span
    /// (in ModelColors order, which is the stack + legend order), everything else
    /// folded into an "Other" tail slice.
    struct ModelSeries {
        struct Slice: Identifiable {
            let month: String
            let model: String       // full id ("Other" for the tail)
            let tokens: Int
            var id: String { "\(month)|\(model)" }
        }
        let domain: [String]        // model ids, stack order (Other last)
        let colors: [Color]
        let labels: [String]        // legend display names
        let slices: [Slice]
    }

    static func modelSeries(_ months: [MonthUsage], top: Int = 5) -> ModelSeries {
        var totals: [String: Int] = [:]
        for month in months {
            for m in month.byModel { totals[m.model, default: 0] += m.tokens }
        }
        let topModels = Set(totals.sorted { $0.value > $1.value }.prefix(top).map(\.key))
        let entries = ModelColors.assign(Array(topModels))

        var slices: [ModelSeries.Slice] = []
        var hasOther = false
        for month in months {
            var other = 0
            var byModel: [String: Int] = [:]
            for m in month.byModel {
                if topModels.contains(m.model) { byModel[m.model, default: 0] += m.tokens }
                else { other += m.tokens }
            }
            for entry in entries where byModel[entry.model] != nil {
                slices.append(.init(month: month.month, model: entry.model, tokens: byModel[entry.model]!))
            }
            if other > 0 { slices.append(.init(month: month.month, model: "Other", tokens: other)); hasOther = true }
        }

        var domain = entries.map(\.model)
        var colors = entries.map(\.color)
        var labels = entries.map { ModelColors.shortName($0.model) }
        if hasOther { domain.append("Other"); colors.append(.gray.opacity(0.55)); labels.append("Other") }
        return ModelSeries(domain: domain, colors: colors, labels: labels, slices: slices)
    }

    /// Stacked monthly bars by MODEL (ModelColors palette: same vendor = same hue,
    /// shade = price rank) — the all-time trend's model-mix page.
    static func monthlyModelBars(_ months: [MonthUsage], series: ModelSeries,
                                 width: CGFloat, height: CGFloat = 130) -> some View {
        Chart {
            ForEach(series.slices) { slice in
                BarMark(x: .value("Month", slice.month),
                        y: .value("Tokens", slice.tokens))
                    .foregroundStyle(by: .value("Model", slice.model))
            }
        }
        .chartForegroundStyleScale(domain: series.domain, range: series.colors)
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yUpper(months.map(\.tokens).max() ?? 0))
        .chartXAxis { monthAxis(months) }
        .chartYAxis { tokenAxis() }
        .frame(width: width, height: height)
    }

    /// Legend chips for the by-model series, mirroring `tokenLegend`.
    static func modelLegend(_ series: ModelSeries) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(series.domain.enumerated()), id: \.offset) { i, _ in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(series.colors[i]).frame(width: 8, height: 8)
                    Text(series.labels[i])
                }
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    /// Monthly cost bars — the one place cost is charted rather than printed.
    /// Historical months carry frozen (then-current) prices, today's month is live.
    static func costBars(_ months: [MonthUsage], width: CGFloat, height: CGFloat = 130) -> some View {
        Chart {
            ForEach(months) { month in
                BarMark(x: .value("Month", month.month),
                        y: .value("Cost", month.cost))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .chartYScale(domain: 0...max((months.map(\.cost).max() ?? 0) * 1.08, 1))
        .chartXAxis { monthAxis(months) }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let c = value.as(Double.self) { Text(c == 0 ? "$0" : Format.costCompact(c)) }
                }
            }
        }
        .frame(width: width, height: height)
    }

    /// Month-key ("2026-06") x-axis: short month names while a year fits, sparse
    /// year-qualified labels ("Jun ’27") once the span would repeat bare names.
    private static func monthAxis(_ months: [MonthUsage]) -> some AxisContent {
        let withYear = months.count > 12
        return AxisMarks(values: monthLabelKeys(months)) { value in
            AxisValueLabel {
                if let m = value.as(String.self) {
                    Text(withYear ? Format.shortMonthYear(m) : Format.shortMonth(m))
                }
            }
        }
    }

    /// Every month while they fit; sparse (~6) once the span grows past a year.
    private static func monthLabelKeys(_ months: [MonthUsage]) -> [String] {
        guard months.count > 12 else { return months.map(\.month) }
        let step = max(1, months.count / 6)
        return stride(from: 0, to: months.count, by: step).map { months[$0].month }
    }

    /// ~6 evenly spaced day keys to label so a month of bars doesn't crowd the axis.
    private static func sparseLabels(_ days: [DailyUsage]) -> [String] {
        guard !days.isEmpty else { return [] }
        let step = max(1, days.count / 6)
        return stride(from: 0, to: days.count, by: step).map { days[$0].date }
    }

    /// Page dots (click a dot to jump), shared by the popover chart decks and the
    /// report's chart toggles so paged charts read the same everywhere.
    static func pageDots(current: Int, count: Int, select: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { page in
                Circle()
                    .fill(page == current ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
                    .onTapGesture { select(page) }
            }
        }
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
