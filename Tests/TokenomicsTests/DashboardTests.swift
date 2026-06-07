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
        #expect(dashboard.isToday == true)
        #expect(headline.date == "2026-06-07")
        #expect(headline.totalTokens == 300)
    }

    @Test("headline falls back to most-recent day and isToday is false when today is absent")
    func headlineFallsBackWhenTodayAbsent() throws {
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

        // Assert
        let headline = try #require(dashboard.headline)
        #expect(dashboard.isToday == false)
        #expect(headline.date == "2026-06-06") // most recent day
        #expect(headline.totalTokens == 250)
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
        #expect(dashboard.isToday == false)
        #expect(dashboard.headline == nil)
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
        #expect(dashboard.isToday == true)
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
        #expect(dashboard.isToday == true)
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
        #expect(dashboard.isToday == true)
        #expect(dashboard.avgTokens == nil)
    }

    @Test("avgTokens excludes the most-recent day when it is the fallback headline")
    func avgExcludesFallbackHeadline() {
        // Arrange
        let cal = Self.utcCalendar()
        let now = Self.date(cal, year: 2026, month: 6, day: 7)
        // Today (2026-06-07) is absent, so the fallback headline is 2026-06-06.
        // That day must still be excluded from the average: mean of 100 and 300.
        let snapshot = UsageSnapshot(days: [
            Self.usage("2026-06-04", totalTokens: 100),
            Self.usage("2026-06-05", totalTokens: 300),
            Self.usage("2026-06-06", totalTokens: 5000), // fallback headline, excluded
        ])

        // Act
        let dashboard = Dashboard.make(from: snapshot, now: now, calendar: cal)

        // Assert
        let headline = dashboard.headline
        #expect(dashboard.isToday == false)
        #expect(headline?.date == "2026-06-06")
        // (100 + 300) / 2 = 200
        #expect(dashboard.avgTokens == 200)
    }
}
