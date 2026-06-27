import Testing
import Foundation
@testable import Tokenomics

/// Tests for `Dashboard.make(from:now:calendar:)`.
///
/// All date/timezone dependent behavior is pinned to a fixed UTC calendar and a
/// fixed `now`, with day keys supplied as literal ISO strings. `DayBucket.dayKey`
/// derives `todayKey` from the passed calendar, so the comparison against each
/// `DailyUsage.date` literal is fully deterministic.
@Suite("Dashboard")
struct DashboardTests {

    // MARK: - Helpers

    /// A UTC gregorian calendar so `DayBucket.dayKey(now:)` is timezone-independent.
    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Builds a `Date` from explicit components using the UTC calendar.
    private static func date(_ cal: Calendar,
                            year: Int, month: Int, day: Int,
                            hour: Int = 12) -> Date {
        DateComponents(calendar: cal,
                       timeZone: cal.timeZone,
                       year: year, month: month, day: day, hour: hour).date!
    }

    /// Constructs a `DailyUsage` with a literal day key and a chosen token total.
    private static func usage(_ dayKey: String, totalTokens: Int) -> DailyUsage {
        DailyUsage(date: dayKey,
                   inputTokens: 0,
                   outputTokens: 0,
                   cacheCreationTokens: 0,
                   cacheReadTokens: 0,
                   totalTokens: totalTokens,
                   totalCost: 0,
                   models: [])
    }

    // MARK: - isToday + headline

    @Test("isToday is true and headline is today's entry when today has data")
    func headlineIsTodayWhenPresent() throws {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 7)
        let snapshot = UsageSnapshot(days: [
            Self.usage("2026-06-05", totalTokens: 100),
            Self.usage("2026-06-06", totalTokens: 200),
            Self.usage("2026-06-07", totalTokens: 300),
        ])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert
        let headline = try #require(dashboard.headline)
        #expect(dashboard.hasUsageToday == true)
        #expect(headline.date == "2026-06-07")
        #expect(headline.totalTokens == 300)
    }

    @Test("headline is a zero today and lastActive is the most recent prior day when today is absent")
    func headlineZeroWhenTodayAbsent() throws {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 7)
        // Series ends on 2026-06-06; there is no entry for today (2026-06-07).
        let snapshot = UsageSnapshot(days: [
            Self.usage("2026-06-04", totalTokens: 100),
            Self.usage("2026-06-05", totalTokens: 200),
            Self.usage("2026-06-06", totalTokens: 250),
        ])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert: the headline is today (synthesized zero), not yesterday.
        let headline = try #require(dashboard.headline)
        #expect(dashboard.hasUsageToday == false)
        #expect(headline.date == "2026-06-07")
        #expect(headline.totalTokens == 0)
        #expect(dashboard.lastActive?.date == "2026-06-06")    // context for "last active …"
        #expect(dashboard.lastActive?.totalTokens == 250)
    }

    @Test("headline is nil when the snapshot has no days")
    func headlineNilWhenEmpty() {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 7)
        let snapshot = UsageSnapshot(days: [])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert
        #expect(dashboard.hasUsageToday == false)
        #expect(dashboard.headline == nil)
        #expect(dashboard.lastActive == nil)
        #expect(dashboard.avgTokens == nil)
    }

    // MARK: - avgTokens

    @Test("avgTokens is the mean of prior days and excludes the headline day")
    func avgExcludesHeadlineDay() {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 7)
        // Headline is today (2026-06-07, 9999 tokens). Prior days: 100, 200, 300.
        // Expected average = (100 + 200 + 300) / 3 = 200, ignoring the 9999.
        let snapshot = UsageSnapshot(days: [
            Self.usage("2026-06-04", totalTokens: 100),
            Self.usage("2026-06-05", totalTokens: 200),
            Self.usage("2026-06-06", totalTokens: 300),
            Self.usage("2026-06-07", totalTokens: 9999),
        ])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert
        #expect(dashboard.hasUsageToday == true)
        #expect(dashboard.avgTokens == 200)
    }

    @Test("avgTokens averages only the most recent 7 prior days when more exist")
    func avgUsesAtMostSevenPriorDays() {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 10)
        // 10 days total. Headline is today (2026-06-10). The earliest two prior
        // days (1 and 2) must be dropped; the window is the 7 most recent prior
        // days: 600..1200 stepping by 100 -> mean = 900.
        let snapshot = UsageSnapshot(days: [
            Self.usage("2026-06-01", totalTokens: 100), // dropped (outside window)
            Self.usage("2026-06-02", totalTokens: 200), // dropped (outside window)
            Self.usage("2026-06-03", totalTokens: 600),
            Self.usage("2026-06-04", totalTokens: 700),
            Self.usage("2026-06-05", totalTokens: 800),
            Self.usage("2026-06-06", totalTokens: 900),
            Self.usage("2026-06-07", totalTokens: 1000),
            Self.usage("2026-06-08", totalTokens: 1100),
            Self.usage("2026-06-09", totalTokens: 1200),
            Self.usage("2026-06-10", totalTokens: 5000), // headline (today), excluded
        ])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert
        #expect(dashboard.hasUsageToday == true)
        // (600+700+800+900+1000+1100+1200) / 7 = 6300 / 7 = 900
        #expect(dashboard.avgTokens == 900)
    }

    @Test("avgTokens is nil when the headline is the only day with data")
    func avgNilWhenNoPriorDays() {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 7)
        let snapshot = UsageSnapshot(days: [
            Self.usage("2026-06-07", totalTokens: 400),
        ])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert
        #expect(dashboard.hasUsageToday == true)
        #expect(dashboard.avgTokens == nil)
    }

    @Test("avgTokens excludes only today, including the most recent completed day")
    func avgIncludesRecentCompletedDay() {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 7)
        // Today (2026-06-07) is empty; the recent average covers the completed days
        // 06-04..06-06, which now includes the most recent one (06-06).
        let snapshot = UsageSnapshot(days: [
            Self.usage("2026-06-04", totalTokens: 100),
            Self.usage("2026-06-05", totalTokens: 300),
            Self.usage("2026-06-06", totalTokens: 5000),
        ])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert
        #expect(dashboard.hasUsageToday == false)
        #expect(dashboard.headline?.date == "2026-06-07")     // today, zero
        #expect(dashboard.lastActive?.date == "2026-06-06")
        // today excluded; (100 + 300 + 5000) / 3 = 1800
        #expect(dashboard.avgTokens == 1800)
    }
}
