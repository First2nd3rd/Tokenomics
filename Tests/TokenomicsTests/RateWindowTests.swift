import Testing
import Foundation
@testable import Tokenomics

@Suite("RateWindow")
struct RateWindowTests {
    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// A Date at the given UTC wall-clock time.
    private static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: utcCalendar(), timeZone: TimeZone(identifier: "UTC")!,
                       year: year, month: month, day: day, hour: hour, minute: minute).date!
    }

    /// A 1440-minute day where minute m carries `m` input tokens (so values
    /// identify their source minute in assertions).
    private static func indexedDay() -> [MinuteBucket] {
        (0..<1440).map { m in
            var b = MinuteBucket()
            b.add(input: m, output: 0, cacheCreation: 0, cacheRead: 0, model: nil)
            return b
        }
    }

    @Test("window entirely inside today ends at the current minute")
    func insideToday() {
        // Arrange — 14:30 UTC; today's minute m carries m tokens.
        let cal = Self.utcCalendar()
        let now = Self.utc(2026, 6, 9, 14, 30)
        let matrix = ["2026-06-09": Self.indexedDay()]

        // Act
        let window = RateWindow.lastMinutes(matrix: matrix, now: now, count: 60, calendar: cal)

        // Assert — minutes 811…870 (14:30 == minute 870), oldest first.
        #expect(window.count == 60)
        #expect(window.first?.counts.input == 870 - 59)
        #expect(window.last?.counts.input == 870)
    }

    @Test("window crossing midnight stitches yesterday's tail before today's head")
    func crossesMidnight() {
        // Arrange — 00:30 UTC; yesterday's minutes are offset by +10000 to tell
        // the two days apart.
        let cal = Self.utcCalendar()
        let now = Self.utc(2026, 6, 10, 0, 30)
        let yesterday = (0..<1440).map { m in
            var b = MinuteBucket()
            b.add(input: 10000 + m, output: 0, cacheCreation: 0, cacheRead: 0, model: nil)
            return b
        }
        let matrix = ["2026-06-09": yesterday, "2026-06-10": Self.indexedDay()]

        // Act
        let window = RateWindow.lastMinutes(matrix: matrix, now: now, count: 60, calendar: cal)

        // Assert — 29 buckets from yesterday (23:31…23:59) then 31 from today (00:00…00:30).
        #expect(window.count == 60)
        #expect(window.first?.counts.input == 10000 + 1411)   // yesterday 23:31
        #expect(window[28].counts.input == 10000 + 1439)      // yesterday 23:59
        #expect(window[29].counts.input == 0)                 // today 00:00
        #expect(window.last?.counts.input == 30)              // today 00:30 (now)
    }

    @Test("days missing from the matrix contribute empty buckets")
    func missingDaysAreEmpty() {
        // Arrange — 00:05 with NO yesterday in the matrix.
        let cal = Self.utcCalendar()
        let now = Self.utc(2026, 6, 10, 0, 5)
        let matrix = ["2026-06-10": Self.indexedDay()]

        // Act
        let window = RateWindow.lastMinutes(matrix: matrix, now: now, count: 60, calendar: cal)

        // Assert — 54 empty buckets, then today's 00:00…00:05.
        #expect(window.count == 60)
        #expect(window[0].counts.total == 0)
        #expect(window[53].counts.total == 0)
        #expect(window[54].counts.input == 0)     // today minute 0 carries 0 by construction
        #expect(window.last?.counts.input == 5)
    }

    @Test("non-positive count yields an empty window")
    func zeroCount() {
        let cal = Self.utcCalendar()
        let now = Self.utc(2026, 6, 9, 12, 0)
        #expect(RateWindow.lastMinutes(matrix: [:], now: now, count: 0, calendar: cal).isEmpty)
    }
}
