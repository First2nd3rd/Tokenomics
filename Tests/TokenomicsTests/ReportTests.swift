import Testing
import Foundation
@testable import Tokenomics

@Suite("ReportPeriod")
struct ReportPeriodTests {
    /// Fixed UTC calendar so period boundaries are deterministic on any CI machine.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test("month range spans the calendar month")
    func monthRange() {
        let r = ReportPeriod.month.range(containing: date(2026, 6, 15), calendar: cal)
        #expect(r.key == "2026-06")
        #expect(r.title == "June 2026")
        #expect(r.start == date(2026, 6, 1, 0))
        #expect(r.end == date(2026, 7, 1, 0))
        #expect(r.dayCount(calendar: cal) == 30)
    }

    @Test("previous month steps back one month")
    func previousMonth() {
        let june = ReportPeriod.month.range(containing: date(2026, 6, 15), calendar: cal)
        #expect(ReportPeriod.month.previous(june, calendar: cal).key == "2026-05")
    }

    @Test("week range is seven days and steps weekly")
    func weekRange() {
        let r = ReportPeriod.week.range(containing: date(2026, 6, 15), calendar: cal)
        #expect(r.dayCount(calendar: cal) == 7)
        #expect(r.contains(date(2026, 6, 15)))
        let prev = ReportPeriod.week.previous(r, calendar: cal)
        #expect(prev.end == r.start)
    }

    @Test("day range is a single day")
    func dayRange() {
        let r = ReportPeriod.day.range(containing: date(2026, 6, 15), calendar: cal)
        #expect(r.key == "2026-06-15")
        #expect(r.dayCount(calendar: cal) == 1)
        #expect(r.contains(epoch: Int(date(2026, 6, 15, 23).timeIntervalSince1970)))
        #expect(!r.contains(epoch: Int(date(2026, 6, 16, 0).timeIntervalSince1970)))
    }

    @Test("monthsSpanning enumerates inclusive month keys")
    func monthsSpanning() {
        #expect(DayBucket.monthsSpanning(from: date(2026, 4, 20), to: date(2026, 6, 5), calendar: cal)
                == ["2026-04", "2026-05", "2026-06"])
    }

    @Test("segmentsToRead covers previous, current, and the next-month slack")
    func segmentsToRead() {
        let june = ReportPeriod.month.range(containing: date(2026, 6, 15), calendar: cal)
        #expect(june.segmentsToRead(calendar: cal) == ["2026-05", "2026-06", "2026-07"])
    }
}

@Suite("PeriodReport")
struct PeriodReportTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func rec(_ source: UsageSource = .claude, key: String?, tokens: Int,
                     model: String = "claude-opus-4-8", _ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> UsageRecord {
        UsageRecord(source: source, key: key, epoch: Int(date(y, m, d, h).timeIntervalSince1970),
                    input: tokens, output: 0, cacheCreation: 0, cacheRead: 0, model: model)
    }

    @Test("a completed month sums the period and excludes other months")
    func completedMonth() {
        let records = [
            rec(key: "a", tokens: 100, 2026, 6, 1),
            rec(key: "b", tokens: 200, 2026, 6, 2),
            rec(key: "c", tokens: 300, 2026, 6, 3),
            rec(key: "may", tokens: 50, 2026, 5, 20),   // prior month
            rec(key: "jul", tokens: 999, 2026, 7, 1),   // next month, must be excluded
        ]
        let r = PeriodReport.make(records: records, period: .month, anchor: date(2026, 6, 15),
                                  now: date(2026, 7, 15), calendar: cal)
        #expect(r.key == "2026-06")
        #expect(r.total.total == 600)
        #expect(r.activeDays == 3)
        #expect(r.totalDays == 30)
        #expect(r.busiestDay?.totalTokens == 300)
        #expect(r.dailyAverage == 200)
        #expect(r.longestStreak == 3)               // Jun 1–3 consecutive
        #expect(r.previousTokens == 50)             // May
        #expect(r.isCurrent == false)
        #expect(r.projectedTokens == nil)           // not in progress
    }

    @Test("an in-progress month projects from the trailing 7-day rate")
    func currentMonthProjection() {
        let records = [
            rec(key: "a", tokens: 100, 2026, 6, 8),
            rec(key: "b", tokens: 100, 2026, 6, 9),
        ]
        // Viewed on Jun 10: trailing 7-day window (Jun 3–9) holds 200 → rate 200/7.
        // 21 days left (10th–30th) → 200 completed + 200/7 × 21 = 800.
        let r = PeriodReport.make(records: records, period: .month, anchor: date(2026, 6, 10),
                                  now: date(2026, 6, 10), calendar: cal)
        #expect(r.isCurrent)
        #expect(r.total.total == 200)
        #expect(r.totalDays == 10)                  // elapsed days, not 30
        #expect(r.projectedTokens == 800)
    }

    @Test("projection is stable across days for a steady rate (no early-month spike)")
    func projectionStability() {
        // 100 tokens every day from May 25 onward. Under the old ×(fullDays/elapsed)
        // linear rule, Jun 1 would project 3100 and decay daily; the trailing-rate
        // rule projects the same ~3000 whether viewed on Jun 1 or Jun 10. Each view
        // only feeds the records that exist at that instant (no future days).
        var may: [UsageRecord] = []
        for d in 25...31 { may.append(rec(key: "m\(d)", tokens: 100, 2026, 5, d)) }
        var june: [UsageRecord] = []
        for d in 1...10 { june.append(rec(key: "j\(d)", tokens: 100, 2026, 6, d)) }

        let onJun1 = PeriodReport.make(records: may + [june[0]], period: .month, anchor: date(2026, 6, 1),
                                       now: date(2026, 6, 1), calendar: cal)
        let onJun10 = PeriodReport.make(records: may + june, period: .month, anchor: date(2026, 6, 10),
                                        now: date(2026, 6, 10), calendar: cal)
        #expect(onJun1.projectedTokens == 3000)     // 0 completed + 100/day × 30 left
        #expect(onJun10.projectedTokens == 3000)    // 900 completed + 100/day × 21 left
    }

    @Test("projection never goes below what the period already holds")
    func projectionFloor() {
        // All usage today, silent trailing week → floor at the current total.
        let records = [rec(key: "t", tokens: 500, 2026, 6, 10)]
        let r = PeriodReport.make(records: records, period: .month, anchor: date(2026, 6, 10),
                                  now: date(2026, 6, 10), calendar: cal)
        #expect(r.projectedTokens == 500)
    }

    @Test("byVendor splits Claude and GPT; byModel excludes synthetic and sorts")
    func vendorAndModelSplit() {
        let records = [
            rec(.claude, key: "a", tokens: 100, model: "claude-opus-4-8", 2026, 6, 1),
            rec(.claude, key: "b", tokens: 40, model: "claude-haiku-4-5-20251001", 2026, 6, 1),
            rec(.codex, key: "x", tokens: 60, model: "gpt-5.5", 2026, 6, 2),
            rec(.claude, key: "s", tokens: 9999, model: "<synthetic>", 2026, 6, 2),
        ]
        let r = PeriodReport.make(records: records, period: .month, anchor: date(2026, 6, 15),
                                  now: date(2026, 7, 1), calendar: cal)
        let vendors = Dictionary(uniqueKeysWithValues: r.byVendor.map { ($0.vendor, $0.tokens) })
        #expect(vendors["Claude"] == 140 + 9999)        // vendor totals include all tokens
        #expect(vendors["GPT"] == 60)
        // byModel excludes <synthetic> and is sorted by tokens descending.
        #expect(r.byModel.map(\.model) == ["claude-opus-4-8", "gpt-5.5", "claude-haiku-4-5-20251001"])
        #expect(r.byModel.allSatisfy { $0.model != "<synthetic>" })
    }

    @Test("a record at the month's first instant lands in that month")
    func timezoneBoundary() {
        let records = [rec(key: "edge", tokens: 10, 2026, 6, 1, 0)]   // Jun 1 00:00 UTC
        let r = PeriodReport.make(records: records, period: .month, anchor: date(2026, 6, 15),
                                  now: date(2026, 7, 1), calendar: cal)
        #expect(r.total.total == 10)
        #expect(r.days.first?.date == "2026-06-01")
    }

    @Test("longestStreak counts consecutive days, breaking on a gap")
    func streak() {
        // Jun 1,2,3 then gap then 5,6 → longest run is 3.
        #expect(PeriodReport.longestStreak(["2026-06-01", "2026-06-02", "2026-06-03",
                                            "2026-06-05", "2026-06-06"], calendar: cal) == 3)
        #expect(PeriodReport.longestStreak([], calendar: cal) == 0)
    }

    @Test("byModel carries a positive cost for a priced model")
    func modelCost() {
        let records = [rec(key: "a", tokens: 1_000_000, model: "claude-opus-4-8", 2026, 6, 1)]
        let r = PeriodReport.make(records: records, period: .month, anchor: date(2026, 6, 1),
                                  now: date(2026, 7, 1), calendar: cal)
        #expect((r.byModel.first?.cost ?? 0) > 0)
    }

    @Test("Markdown export carries the title, sections, and a vendor row")
    func markdownExport() {
        let records = [
            rec(.claude, key: "a", tokens: 100, model: "claude-opus-4-8", 2026, 6, 1),
            rec(.codex, key: "x", tokens: 60, model: "gpt-5.5", 2026, 6, 2),
        ]
        let r = PeriodReport.make(records: records, period: .month, anchor: date(2026, 6, 15),
                                  now: date(2026, 7, 1), calendar: cal)
        let md = ReportMarkdown.make(r, syncOn: true)
        #expect(md.contains("# Usage Report — June 2026"))
        #expect(md.contains("## By vendor"))
        #expect(md.contains("| Claude |"))
        #expect(md.contains("## By model"))
        #expect(md.contains("## Stats"))
        #expect(md.contains("Active days: 2 of 30"))
        #expect(md.contains("excludes other Macs"))      // sync note
        #expect(md.contains("estimated at current prices")) // completed month
    }
}
