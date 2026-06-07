import Testing
import Foundation
@testable import Tokenomics

@Suite("Format.tokensShort")
struct FormatTokensShortTests {
    @Test("renders small counts as raw integers")
    func rawIntegers() {
        #expect(Format.tokensShort(0) == "0")
        #expect(Format.tokensShort(312) == "312")
        #expect(Format.tokensShort(999) == "999")
    }

    @Test("renders thousands as whole k with no decimal")
    func thousands() {
        #expect(Format.tokensShort(1_000) == "1k")
        #expect(Format.tokensShort(1_500) == "2k") // rounds via %.0f
        #expect(Format.tokensShort(312_000) == "312k")
    }

    @Test("renders millions with one decimal")
    func millions() {
        #expect(Format.tokensShort(1_000_000) == "1.0M")
        #expect(Format.tokensShort(72_900_000) == "72.9M")
    }

    @Test("renders billions with one decimal")
    func billions() {
        #expect(Format.tokensShort(1_000_000_000) == "1.0B")
        #expect(Format.tokensShort(1_200_000_000) == "1.2B")
    }

    @Test("uses the largest applicable unit at boundaries")
    func boundaries() {
        // Just below 1k stays raw.
        #expect(Format.tokensShort(999) == "999")
        // Exactly 1k crosses into k.
        #expect(Format.tokensShort(1_000) == "1k")
        // Just below 1M stays in k (999999/1000 = 999.999 -> %.0f -> 1000k).
        #expect(Format.tokensShort(999_999) == "1000k")
        // Exactly 1M crosses into M.
        #expect(Format.tokensShort(1_000_000) == "1.0M")
        // Exactly 1B crosses into B.
        #expect(Format.tokensShort(1_000_000_000) == "1.0B")
    }
}

@Suite("Format.cost")
struct FormatCostTests {
    @Test("formats with a dollar sign and two decimals")
    func twoDecimals() {
        #expect(Format.cost(0) == "$0.00")
        #expect(Format.cost(3.5) == "$3.50")
        #expect(Format.cost(12.345) == "$12.35") // rounds to 2 dp
    }

    @Test("formats large values without grouping separators")
    func largeValue() {
        #expect(Format.cost(1234.5) == "$1234.50")
    }
}

@Suite("Format.multiple")
struct FormatMultipleTests {
    @Test("renders one decimal and a multiplication sign under 10x")
    func underTen() {
        #expect(Format.multiple(2.3) == "2.3\u{00D7}")
        #expect(Format.multiple(0.0) == "0.0\u{00D7}")
        #expect(Format.multiple(9.94) == "9.9\u{00D7}") // %.1f rounding
    }

    @Test("renders a whole number at or above 10x")
    func atOrAboveTen() {
        #expect(Format.multiple(10.0) == "10\u{00D7}")
        #expect(Format.multiple(12.7) == "13\u{00D7}") // %.0f rounding
        #expect(Format.multiple(100.0) == "100\u{00D7}")
    }
}

@Suite("Format.shortMonthDay")
struct FormatShortMonthDayTests {
    @Test("converts an ISO day string to month and day")
    func parsesIsoDay() {
        #expect(Format.shortMonthDay("2026-06-04") == "Jun 4")
        #expect(Format.shortMonthDay("2026-01-01") == "Jan 1")
        #expect(Format.shortMonthDay("2026-12-25") == "Dec 25")
    }

    @Test("returns unparseable input unchanged")
    func returnsUnparseableUnchanged() {
        #expect(Format.shortMonthDay("not-a-date") == "not-a-date")
        #expect(Format.shortMonthDay("") == "")
        #expect(Format.shortMonthDay("tomorrow") == "tomorrow")
    }
}

@Suite("Format.deltaPct")
struct FormatDeltaPctTests {
    @Test("returns nil when base is zero or negative")
    func nilWithoutBaseline() {
        #expect(Format.deltaPct(100, vs: 0) == nil)
        #expect(Format.deltaPct(100, vs: -5) == nil)
    }

    @Test("renders an up arrow for an increase")
    func upArrow() throws {
        let result = try #require(Format.deltaPct(118, vs: 100))
        #expect(result == "\u{25B2} 18%")
    }

    @Test("renders a down arrow for a decrease")
    func downArrow() throws {
        let result = try #require(Format.deltaPct(95, vs: 100))
        #expect(result == "\u{25BC} 5%")
    }

    @Test("renders an up arrow with zero percent when unchanged")
    func noChangeUsesUpArrow() throws {
        let result = try #require(Format.deltaPct(100, vs: 100))
        #expect(result == "\u{25B2} 0%")
    }

    @Test("uses the absolute value of the percentage for the magnitude")
    func absoluteMagnitude() throws {
        let result = try #require(Format.deltaPct(50, vs: 100))
        #expect(result == "\u{25BC} 50%")
    }
}
