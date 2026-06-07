import Testing
import Foundation
@testable import Tokenomics

/// Tests for `IntradayCurve.build(matrix:now:calendar:)`.
///
/// All dates are built in a fixed UTC gregorian calendar and all day keys are
/// literal strings we control, so nothing depends on the host clock or zone.
@Suite("IntradayCurve")
struct IntradayCurveTests {

    // MARK: - Deterministic helpers

    /// A gregorian calendar pinned to UTC so `dayKey`/`nowMinute` are predictable.
    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Builds a UTC `Date` for the fixed test day 2026-06-07 at the given time.
    private func utcDate(year: Int = 2026, month: Int = 6, day: Int = 7,
                         hour: Int, minute: Int = 0) -> Date {
        DateComponents(calendar: Self.utcCalendar, timeZone: TimeZone(identifier: "UTC")!,
                       year: year, month: month, day: day,
                       hour: hour, minute: minute).date!
    }

    /// Creates a 1440-length minute array, placing `tokens` (as plain input) at the
    /// listed minute-of-day positions. Everything else is zero.
    private func minutes(_ entries: [(minute: Int, tokens: Int)]) -> [MinuteBucket] {
        var buckets = Array(repeating: MinuteBucket(), count: 1440)
        for e in entries {
            buckets[e.minute].add(input: e.tokens, output: 0,
                                  cacheCreation: 0, cacheRead: 0, model: nil)
        }
        return buckets
    }

    // MARK: - projectedTotal from a known fraction

    @Test("projectedTotal equals todayCum[now] divided by the typical fraction at now")
    func projectedTotalMatchesFractionFormula() throws {
        // Arrange: now is exactly noon (minute 720, a 5-min boundary).
        let cal = Self.utcCalendar
        let now = utcDate(hour: 12)

        // Prior day: half the tokens land before noon, half after — so the typical
        // normalized fraction completed by noon is exactly 0.5.
        let priorDay = minutes([(minute: 600, tokens: 1_000),
                                (minute: 800, tokens: 1_000)])
        // Today: 400 tokens accumulated by noon.
        let today = minutes([(minute: 600, tokens: 400)])

        let matrix: [String: [MinuteBucket]] = [
            "2026-06-06": priorDay,
            "2026-06-07": today,
        ]

        // Act
        let series = IntradayCurve.build(matrix: matrix, now: now, calendar: cal)

        // Assert: 400 / 0.5 = 800.
        let projected = try #require(series.projectedTotal)
        #expect(projected == 800)
    }

    // MARK: - No prior days

    @Test("with no prior days typical is empty and projectedTotal is nil")
    func noPriorDaysYieldsNoTypicalOrProjection() {
        // Arrange: only today's data exists.
        let cal = Self.utcCalendar
        let now = utcDate(hour: 12)
        let today = minutes([(minute: 600, tokens: 400)])
        let matrix: [String: [MinuteBucket]] = ["2026-06-07": today]

        // Act
        let series = IntradayCurve.build(matrix: matrix, now: now, calendar: cal)

        // Assert
        #expect(series.typical.isEmpty)
        #expect(series.projectedTotal == nil)
        #expect(series.predicted.isEmpty)
    }

    // MARK: - minFraction guard

    @Test("very early in the day the minFraction guard suppresses projection")
    func minFractionGuardSuppressesEarlyProjection() {
        // Arrange: now is 00:05 (minute 5). The prior day puts essentially all of
        // its tokens late in the day, so the fraction completed by 00:05 is far
        // below the 0.05 stability floor.
        let cal = Self.utcCalendar
        let now = utcDate(hour: 0, minute: 5)

        let priorDay = minutes([(minute: 1_400, tokens: 10_000)])
        let today = minutes([(minute: 1, tokens: 50)])
        let matrix: [String: [MinuteBucket]] = [
            "2026-06-06": priorDay,
            "2026-06-07": today,
        ]

        // Act
        let series = IntradayCurve.build(matrix: matrix, now: now, calendar: cal)

        // Assert: typical still exists (there is a prior day) but projection is gated.
        #expect(!series.typical.isEmpty)
        #expect(series.projectedTotal == nil)
        #expect(series.predicted.isEmpty)
    }

    // MARK: - End-of-day pins

    @Test("end-of-day pins predicted to projectedTotal and typical to the full typical total")
    func endOfDayPinsReachFullTotals() throws {
        // Arrange
        let cal = Self.utcCalendar
        let now = utcDate(hour: 12)

        // Prior day total is 2_000; half completed by noon → fraction 0.5.
        let priorDay = minutes([(minute: 600, tokens: 1_000),
                                (minute: 800, tokens: 1_000)])
        let today = minutes([(minute: 600, tokens: 400)])
        let matrix: [String: [MinuteBucket]] = [
            "2026-06-06": priorDay,
            "2026-06-07": today,
        ]

        // Act
        let series = IntradayCurve.build(matrix: matrix, now: now, calendar: cal)

        // Assert: the predicted line ends exactly at projectedTotal (= 800)…
        let projected = try #require(series.projectedTotal)
        let lastPredicted = try #require(series.predicted.last)
        #expect(lastPredicted.tokens == projected)
        #expect(lastPredicted.id == 1440)
        #expect(lastPredicted.hour == 24.0)

        // …and the typical line ends at the full averaged typical total (= 2_000).
        let lastTypical = try #require(series.typical.last)
        #expect(lastTypical.tokens == 2_000)
        #expect(lastTypical.id == 1440)
        #expect(lastTypical.hour == 24.0)
    }

    // MARK: - Today line stops at now

    @Test("today line stops at now and is pinned to the exact cumulative there")
    func todayLineStopsAtNow() throws {
        // Arrange: now is 12:00 (minute 720).
        let cal = Self.utcCalendar
        let now = utcDate(hour: 12)

        let priorDay = minutes([(minute: 600, tokens: 1_000),
                                (minute: 800, tokens: 1_000)])
        // Today: 400 tokens before now, plus 999 tokens AFTER now that must not
        // appear in the today line.
        let today = minutes([(minute: 600, tokens: 400),
                             (minute: 900, tokens: 999)])
        let matrix: [String: [MinuteBucket]] = [
            "2026-06-06": priorDay,
            "2026-06-07": today,
        ]

        // Act
        let series = IntradayCurve.build(matrix: matrix, now: now, calendar: cal)

        // Assert: the today line ends exactly at minute 720…
        let lastToday = try #require(series.today.last)
        #expect(lastToday.id == 720)
        #expect(lastToday.hour == 12.0)
        // …with only the pre-now cumulative (400), excluding the later 999.
        #expect(lastToday.tokens == 400)
        // No today point may sit past now.
        #expect(series.today.allSatisfy { $0.id <= 720 })
    }

    // MARK: - Heavy and light prior days contribute equally to the SHAPE

    @Test("a heavy day and a light day with identical shape weight the fraction equally")
    func heavyAndLightDaysContributeEquallyToShape() throws {
        // Arrange: two prior days share the SAME normalized shape (half by noon)
        // but wildly different magnitudes. Normalization should make the fraction
        // at noon land on 0.5 regardless, so the projection is unchanged.
        let cal = Self.utcCalendar
        let now = utcDate(hour: 12)

        let heavyDay = minutes([(minute: 600, tokens: 1_000_000),
                               (minute: 800, tokens: 1_000_000)])
        let lightDay = minutes([(minute: 600, tokens: 10),
                               (minute: 800, tokens: 10)])
        let today = minutes([(minute: 600, tokens: 400)])

        let matrix: [String: [MinuteBucket]] = [
            "2026-06-05": heavyDay,
            "2026-06-06": lightDay,
            "2026-06-07": today,
        ]

        // Act
        let series = IntradayCurve.build(matrix: matrix, now: now, calendar: cal)

        // Assert: fraction at noon averages to 0.5 → 400 / 0.5 = 800, despite the
        // heavy day dwarfing the light one in absolute terms.
        let projected = try #require(series.projectedTotal)
        #expect(projected == 800)
    }
}
