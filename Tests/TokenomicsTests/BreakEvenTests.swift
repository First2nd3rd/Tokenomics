import Testing
import Foundation
@testable import Tokenomics

/// Tests for `BreakEven.compute(perVendor:now:claude:gpt:calendar:)`.
///
/// Determinism: every test builds its own UTC gregorian calendar and a fixed
/// `now`, then passes literal day-keyed `DailyUsage.date` strings ("yyyy-MM-dd")
/// that it controls. `compute` derives the "current month" prefix from `now`
/// via the supplied calendar, so nothing depends on the host machine's clock
/// or timezone. Tests are stateless and safe to run in parallel.
@Suite("BreakEven")
struct BreakEvenTests {

    // MARK: - Helpers

    /// A UTC gregorian calendar so month derivation is timezone-independent.
    private static func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// A deterministic `Date` in UTC. Used only to set the "current month".
    private static func date(_ cal: Calendar,
                             _ year: Int, _ month: Int, _ day: Int,
                             hour: Int = 12) -> Date {
        DateComponents(calendar: cal, timeZone: TimeZone(identifier: "UTC")!,
                       year: year, month: month, day: day, hour: hour).date!
    }

    /// A `DailyUsage` carrying only the fields BreakEven reads (`date`,
    /// `totalCost`); other token fields are filled with placeholder values.
    private static func usage(_ date: String, cost: Double) -> DailyUsage {
        DailyUsage(date: date,
                   inputTokens: 0,
                   outputTokens: 0,
                   cacheCreationTokens: 0,
                   cacheReadTokens: 0,
                   totalTokens: 0,
                   totalCost: cost,
                   models: [])
    }

    /// Provider id for Claude's daily series, per `Vendor.claude.providerID`.
    private static let claudeID = "claude-native"
    /// Provider id for GPT's daily series, per `Vendor.gpt.providerID`.
    private static let codexID = "codex"

    // MARK: - monthToDateCost sums only the current-month days

    @Test("monthToDateCost sums only the current calendar month's days")
    func monthToDateSumsCurrentMonthOnly() throws {
        // Arrange: now is June 2026; days span May, June, and July.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 15)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-05-31", cost: 100), // previous month -> excluded
                Self.usage("2026-06-01", cost: 10),
                Self.usage("2026-06-10", cost: 5),
                Self.usage("2026-06-15", cost: 2.5),
                Self.usage("2026-07-01", cost: 50)   // next month -> excluded
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .api, gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert: only the three June days are summed (10 + 5 + 2.5).
        #expect(claude.monthToDateCost == 17.5)
    }

    @Test("days from other months are excluded even when basis is subscription")
    func otherMonthsExcludedUnderSubscription() throws {
        // Arrange: a huge previous-month cost must not count toward this month.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-05-15", cost: 999),
                Self.usage("2026-06-03", cost: 8)
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert: only June is counted; break-even not reached on 8 vs 20.
        #expect(claude.monthToDateCost == 8)
        #expect(claude.brokeEvenOn == nil)
    }

    // MARK: - multiple = cost / fee; progress capped at 1

    @Test("multiple equals monthToDateCost divided by the monthly fee")
    func multipleIsCostOverFee() throws {
        // Arrange: $30 spent against a $20 subscription -> 1.5x.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-06-02", cost: 10),
                Self.usage("2026-06-04", cost: 20)
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert
        let multiple = try #require(claude.multiple)
        #expect(multiple == 1.5)
    }

    @Test("progress caps at 1 once cost exceeds the fee")
    func progressCapsAtOne() throws {
        // Arrange: well past break-even (multiple = 5x).
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [Self.usage("2026-06-01", cost: 100)]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert: multiple is 5 but progress is clamped to 1.
        #expect(try #require(claude.multiple) == 5)
        #expect(try #require(claude.progress) == 1.0)
    }

    @Test("progress is the raw ratio while still below break-even")
    func progressBelowOne() throws {
        // Arrange: $5 spent against a $20 fee -> 0.25.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [Self.usage("2026-06-01", cost: 5)]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert
        #expect(try #require(claude.progress) == 0.25)
    }

    // MARK: - brokeEvenOn: first day the running cumulative reaches the fee

    @Test("brokeEvenOn is the first day cumulative cost reaches the fee")
    func brokeEvenOnFirstReachingDay() throws {
        // Arrange: days deliberately out of order so the .sorted ascending
        // ordering inside compute is exercised. Cumulative by date:
        //   06-02: 8, 06-05: 16, 06-09: 24 (reaches 20 here).
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 30)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-06-09", cost: 8),
                Self.usage("2026-06-02", cost: 8),
                Self.usage("2026-06-05", cost: 8)
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert: 8 + 8 = 16 < 20, then + 8 = 24 >= 20 on 06-09.
        #expect(claude.brokeEvenOn == "2026-06-09")
        #expect(claude.monthToDateCost == 24)
    }

    @Test("brokeEvenOn is nil when cumulative cost never reaches the fee")
    func brokeEvenOnNilWhenNeverReached() throws {
        // Arrange: total $12 stays under the $20 fee.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 30)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-06-03", cost: 7),
                Self.usage("2026-06-20", cost: 5)
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert
        #expect(claude.brokeEvenOn == nil)
        #expect(claude.monthToDateCost == 12)
    }

    @Test("brokeEvenOn is the first day when that day alone already exceeds the fee")
    func brokeEvenOnFirstDayWhenItAlreadyExceeds() throws {
        // Arrange: the earliest day's cost already passes the fee on its own.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-06-01", cost: 50), // earliest, already > 20
                Self.usage("2026-06-02", cost: 10)
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert: break-even lands on the first day, not a later one.
        #expect(claude.brokeEvenOn == "2026-06-01")
    }

    @Test("brokeEvenOn equals the day cumulative exactly equals the fee")
    func brokeEvenOnExactBoundary() throws {
        // Arrange: cumulative hits exactly the fee on 06-04 (>= comparison).
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-06-02", cost: 12),
                Self.usage("2026-06-04", cost: 8) // 12 + 8 == 20
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert
        #expect(claude.brokeEvenOn == "2026-06-04")
    }

    // MARK: - .api basis behavior

    @Test("API basis yields nil multiple, fee, and brokeEvenOn but still sums cost")
    func apiBasisNoBreakEvenButCostSummed() throws {
        // Arrange: API pay-as-you-go has no fee to break even against.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [
                Self.usage("2026-06-01", cost: 3),
                Self.usage("2026-06-05", cost: 4)
            ]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .api, gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert: no break-even math, but month-to-date cost is still accrued.
        #expect(claude.multiple == nil)
        #expect(claude.monthlyFee == nil)
        #expect(claude.brokeEvenOn == nil)
        #expect(claude.progress == nil)
        #expect(claude.monthToDateCost == 7)
    }

    // MARK: - per-vendor routing & defaults

    @Test("compute keys each vendor by its providerID and returns both vendors")
    func vendorRoutingByProviderID() throws {
        // Arrange: distinct cost streams under each provider id.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [Self.usage("2026-06-01", cost: 30)],
            Self.codexID: [Self.usage("2026-06-01", cost: 25)]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .subscription(monthlyUSD: 20),
                                       calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })
        let gpt = try #require(result.first { $0.vendor == .gpt })

        // Assert: each vendor draws from its own providerID series.
        #expect(result.count == 2)
        #expect(claude.monthToDateCost == 30)
        #expect(gpt.monthToDateCost == 25)
        #expect(claude.brokeEvenOn == "2026-06-01")
        #expect(gpt.brokeEvenOn == "2026-06-01")
    }

    @Test("a vendor with no matching providerID entry has zero cost and no break-even")
    func missingVendorSeriesIsEmpty() throws {
        // Arrange: only Claude has data; GPT's providerID is absent.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [Self.usage("2026-06-01", cost: 5)]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 20),
                                       gpt: .subscription(monthlyUSD: 20),
                                       calendar: cal)
        let gpt = try #require(result.first { $0.vendor == .gpt })

        // Assert
        #expect(gpt.monthToDateCost == 0)
        #expect(gpt.brokeEvenOn == nil)
    }

    @Test("a zero monthly fee subscription produces nil multiple and no break-even")
    func zeroFeeSubscriptionHasNoMultiple() throws {
        // Arrange: guard `fee > 0` means a $0 subscription behaves like no fee.
        let cal = Self.utcCalendar()
        let now = Self.date(cal, 2026, 6, 7)
        let perVendor: [String: [DailyUsage]] = [
            Self.claudeID: [Self.usage("2026-06-01", cost: 10)]
        ]

        // Act
        let result = BreakEven.compute(perVendor: perVendor, now: now,
                                       claude: .subscription(monthlyUSD: 0),
                                       gpt: .api, calendar: cal)
        let claude = try #require(result.first { $0.vendor == .claude })

        // Assert: cost is still summed, but no break-even is computed.
        #expect(claude.monthToDateCost == 10)
        #expect(claude.multiple == nil)
        #expect(claude.brokeEvenOn == nil)
    }
}
