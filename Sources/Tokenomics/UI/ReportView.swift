import SwiftUI

/// The report window: a day / week / month usage breakdown read from the durable
/// archive. This Mac only (see the note when sync is on). Presentation only — every
/// figure comes from `PeriodReport`.
struct ReportView: View {
    @ObservedObject var model: ReportModel

    private let width: CGFloat = 520
    private var chartWidth: CGFloat { width - 40 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let report = model.report, report.total.total > 0 {
                    content(report)
                } else {
                    Text("No usage recorded in this period.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
            }
            .padding(20)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, height: 660)
        .onAppear { if model.report == nil { model.reload() } }
    }

    // MARK: - Header (granularity picker + period navigator)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Usage Report").font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("", selection: $model.period) {
                    ForEach(ReportPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack(spacing: 14) {
                Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(model.period.range(containing: model.anchor).title)
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 190, alignment: .leading)
                Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(!model.canStepForward)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder private func content(_ r: PeriodReport) -> some View {
        headline(r)
        notes(r)
        section("Daily") { ChartKit.dailyBars(r.days, width: chartWidth); ChartKit.tokenLegend() }
        if !r.byVendor.isEmpty { section("By vendor") { vendorRows(r) } }
        if !r.byModel.isEmpty { section("By model") { modelRows(r) } }
        section("Stats") { statsGrid(r) }
    }

    private func headline(_ r: PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.tokensShort(r.total.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(Format.cost(r.cost)).font(.system(size: 18)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let delta = Format.deltaPct(r.total.total, vs: r.previousTokens) {
                    Text("\(delta) vs previous \(r.period.label.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let projected = r.projectedTokens {
                    Text("→ ~\(Format.tokensShort(projected)) projected")
                        .font(.caption).foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func notes(_ r: PeriodReport) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.syncOn {
                Text("This Mac only — excludes the other Macs shown on the dashboard.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !r.isCurrent {
                Text("Costs estimated at current prices.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - By vendor / by model

    private func vendorRows(_ r: PeriodReport) -> some View {
        let maxTokens = r.byVendor.map(\.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(r.byVendor) { v in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(v.vendor).font(.caption).fontWeight(.medium)
                        Spacer()
                        Text(Format.tokensShort(v.tokens)).font(.caption).foregroundStyle(.secondary)
                        Text(Format.cost(v.cost)).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    ChartKit.proportionBar(
                        fraction: maxTokens > 0 ? Double(v.tokens) / Double(maxTokens) : 0,
                        color: vendorColor(v.vendor), width: chartWidth)
                }
            }
        }
    }

    private func modelRows(_ r: PeriodReport) -> some View {
        let top = Array(r.byModel.prefix(8))
        let rest = r.byModel.dropFirst(8)
        let restTokens = rest.reduce(0) { $0 + $1.tokens }
        let restCost = rest.reduce(0.0) { $0 + $1.cost }
        let maxTokens = r.byModel.map(\.tokens).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(top) { m in modelRow(ModelColors.shortName(m.model), m.tokens, m.cost, max: maxTokens) }
            if restTokens > 0 { modelRow("Other", restTokens, restCost, max: maxTokens) }
        }
    }

    private func modelRow(_ name: String, _ tokens: Int, _ cost: Double, max maxTokens: Int) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).frame(width: 120, alignment: .leading)
            ChartKit.proportionBar(fraction: maxTokens > 0 ? Double(tokens) / Double(maxTokens) : 0,
                                   color: .accentColor, width: chartWidth - 120 - 72 - 64)
            Spacer(minLength: 0)
            Text(Format.tokensShort(tokens)).font(.caption).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(Format.cost(cost)).font(.caption).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    // MARK: - Stats

    private func statsGrid(_ r: PeriodReport) -> some View {
        let items: [(String, String)] = [
            ("Active days", "\(r.activeDays) of \(r.totalDays)"),
            ("Daily average", Format.tokensShort(r.dailyAverage)),
            ("Busiest day", r.busiestDay.map { "\(Format.shortMonthDay($0.date)) · \(Format.tokensShort($0.totalTokens))" } ?? "—"),
            ("Longest streak", "\(r.longestStreak) day\(r.longestStreak == 1 ? "" : "s")"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                   GridItem(.flexible(), alignment: .leading)], spacing: 12) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                    Text(item.1).font(.callout)
                }
            }
        }
    }

    // MARK: - Helpers

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            content()
        }
    }

    /// Match the dashboard's vendor palette (Claude orange, GPT teal).
    private func vendorColor(_ vendor: String) -> Color {
        ModelColors.color(for: vendor == Vendor.claude.displayName ? "claude" : "gpt")
    }
}
