import Testing
import Foundation
@testable import Tokenomics

@Suite("TokenCounts")
struct TokenCountsTests {

    // MARK: - total

    @Test("total sums all four token components")
    func totalSumsComponents() {
        // Arrange
        let counts = TokenCounts(input: 1, output: 2, cacheCreation: 4, cacheRead: 8)

        // Act
        let total = counts.total

        // Assert
        #expect(total == 15)
    }

    @Test("total is zero for a default-initialized TokenCounts")
    func totalDefaultsToZero() {
        // Arrange
        let counts = TokenCounts()

        // Act / Assert
        #expect(counts.total == 0)
    }

    // MARK: - add(input:output:cacheCreation:cacheRead:)

    @Test("add(input:output:cacheCreation:cacheRead:) accumulates each field")
    func addFieldsAccumulates() {
        // Arrange
        var counts = TokenCounts(input: 10, output: 20, cacheCreation: 30, cacheRead: 40)

        // Act
        counts.add(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)

        // Assert
        #expect(counts.input == 11)
        #expect(counts.output == 22)
        #expect(counts.cacheCreation == 33)
        #expect(counts.cacheRead == 44)
        #expect(counts.total == 110)
    }

    @Test("add(input:output:cacheCreation:cacheRead:) starting from zero sets the fields")
    func addFieldsFromZero() {
        // Arrange
        var counts = TokenCounts()

        // Act
        counts.add(input: 5, output: 6, cacheCreation: 7, cacheRead: 8)

        // Assert
        #expect(counts.input == 5)
        #expect(counts.output == 6)
        #expect(counts.cacheCreation == 7)
        #expect(counts.cacheRead == 8)
    }

    // MARK: - add(_ other:)

    @Test("add(_ other:) merges another TokenCounts component-wise")
    func addOtherMerges() {
        // Arrange
        var base = TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        let other = TokenCounts(input: 10, output: 20, cacheCreation: 30, cacheRead: 40)

        // Act
        base.add(other)

        // Assert
        #expect(base.input == 11)
        #expect(base.output == 22)
        #expect(base.cacheCreation == 33)
        #expect(base.cacheRead == 44)
        #expect(base.total == 110)
    }

    @Test("add(_ other:) leaves the merged-in value untouched")
    func addOtherDoesNotMutateSource() {
        // Arrange
        var base = TokenCounts(input: 1, output: 1, cacheCreation: 1, cacheRead: 1)
        let other = TokenCounts(input: 2, output: 2, cacheCreation: 2, cacheRead: 2)

        // Act
        base.add(other)

        // Assert
        #expect(other.input == 2)
        #expect(other.output == 2)
        #expect(other.cacheCreation == 2)
        #expect(other.cacheRead == 2)
    }
}

@Suite("MinuteBucket")
struct MinuteBucketTests {

    // MARK: - add(input:output:cacheCreation:cacheRead:model:)

    @Test("add with a model updates counts and records the model's total in byModel")
    func addWithModelUpdatesCountsAndByModel() {
        // Arrange
        var bucket = MinuteBucket()

        // Act
        bucket.add(input: 1, output: 2, cacheCreation: 3, cacheRead: 4, model: "opus")

        // Assert
        #expect(bucket.counts.input == 1)
        #expect(bucket.counts.output == 2)
        #expect(bucket.counts.cacheCreation == 3)
        #expect(bucket.counts.cacheRead == 4)
        #expect(bucket.byModel["opus"] == 10)
    }

    @Test("add with model nil updates counts but creates no byModel entry")
    func addWithNilModelLeavesByModelEmpty() {
        // Arrange
        var bucket = MinuteBucket()

        // Act
        bucket.add(input: 5, output: 6, cacheCreation: 7, cacheRead: 8, model: nil)

        // Assert
        #expect(bucket.counts.total == 26)
        #expect(bucket.byModel.isEmpty)
    }

    @Test("repeated add calls for the same model accumulate that model's total")
    func addSameModelAccumulates() {
        // Arrange
        var bucket = MinuteBucket()

        // Act
        bucket.add(input: 1, output: 1, cacheCreation: 1, cacheRead: 1, model: "sonnet")
        bucket.add(input: 2, output: 0, cacheCreation: 0, cacheRead: 0, model: "sonnet")

        // Assert
        #expect(bucket.byModel["sonnet"] == 6)
        #expect(bucket.counts.input == 3)
    }

    @Test("add calls for distinct models keep separate byModel totals")
    func addDistinctModelsTrackedSeparately() {
        // Arrange
        var bucket = MinuteBucket()

        // Act
        bucket.add(input: 1, output: 0, cacheCreation: 0, cacheRead: 0, model: "opus")
        bucket.add(input: 0, output: 2, cacheCreation: 0, cacheRead: 0, model: "haiku")

        // Assert
        #expect(bucket.byModel["opus"] == 1)
        #expect(bucket.byModel["haiku"] == 2)
        #expect(bucket.byModel.count == 2)
    }

    // MARK: - add(_ other:)

    @Test("add(_ other:) merges both counts and byModel")
    func addOtherMergesCountsAndByModel() {
        // Arrange
        var base = MinuteBucket()
        base.add(input: 1, output: 1, cacheCreation: 1, cacheRead: 1, model: "opus")

        var other = MinuteBucket()
        other.add(input: 2, output: 2, cacheCreation: 2, cacheRead: 2, model: "opus")
        other.add(input: 3, output: 0, cacheCreation: 0, cacheRead: 0, model: "haiku")

        // Act
        base.add(other)

        // Assert
        #expect(base.counts.input == 6)   // 1 (base) + 2 + 3 (other: opus + haiku)
        #expect(base.counts.output == 3)
        #expect(base.counts.cacheCreation == 3)
        #expect(base.counts.cacheRead == 3)
        #expect(base.byModel["opus"] == 12)   // 4 from base + 8 from other
        #expect(base.byModel["haiku"] == 3)
    }

    @Test("add(_ other:) with disjoint models keeps each model entry")
    func addOtherDisjointModels() {
        // Arrange
        var base = MinuteBucket()
        base.add(input: 1, output: 0, cacheCreation: 0, cacheRead: 0, model: "opus")

        var other = MinuteBucket()
        other.add(input: 0, output: 5, cacheCreation: 0, cacheRead: 0, model: "sonnet")

        // Act
        base.add(other)

        // Assert
        #expect(base.byModel["opus"] == 1)
        #expect(base.byModel["sonnet"] == 5)
        #expect(base.byModel.count == 2)
    }
}

@Suite("DailyUsage.counts")
struct DailyUsageCountsTests {

    @Test("counts maps the four token fields into TokenCounts and ignores totalTokens")
    func countsMapsTokenFields() {
        // Arrange
        let usage = DailyUsage(
            date: "2026-06-07",
            inputTokens: 100,
            outputTokens: 200,
            cacheCreationTokens: 300,
            cacheReadTokens: 400,
            totalTokens: 9999,   // deliberately inconsistent: counts must use the four fields
            totalCost: 1.23,
            models: ["opus"]
        )

        // Act
        let counts = usage.counts

        // Assert
        #expect(counts.input == 100)
        #expect(counts.output == 200)
        #expect(counts.cacheCreation == 300)
        #expect(counts.cacheRead == 400)
        #expect(counts.total == 1000)
    }

    @Test("counts is all-zero when the day has no token usage")
    func countsZeroForEmptyDay() {
        // Arrange
        let usage = DailyUsage(
            date: "2026-06-07",
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: 0,
            totalCost: 0,
            models: []
        )

        // Act
        let counts = usage.counts

        // Assert
        #expect(counts.total == 0)
    }
}
