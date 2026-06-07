import Testing
import Foundation
@testable import Tokenomics

@Suite("CombinedProvider.merge")
struct CombinedProviderMergeTests {

    // MARK: - Helpers

    /// Builds a DailyUsage with sensible defaults so each test only states the
    /// fields it cares about. All fields here are internal (no private members).
    private func day(
        _ date: String,
        input: Int = 0,
        output: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        total: Int = 0,
        cost: Double = 0,
        models: [String] = []
    ) -> DailyUsage {
        DailyUsage(
            date: date,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            totalTokens: total,
            totalCost: cost,
            models: models
        )
    }

    // MARK: - Empty input

    @Test("returns empty array when given no lists")
    func emptyInputNoLists() {
        // Arrange / Act
        let result = CombinedProvider.merge([])

        // Assert
        #expect(result.isEmpty)
    }

    @Test("returns empty array when all lists are empty")
    func emptyInputEmptyLists() {
        // Arrange / Act
        let result = CombinedProvider.merge([[], [], []])

        // Assert
        #expect(result.isEmpty)
    }

    // MARK: - Distinct dates preserved

    @Test("preserves every distinct date across lists")
    func distinctDatesPreserved() {
        // Arrange
        let listA = [day("2026-06-05"), day("2026-06-07")]
        let listB = [day("2026-06-06")]

        // Act
        let result = CombinedProvider.merge([listA, listB])

        // Assert
        #expect(result.map(\.date) == ["2026-06-05", "2026-06-06", "2026-06-07"])
    }

    @Test("keeps a single distinct date untouched")
    func singleEntryPassthrough() {
        // Arrange
        let input = day(
            "2026-06-07",
            input: 11,
            output: 22,
            cacheCreation: 33,
            cacheRead: 44,
            total: 110,
            cost: 1.5,
            models: ["sonnet"]
        )

        // Act
        let result = CombinedProvider.merge([[input]])

        // Assert
        #expect(result.count == 1)
        let only = result.first
        #expect(only?.date == "2026-06-07")
        #expect(only?.inputTokens == 11)
        #expect(only?.outputTokens == 22)
        #expect(only?.cacheCreationTokens == 33)
        #expect(only?.cacheReadTokens == 44)
        #expect(only?.totalTokens == 110)
        #expect(only?.totalCost == 1.5)
        #expect(only?.models == ["sonnet"])
    }

    // MARK: - Ascending date order

    @Test("output is sorted ascending by date regardless of input order")
    func outputSortedAscending() {
        // Arrange: deliberately scrambled, spanning across two lists.
        let listA = [day("2026-06-10"), day("2026-06-01")]
        let listB = [day("2026-06-05"), day("2026-12-31"), day("2026-01-15")]

        // Act
        let result = CombinedProvider.merge([listA, listB])

        // Assert: lexicographic ISO-day order == chronological order.
        let dates = result.map(\.date)
        #expect(dates == ["2026-01-15", "2026-06-01", "2026-06-05", "2026-06-10", "2026-12-31"])
        #expect(dates == dates.sorted())
    }

    // MARK: - Same-date summing

    @Test("sums all token fields and cost for the same date across lists")
    func sumsTokenFieldsAndCost() throws {
        // Arrange: same date appearing in two separate lists.
        let listA = [day(
            "2026-06-07",
            input: 100,
            output: 200,
            cacheCreation: 300,
            cacheRead: 400,
            total: 1000,
            cost: 2.50
        )]
        let listB = [day(
            "2026-06-07",
            input: 1,
            output: 2,
            cacheCreation: 3,
            cacheRead: 4,
            total: 10,
            cost: 0.25
        )]

        // Act
        let result = CombinedProvider.merge([listA, listB])

        // Assert
        #expect(result.count == 1)
        let merged = try #require(result.first)
        #expect(merged.date == "2026-06-07")
        #expect(merged.inputTokens == 101)
        #expect(merged.outputTokens == 202)
        #expect(merged.cacheCreationTokens == 303)
        #expect(merged.cacheReadTokens == 404)
        #expect(merged.totalTokens == 1010)
        #expect(merged.totalCost == 2.75)
    }

    @Test("sums same-date entries that occur within a single list")
    func sumsDuplicatesWithinOneList() throws {
        // Arrange: two entries for the same date inside one list (flatMap then combine).
        let list = [
            day("2026-06-07", input: 5, total: 5, cost: 1.0),
            day("2026-06-07", input: 7, total: 7, cost: 2.0),
        ]

        // Act
        let result = CombinedProvider.merge([list])

        // Assert
        #expect(result.count == 1)
        let merged = try #require(result.first)
        #expect(merged.inputTokens == 12)
        #expect(merged.totalTokens == 12)
        #expect(merged.totalCost == 3.0)
    }

    @Test("accumulates the same date across three lists")
    func sumsAcrossThreeLists() throws {
        // Arrange
        let listA = [day("2026-06-07", total: 1, cost: 0.1)]
        let listB = [day("2026-06-07", total: 10, cost: 0.2)]
        let listC = [day("2026-06-07", total: 100, cost: 0.3)]

        // Act
        let result = CombinedProvider.merge([listA, listB, listC])

        // Assert
        #expect(result.count == 1)
        let merged = try #require(result.first)
        #expect(merged.totalTokens == 111)
        #expect(merged.totalCost == 0.1 + 0.2 + 0.3)
    }

    // MARK: - Model union + sort

    @Test("unions and sorts models for the same date, de-duplicating overlaps")
    func unionsAndSortsModels() throws {
        // Arrange: overlapping ("sonnet") plus distinct models, intentionally unsorted.
        let listA = [day("2026-06-07", models: ["sonnet", "opus"])]
        let listB = [day("2026-06-07", models: ["sonnet", "haiku", "codex"])]

        // Act
        let result = CombinedProvider.merge([listA, listB])

        // Assert: set union, then ascending sort; "sonnet" appears once.
        let merged = try #require(result.first)
        #expect(merged.models == ["codex", "haiku", "opus", "sonnet"])
    }

    @Test("keeps a single date's model list when only one list contributes it")
    func modelsPreservedForUnmergedDate() throws {
        // Arrange: this date exists only in one list, so combine is never called.
        let listA = [day("2026-06-06", models: ["opus", "sonnet"])]
        let listB = [day("2026-06-07", models: ["codex"])]

        // Act
        let result = CombinedProvider.merge([listA, listB])

        // Assert: untouched dates retain their original models verbatim.
        let first = try #require(result.first { $0.date == "2026-06-06" })
        #expect(first.models == ["opus", "sonnet"])
    }

    // MARK: - Combined behavior

    @Test("merges overlapping dates while preserving distinct ones, all sorted")
    func mixedOverlapAndDistinct() throws {
        // Arrange
        let listA = [
            day("2026-06-07", total: 100, cost: 1.0, models: ["opus"]),
            day("2026-06-05", total: 50, cost: 0.5, models: ["haiku"]),
        ]
        let listB = [
            day("2026-06-07", total: 1, cost: 0.01, models: ["sonnet"]),
            day("2026-06-06", total: 9, cost: 0.09, models: ["codex"]),
        ]

        // Act
        let result = CombinedProvider.merge([listA, listB])

        // Assert: three distinct dates, ascending order.
        #expect(result.map(\.date) == ["2026-06-05", "2026-06-06", "2026-06-07"])

        // The overlapping date (06-07) is summed and its models unioned + sorted.
        let overlap = try #require(result.first { $0.date == "2026-06-07" })
        #expect(overlap.totalTokens == 101)
        #expect(overlap.totalCost == 1.01)
        #expect(overlap.models == ["opus", "sonnet"])

        // Distinct dates pass through unchanged.
        let distinct = try #require(result.first { $0.date == "2026-06-05" })
        #expect(distinct.totalTokens == 50)
        #expect(distinct.models == ["haiku"])
    }
}
