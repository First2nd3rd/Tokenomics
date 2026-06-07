import Testing
import Foundation
@testable import Tokenomics

// NOTE: DayBucket.localDay(_:) and DayBucket.localDayMinute(_:) format using the
// machine's current timezone (`.current` / `dayFormatter.timeZone = .current`),
// so they are not unit-tested deterministically here.
//
// NOTE on recentDays: it calls `dayKey(now)` internally WITHOUT a calendar
// parameter, so "today" is derived with `Calendar.current` (machine timezone).
// To keep these tests deterministic across machine timezones we always pick a
// `now` at 12:00 UTC. At noon UTC no realistic timezone offset (±14h is the
// extreme, common offsets are within ±12h) shifts the calendar day across a
// midnight boundary, so `dayKey(now)` resolves to the same "today" everywhere.
@Suite("DayBucket")
struct DayBucketTests {

    // A UTC calendar used for building deterministic `now` instants and for the
    // direct dayKey(_:calendar:) assertions.
    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Builds a Date at noon UTC on the given day (safe from timezone-induced
    /// day rollover when recentDays internally calls dayKey with .current).
    private static func noonUTC(year: Int, month: Int, day: Int) -> Date {
        let cal = utcCalendar()
        return DateComponents(
            calendar: cal, timeZone: TimeZone(identifier: "UTC")!,
            year: year, month: month, day: day, hour: 12, minute: 0
        ).date!
    }

    // MARK: - dayKey(_:calendar:)

    @Test("dayKey formats date as zero-padded yyyy-MM-dd in the given calendar")
    func dayKeyFormatsZeroPadded() {
        // Arrange
        let cal = Self.utcCalendar()
        let date = DateComponents(
            calendar: cal, timeZone: TimeZone(identifier: "UTC")!,
            year: 2026, month: 6, day: 7, hour: 12
        ).date!

        // Act
        let key = DayBucket.dayKey(date, calendar: cal)

        // Assert
        #expect(key == "2026-06-07")
    }

    @Test("dayKey zero-pads single-digit month and day")
    func dayKeyZeroPadsSingleDigits() {
        // Arrange
        let cal = Self.utcCalendar()
        let date = DateComponents(
            calendar: cal, timeZone: TimeZone(identifier: "UTC")!,
            year: 2026, month: 1, day: 3, hour: 12
        ).date!

        // Act
        let key = DayBucket.dayKey(date, calendar: cal)

        // Assert
        #expect(key == "2026-01-03")
    }

    @Test("dayKey respects the supplied calendar's timezone at a boundary")
    func dayKeyRespectsCalendarTimezone() {
        // Arrange: 2026-06-07 00:30 UTC is still 2026-06-06 in a UTC-2 zone.
        let utc = Self.utcCalendar()
        let instant = DateComponents(
            calendar: utc, timeZone: TimeZone(identifier: "UTC")!,
            year: 2026, month: 6, day: 7, hour: 0, minute: 30
        ).date!

        var minus2 = Calendar(identifier: .gregorian)
        minus2.timeZone = TimeZone(secondsFromGMT: -2 * 3600)!

        // Act
        let utcKey = DayBucket.dayKey(instant, calendar: utc)
        let minus2Key = DayBucket.dayKey(instant, calendar: minus2)

        // Assert
        #expect(utcKey == "2026-06-07")
        #expect(minus2Key == "2026-06-06")
    }

    // MARK: - recentDays

    @Test("recentDays keeps today plus the count most recent prior days with data")
    func recentDaysKeepsTodayPlusCount() {
        // Arrange: today is 2026-06-07; prior days each have data.
        let now = Self.noonUTC(year: 2026, month: 6, day: 7)
        let matrix: [String: [Int]] = [
            "2026-06-07": [7],
            "2026-06-06": [6],
            "2026-06-05": [5],
            "2026-06-04": [4],
            "2026-06-03": [3],
        ]

        // Act: count = 2 prior days -> today + 2 = 3 kept.
        let result = DayBucket.recentDays(matrix, now: now, count: 2)

        // Assert
        #expect(Set(result.keys) == ["2026-06-07", "2026-06-06", "2026-06-05"])
        #expect(result["2026-06-07"] == [7])
        #expect(result["2026-06-06"] == [6])
        #expect(result["2026-06-05"] == [5])
    }

    @Test("recentDays excludes days in the future relative to now")
    func recentDaysExcludesFuture() {
        // Arrange: today is 2026-06-05 but matrix has later-dated entries.
        let now = Self.noonUTC(year: 2026, month: 6, day: 5)
        let matrix: [String: [Int]] = [
            "2026-06-08": [8],   // future
            "2026-06-07": [7],   // future
            "2026-06-05": [5],   // today
            "2026-06-04": [4],
            "2026-06-03": [3],
        ]

        // Act: count large enough to keep all non-future days.
        let result = DayBucket.recentDays(matrix, now: now, count: 10)

        // Assert: future days dropped, today + priors retained.
        #expect(Set(result.keys) == ["2026-06-05", "2026-06-04", "2026-06-03"])
    }

    @Test("recentDays counts days-with-data not calendar days when there are gaps")
    func recentDaysHandlesGaps() {
        // Arrange: missing calendar days between entries; only days WITH data count.
        let now = Self.noonUTC(year: 2026, month: 6, day: 20)
        let matrix: [String: [Int]] = [
            "2026-06-20": [20],  // today
            "2026-06-15": [15],  // gap before today
            "2026-06-10": [10],
            "2026-06-01": [1],
        ]

        // Act: keep today + 2 most recent prior days-with-data.
        let result = DayBucket.recentDays(matrix, now: now, count: 2)

        // Assert: 2026-06-01 is the oldest and gets dropped despite calendar gaps.
        #expect(Set(result.keys) == ["2026-06-20", "2026-06-15", "2026-06-10"])
    }

    @Test("recentDays returns all available when count exceeds available prior days")
    func recentDaysCountLargerThanAvailable() {
        // Arrange
        let now = Self.noonUTC(year: 2026, month: 6, day: 7)
        let matrix: [String: [Int]] = [
            "2026-06-07": [7],
            "2026-06-06": [6],
            "2026-06-05": [5],
        ]

        // Act: ask for far more prior days than exist.
        let result = DayBucket.recentDays(matrix, now: now, count: 100)

        // Assert: everything (non-future) is kept, nothing fabricated.
        #expect(Set(result.keys) == ["2026-06-07", "2026-06-06", "2026-06-05"])
        #expect(result.count == 3)
    }

    @Test("recentDays preserves the payload arrays for kept days")
    func recentDaysPreservesPayload() {
        // Arrange
        let now = Self.noonUTC(year: 2026, month: 6, day: 7)
        let matrix: [String: [Int]] = [
            "2026-06-07": [1, 2, 3],
            "2026-06-06": [4, 5],
            "2026-06-05": [],
        ]

        // Act
        let result = DayBucket.recentDays(matrix, now: now, count: 5)

        // Assert
        #expect(result["2026-06-07"] == [1, 2, 3])
        #expect(result["2026-06-06"] == [4, 5])
        #expect(result["2026-06-05"] == [])
    }

    @Test("recentDays with count zero keeps only today")
    func recentDaysCountZeroKeepsOnlyToday() {
        // Arrange
        let now = Self.noonUTC(year: 2026, month: 6, day: 7)
        let matrix: [String: [Int]] = [
            "2026-06-07": [7],
            "2026-06-06": [6],
            "2026-06-05": [5],
        ]

        // Act: count + 1 = 1, so only the single most recent (today) is kept.
        let result = DayBucket.recentDays(matrix, now: now, count: 0)

        // Assert
        #expect(Set(result.keys) == ["2026-06-07"])
        #expect(result["2026-06-07"] == [7])
    }

    @Test("recentDays drops today's slot when today has no data and keeps recent priors")
    func recentDaysWhenTodayMissing() {
        // Arrange: no entry for today (2026-06-07); only prior days have data.
        let now = Self.noonUTC(year: 2026, month: 6, day: 7)
        let matrix: [String: [Int]] = [
            "2026-06-06": [6],
            "2026-06-05": [5],
            "2026-06-04": [4],
        ]

        // Act: keep at most count + 1 = 3 most-recent non-future keys.
        let result = DayBucket.recentDays(matrix, now: now, count: 2)

        // Assert: today absent from matrix, so the three most recent priors remain.
        #expect(Set(result.keys) == ["2026-06-06", "2026-06-05", "2026-06-04"])
    }

    @Test("recentDays returns empty when matrix is empty")
    func recentDaysEmptyMatrix() {
        // Arrange
        let now = Self.noonUTC(year: 2026, month: 6, day: 7)
        let matrix: [String: [Int]] = [:]

        // Act
        let result = DayBucket.recentDays(matrix, now: now, count: 5)

        // Assert
        #expect(result.isEmpty)
    }
}
