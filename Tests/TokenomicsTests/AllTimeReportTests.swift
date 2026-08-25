import Testing
import Foundation
@testable import Tokenomics

@Suite("All-time report")
struct AllTimeReportTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func snap(_ date: String, tokens: Int, cost: Double = 0, frozen: Bool = true,
                      vendor: String = "Claude", model: String = "claude-opus-4-8") -> DaySnapshot {
        let counts = TokenCounts(input: tokens, output: 0, cacheCreation: 0, cacheRead: 0)
        return DaySnapshot(date: date, total: counts, cost: cost, pricedAt: 0, frozen: frozen,
                           byVendor: [VendorUsage(vendor: vendor, counts: counts, cost: cost)],
                           byModel: [ModelUsage(model: model, counts: counts, cost: cost)])
    }

    @Test("the all period is one unbounded range with a stable key")
    func allPeriodRange() {
        let r = ReportPeriod.all.range(containing: date(2026, 6, 15), calendar: cal)
        #expect(r.key == "all")
        #expect(r.title == "All Time")
        #expect(r.contains(date(1990, 1, 1)))
        #expect(r.contains(date(2050, 1, 1)))
        #expect(r.segmentsToRead(calendar: cal) == [])
    }

    @Test("makeAllTime sums everything and rolls months up")
    func totalsAndMonths() {
        let summaries = [
            snap("2026-05-20", tokens: 100, cost: 1),
            snap("2026-05-21", tokens: 200, cost: 2),
            snap("2026-06-10", tokens: 400, cost: 4, vendor: "GPT", model: "gpt-5"),
        ]
        let r = PeriodReport.makeAllTime(daySummaries: summaries, now: date(2026, 6, 15), calendar: cal)

        #expect(r.period == .all)
        #expect(r.key == "all")
        #expect(r.title == "All Time")
        #expect(r.total.total == 700)
        #expect(r.cost == 7)
        #expect(r.activeDays == 3)
        #expect(r.totalDays == 27)                      // May 20 → Jun 15, inclusive
        #expect(r.busiestDay?.totalTokens == 400)
        #expect(r.longestStreak == 2)                   // May 20–21
        #expect(r.byVendor.map(\.vendor) == ["GPT", "Claude"])
        #expect(r.byVendor.map(\.tokens) == [400, 300])

        let months = try! #require(r.months)
        #expect(months.map(\.month) == ["2026-05", "2026-06"])
        #expect(months.map(\.tokens) == [300, 400])
        #expect(months.map(\.cost) == [3, 4])
        #expect(months[0].byModel.map(\.model) == ["claude-opus-4-8"])
        #expect(r.activeWeeks == 2)                     // May 20–21 share a week; Jun 10 is another
    }

    @Test("silent months keep their slot in the monthly rollup")
    func gapMonthsFilled() {
        let r = PeriodReport.makeAllTime(
            daySummaries: [snap("2026-05-20", tokens: 100), snap("2026-08-10", tokens: 200)],
            now: date(2026, 8, 15), calendar: cal)
        let months = try! #require(r.months)
        #expect(months.map(\.month) == ["2026-05", "2026-06", "2026-07", "2026-08"])
        #expect(months.map(\.tokens) == [100, 0, 0, 200])
        #expect(months[1].byVendor.isEmpty)
    }

    @Test("all time has no previous period and no projection")
    func noDeltaNoProjection() {
        let r = PeriodReport.makeAllTime(daySummaries: [snap("2026-06-01", tokens: 10)],
                                         now: date(2026, 6, 15), calendar: cal)
        #expect(r.previousTokens == 0)
        #expect(r.projectedTokens == nil)
        #expect(r.projectedCost == nil)
        #expect(r.hourly == nil)
        #expect(r.fine == nil)
    }

    @Test("summaries after today are dropped")
    func futureDaysExcluded() {
        let r = PeriodReport.makeAllTime(
            daySummaries: [snap("2026-06-10", tokens: 100), snap("2026-06-16", tokens: 999)],
            now: date(2026, 6, 15), calendar: cal)
        #expect(r.total.total == 100)
        #expect(r.days.map(\.date) == ["2026-06-10"])
    }

    @Test("prices are frozen only when every completed day is")
    func priceFreezing() {
        // A live (unfrozen) TODAY doesn't unfreeze the report…
        let liveToday = PeriodReport.makeAllTime(
            daySummaries: [snap("2026-06-10", tokens: 1), snap("2026-06-15", tokens: 1, frozen: false)],
            now: date(2026, 6, 15), calendar: cal)
        #expect(liveToday.pricesFrozen)
        // …but an unfrozen completed day does.
        let liveYesterday = PeriodReport.makeAllTime(
            daySummaries: [snap("2026-06-10", tokens: 1), snap("2026-06-14", tokens: 1, frozen: false)],
            now: date(2026, 6, 15), calendar: cal)
        #expect(!liveYesterday.pricesFrozen)
    }

    @Test("empty history yields an empty, zero-span report")
    func emptyHistory() {
        let r = PeriodReport.makeAllTime(daySummaries: [], now: date(2026, 6, 15), calendar: cal)
        #expect(r.total.total == 0)
        #expect(r.totalDays == 0)
        #expect(r.activeDays == 0)
        #expect(r.months == [])
        #expect(r.dailyAverage == 0)
    }

    @Test("all-time markdown rolls days up into a monthly table")
    func markdown() {
        let r = PeriodReport.makeAllTime(
            daySummaries: [snap("2026-05-20", tokens: 100, cost: 1), snap("2026-06-10", tokens: 200, cost: 2)],
            now: date(2026, 6, 15), calendar: cal)
        let md = ReportMarkdown.make(r)
        #expect(md.contains("All Time"))
        #expect(md.contains("## Monthly"))
        #expect(md.contains("| 2026-05 |"))
        #expect(!md.contains("## Daily"))
        #expect(!md.contains("vs previous"))
    }
}

@Suite("Lifetime break-even")
struct LifetimeBreakEvenTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private func month(_ key: String, claude: Double = 0, gpt: Double = 0) -> MonthUsage {
        var vendors: [VendorUsage] = []
        if claude > 0 { vendors.append(VendorUsage(vendor: "Claude", counts: TokenCounts(), cost: claude)) }
        if gpt > 0 { vendors.append(VendorUsage(vendor: "GPT", counts: TokenCounts(), cost: gpt)) }
        return MonthUsage(month: key, counts: TokenCounts(), cost: claude + gpt,
                          byVendor: vendors, byModel: [])
    }

    @Test("each vendor's span starts at its own first recorded month")
    func perVendorSpans() {
        let months = [
            month("2026-05", claude: 300),
            month("2026-06", claude: 500, gpt: 40),
            month("2026-08", claude: 200, gpt: 10),   // a silent July doesn't shrink the span
        ]
        let result = BreakEven.lifetime(months: months, now: date(2026, 8, 15),
                                        claude: .subscription(monthlyUSD: 200), gpt: .api,
                                        calendar: cal)

        let claude = result.first { $0.vendor == .claude }!
        #expect(claude.monthsCount == 4)              // May → Aug inclusive
        #expect(claude.totalCost == 1000)
        #expect(claude.totalFees == 800)
        #expect(claude.multiple == 1.25)
        #expect(claude.progress == 1.0)

        let gpt = result.first { $0.vendor == .gpt }!
        #expect(gpt.monthsCount == 3)                 // Jun → Aug inclusive
        #expect(gpt.totalCost == 50)
        #expect(gpt.multiple == nil)                  // API basis — nothing to break even against
        #expect(gpt.totalFees == nil)
    }

    @Test("a subscribed vendor with no recorded usage has no span or multiple")
    func unusedVendor() {
        let result = BreakEven.lifetime(months: [month("2026-06", claude: 100)],
                                        now: date(2026, 6, 15),
                                        claude: .subscription(monthlyUSD: 200),
                                        gpt: .subscription(monthlyUSD: 20),
                                        calendar: cal)
        let gpt = result.first { $0.vendor == .gpt }!
        #expect(gpt.monthsCount == 0)
        #expect(gpt.totalFees == 0)
        #expect(gpt.multiple == nil)
    }

    @Test("a year boundary still counts calendar months")
    func yearBoundary() {
        let result = BreakEven.lifetime(months: [month("2026-11", claude: 100)],
                                        now: date(2027, 2, 10),
                                        claude: .subscription(monthlyUSD: 100), gpt: .api,
                                        calendar: cal)
        #expect(result.first { $0.vendor == .claude }!.monthsCount == 4)   // Nov → Feb
    }
}

@Suite("Activity grid")
struct ActivityGridTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    private func du(_ date: String, _ tokens: Int) -> DailyUsage {
        DailyUsage(date: date, inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0,
                   cacheReadTokens: 0, totalTokens: tokens, totalCost: 0, models: [])
    }

    @Test("53 week columns end at today, later cells are blank")
    func windowShape() {
        // Jun 15, 2026 is a Monday; default weeks start Sunday (Jun 14).
        let grid = ActivityGrid.make(days: [], now: date(2026, 6, 15), calendar: cal)
        #expect(grid.columns.count == ActivityGrid.weekCount)
        #expect(grid.columns.allSatisfy { $0.count == 7 })

        let last = grid.columns.last!
        #expect(last[0]?.day == "2026-06-14")
        #expect(last[1]?.day == "2026-06-15")
        #expect(last[2] == nil)                           // tomorrow

        let first = grid.columns.first!
        #expect(first[0]?.day == "2025-06-15")            // 52 weeks before the current week
        #expect(first.allSatisfy { $0 != nil })
    }

    @Test("levels bucket active days into quartiles, zero days stay level 0")
    func levels() {
        let days = [du("2026-06-08", 10), du("2026-06-09", 20),
                    du("2026-06-10", 30), du("2026-06-11", 40)]
        let grid = ActivityGrid.make(days: days, now: date(2026, 6, 15), calendar: cal)

        var byDay: [String: ActivityGrid.Cell] = [:]
        for cell in grid.columns.flatMap({ $0 }).compactMap({ $0 }) { byDay[cell.day] = cell }
        #expect(byDay["2026-06-08"]?.level == 1)
        #expect(byDay["2026-06-09"]?.level == 2)
        #expect(byDay["2026-06-10"]?.level == 3)
        #expect(byDay["2026-06-11"]?.level == 4)
        #expect(byDay["2026-06-12"]?.level == 0)
        #expect(byDay["2026-06-08"]?.tokens == 10)
    }

    @Test("the window maximum always paints darkest, even with uniform usage")
    func uniformUsageTopsOut() {
        // One active day: its cell must not sit at the faintest step.
        let single = ActivityGrid.make(days: [du("2026-06-10", 100)],
                                       now: date(2026, 6, 15), calendar: cal)
        let singleCells = single.columns.flatMap { $0 }.compactMap { $0 }.filter { $0.tokens > 0 }
        #expect(singleCells.map(\.level) == [4])

        // All-equal days: every one is the maximum, so all paint at the top.
        let equal = ActivityGrid.make(days: [du("2026-06-08", 50), du("2026-06-09", 50)],
                                      now: date(2026, 6, 15), calendar: cal)
        let equalCells = equal.columns.flatMap { $0 }.compactMap { $0 }.filter { $0.tokens > 0 }
        #expect(equalCells.map(\.level) == [4, 4])
    }

    @Test("month labels mark the columns holding each month's first day")
    func monthLabels() {
        let grid = ActivityGrid.make(days: [], now: date(2026, 6, 15), calendar: cal)
        // Jun 1, 2026 (a Monday) falls in the week starting Sunday May 31 —
        // three columns before the current week's.
        let junColumn = ActivityGrid.weekCount - 3
        #expect(grid.monthLabels[junColumn] == "Jun")
        // The window opens Jun 15, 2025 — after that June's 1st — so "Jun"
        // appears once (2026) and "Jul" (2025) is the first label.
        #expect(grid.monthLabels.values.filter { $0 == "Jun" }.count == 1)
        #expect(grid.monthLabels[grid.monthLabels.keys.min()!] == "Jul")
    }

    @Test("Mon / Wed / Fri rows carry their letters")
    func rowLabels() {
        let grid = ActivityGrid.make(days: [], now: date(2026, 6, 15), calendar: cal)
        #expect(grid.rowLabels == [nil, "M", nil, "W", nil, "F", nil])   // Sunday-start rows

        var mondayCal = cal
        mondayCal.firstWeekday = 2
        let mondayGrid = ActivityGrid.make(days: [], now: date(2026, 6, 15), calendar: mondayCal)
        #expect(mondayGrid.rowLabels == ["M", nil, "W", nil, "F", nil, nil])
    }
}
