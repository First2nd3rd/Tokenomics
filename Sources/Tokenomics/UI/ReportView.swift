import SwiftUI
import AppKit

/// The Statistics pane of the unified settings window: a day / week / month usage
/// breakdown read from the durable archive. This Mac only (see the note when sync
/// is on). Presentation only — every figure comes from `PeriodReport`.
struct ReportView: View {
    @ObservedObject var model: ReportModel
    @State private var copied = false
    /// Week chart page: daily bars by default, fixed-hour slots on page 2
    /// (chart click or the page dots switch, like the popover decks).
    @State private var weekFine = false
    /// Slot width for the fine page, stepped through `Self.slotChoices`.
    @AppStorage("weekSlotHours") private var weekSlotHours = 3
    private static let slotChoices = [1, 2, 3, 4, 6, 8, 12]

    /// Charts draw at explicit widths (see ChartKit); sized to the settings
    /// window's detail column.
    private let chartWidth = SettingsWindowMetrics.detailContentWidth

    var body: some View {
        Form {
            Section { header }
            if let report = model.report, report.total.total > 0 {
                content(report)
            } else if model.isLoading {
                // Nothing (or an empty period) shown yet — spinner, not a
                // premature "No usage", while the new period loads.
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            } else {
                Section {
                    Text(model.period == .all ? "No usage recorded yet."
                                              : "No usage recorded in this period.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.syncOn = UserDefaults.standard.bool(forKey: "syncEnabled")
            model.reload()
        }
        .onChange(of: model.report?.key) { _, _ in copied = false }
    }

    /// The stored slot width, snapped to the nearest allowed choice.
    private var slotHours: Int {
        Self.slotChoices.min { abs($0 - weekSlotHours) < abs($1 - weekSlotHours) } ?? 3
    }

    /// The stepper walks the allowed slot widths (1, 2, 3, 4, 6, 8, 12h) by index.
    private var slotChoiceIndex: Binding<Int> {
        Binding(
            get: { Self.slotChoices.firstIndex(of: slotHours) ?? 2 },
            set: { weekSlotHours = Self.slotChoices[$0] }
        )
    }

    // MARK: - Header (granularity picker + period navigator)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.period) {
                ForEach(ReportPeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 14) {
                // All time is a single unbounded period — nothing to step through.
                if model.period != .all {
                    Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Text(model.period.range(containing: model.anchor).title)
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 190, alignment: .leading)
                if model.period != .all {
                    Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                        .disabled(!model.canStepForward)
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Content

    @ViewBuilder private func content(_ r: PeriodReport) -> some View {
        if r.period == .all {
            OverviewSections(r: r, syncOn: model.syncOn, chartWidth: chartWidth)
        } else {
            periodSections(r)
        }
        Section {
            Button(copied ? "Copied ✓" : "Copy as Markdown") { copyMarkdown(r) }
        }
    }

    @ViewBuilder private func periodSections(_ r: PeriodReport) -> some View {
        Section {
            headline(r)
        }
        // A single day gets its intraday shape (hour-of-day bars); one lone daily
        // bar says nothing. The week can toggle density with a click (the popover
        // charts use the same tap-to-cycle gesture); the month keeps daily bars.
        if r.period == .day, let hourly = r.hourly {
            Section("By Hour") {
                VStack(alignment: .leading, spacing: 8) {
                    ChartKit.hourlyBars(hourly, width: chartWidth)
                    ChartKit.tokenLegend()
                }
                .padding(.vertical, 2)
            }
        } else if r.period == .week, let fine = r.fine {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if weekFine {
                        ChartKit.slotBars(PeriodReport.regroup(fine, hours: slotHours),
                                          width: chartWidth)
                    } else {
                        ChartKit.dailyBars(r.days, width: chartWidth)
                    }
                    HStack {
                        ChartKit.tokenLegend()
                        Spacer()
                        ChartKit.pageDots(current: weekFine ? 1 : 0, count: 2) { weekFine = $0 == 1 }
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { weekFine.toggle() }
            } header: {
                HStack(spacing: 8) {
                    Text(weekFine ? (slotHours == 1 ? "Hourly" : "Every \(slotHours) Hours") : "Daily")
                    if weekFine {
                        Stepper("", value: slotChoiceIndex, in: 0...(Self.slotChoices.count - 1))
                            .labelsHidden()
                            .controlSize(.mini)
                    }
                }
            }
        } else {
            Section("Daily") {
                VStack(alignment: .leading, spacing: 8) {
                    ChartKit.dailyBars(r.days, width: chartWidth)
                    ChartKit.tokenLegend()
                }
                .padding(.vertical, 2)
            }
        }
        // A month of daily bars is hard to read at a glance; the weekly rollup
        // (bars keyed by each week's start day) gives the coarse shape. Same
        // chart, week-summed series.
        if r.period == .month {
            Section("Weekly") {
                VStack(alignment: .leading, spacing: 8) {
                    ChartKit.dailyBars(r.weeklyRollup(), width: chartWidth)
                    ChartKit.tokenLegend()
                }
                .padding(.vertical, 2)
            }
            cacheRateSection(r)
        }
        if !r.byVendor.isEmpty { Section("By Vendor") { VendorRows(vendors: r.byVendor, width: chartWidth) } }
        if !r.byModel.isEmpty { Section("By Model") { ModelRows(models: r.byModel, width: chartWidth) } }
        Section("Stats") { statsGrid(r) }
    }

    /// Daily cache-hit-rate line for the month — how much of each day's prompt
    /// side came from cache. Needs two rated days to draw a line at all.
    @ViewBuilder private func cacheRateSection(_ r: PeriodReport) -> some View {
        let rated = r.days.filter { $0.cacheHitRate != nil }
        if rated.count >= 2 {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ChartKit.cacheRateLine(r.days, width: chartWidth)
                    Text("Cache reads ÷ prompt tokens (input + cache write + cache read)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                HStack(spacing: 8) {
                    Text("Cache Hit Rate")
                    if let average = DailyUsage.cacheHitRate(across: r.days) {
                        Text("avg \(Format.percent(average))")
                            .font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func copyMarkdown(_ r: PeriodReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReportMarkdown.make(r, syncOn: model.syncOn), forType: .string)
        copied = true
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
            ReportCaveats(syncOn: model.syncOn, pricesFrozen: r.pricesFrozen)
        }
        .padding(.vertical, 2)
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
        .padding(.vertical, 2)
    }
}
