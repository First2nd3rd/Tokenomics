import SwiftUI

/// The Statistics pane's All-time content: the activity heatmap with its headline
/// strip, the monthly trend deck, lifetime subscription payback, the all-time
/// vendor/model splits, and the record book. Emits sections into the pane's
/// grouped Form; every figure comes from the all-time `PeriodReport`.
struct OverviewSections: View {
    let r: PeriodReport
    let syncOn: Bool
    let chartWidth: CGFloat

    /// Monthly deck page (by type / by model / cost), persisted like the other
    /// paged charts.
    @AppStorage("allMonthlyPage") private var monthlyPage = 0
    private static let monthlyTitles = ["Monthly", "Monthly · By Model", "Monthly · Cost"]

    var body: some View {
        Section("Activity") { activity }
        if let months = r.months, months.count >= 2 { monthly(months) }
        subscription
        if !r.byVendor.isEmpty { Section("By Vendor") { VendorRows(vendors: r.byVendor, width: chartWidth) } }
        if !r.byModel.isEmpty { Section("By Model") { ModelRows(models: r.byModel, width: chartWidth) } }
        Section("Records") { records }
    }

    // MARK: - Activity (headline strip + heatmap)

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            strip
            ActivityHeatmap(grid: ActivityGrid.make(days: r.days, now: Date()))
            HStack {
                ActivityHeatmap.legend()
                Spacer()
                if let first = r.days.first?.date {
                    Text("Since \(Format.monthDayYear(first))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ReportCaveats(syncOn: syncOn, pricesFrozen: r.pricesFrozen)
        }
        .padding(.vertical, 2)
    }

    /// The all-time headline as a stat strip over the heatmap — averages are per
    /// ACTIVE day/week, matching the period views' "Daily average".
    private var strip: some View {
        let weeks = r.activeWeeks ?? 0
        let items: [(String, String)] = [
            ("Longest streak", "\(r.longestStreak) day\(r.longestStreak == 1 ? "" : "s")"),
            ("Avg / day", Format.tokensShort(r.dailyAverage)),
            ("Avg / week", weeks > 0 ? Format.tokensShort(r.total.total / weeks) : "—"),
            ("Total", Format.tokensShort(r.total.total)),
            ("Cost", Format.costGrouped(r.cost)),
        ]
        return HStack(alignment: .top, spacing: 8) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                    Text(item.1).font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Monthly trend deck

    private func monthly(_ months: [MonthUsage]) -> some View {
        let page = min(max(monthlyPage, 0), 2)
        let series = ChartKit.modelSeries(months)
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                switch page {
                case 1: ChartKit.monthlyModelBars(months, series: series, width: chartWidth)
                case 2: ChartKit.costBars(months, width: chartWidth)
                default: ChartKit.monthlyBars(months, width: chartWidth)
                }
                HStack {
                    switch page {
                    case 1: ChartKit.modelLegend(series)
                    case 2: Text("API-equivalent cost per month")
                                .font(.caption2).foregroundStyle(.secondary)
                    default: ChartKit.tokenLegend()
                    }
                    Spacer()
                    ChartKit.pageDots(current: page, count: 3) { monthlyPage = $0 }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { monthlyPage = (page + 1) % 3 }
        } header: {
            Text(Self.monthlyTitles[page])
        }
    }

    // MARK: - Lifetime subscription payback

    @ViewBuilder private var subscription: some View {
        let lifetimes = BreakEven.lifetime(months: r.months ?? [], now: Date(),
                                           claude: CostBasisStore.claude(), gpt: CostBasisStore.gpt())
            .filter { $0.totalCost > 0 || ($0.monthlyFee != nil && $0.monthsCount > 0) }
        // A payback story needs a subscription somewhere; a pure pay-as-you-go
        // setup already has its costs in By Vendor. A mixed setup keeps the API
        // row as context next to the subscription one, like the dashboard.
        if lifetimes.contains(where: { $0.monthlyFee != nil }) {
            Section("Subscription") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lifetimes) { lifetimeRow($0) }
                    // The stored basis has no plan history — the fee side of the
                    // math is an approximation worth admitting to.
                    Text("Assumes the current plan for every recorded month.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func lifetimeRow(_ v: VendorLifetime) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(v.vendor.displayName).font(.caption).fontWeight(.medium)
                Spacer()
                if let multiple = v.multiple {
                    Text(Format.multiple(multiple))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(multiple >= 1 ? Color.green : Color.secondary)
                } else {
                    Text("API").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if v.monthlyFee != nil {
                ChartKit.proportionBar(fraction: v.progress ?? 0,
                                       color: VendorRows.color(for: v.vendor.displayName),
                                       width: chartWidth)
            }
            Text(lifetimeDetail(v)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func lifetimeDetail(_ v: VendorLifetime) -> String {
        if let fees = v.totalFees, let fee = v.monthlyFee {
            return "\(Format.costGrouped(v.totalCost)) vs \(Format.costGrouped(fees))"
                + " (\(Format.costCompact(fee))/mo × \(v.monthsCount))"
        }
        return "\(Format.costGrouped(v.totalCost)) API-equivalent"
    }

    // MARK: - Records

    private var records: some View {
        let biggest = r.months?.max { $0.tokens < $1.tokens }
        let items: [(String, String)] = [
            ("Busiest day", r.busiestDay.map { "\(Format.shortMonthDay($0.date)) · \(Format.tokensShort($0.totalTokens))" } ?? "—"),
            ("Biggest month", biggest.map { "\(Format.shortMonth($0.month)) · \(Format.tokensShort($0.tokens))" } ?? "—"),
            ("Active days", "\(r.activeDays) of \(r.totalDays)"),
            ("First recorded", r.days.first.map { Format.monthDayYear($0.date) } ?? "—"),
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
