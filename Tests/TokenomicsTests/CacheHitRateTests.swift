import Testing
import Foundation
@testable import Tokenomics

@Suite("Cache hit rate")
struct CacheHitRateTests {
    private func du(input: Int = 0, output: Int = 0, write: Int = 0, read: Int = 0,
                    date: String = "2026-08-01") -> DailyUsage {
        DailyUsage(date: date, inputTokens: input, outputTokens: output,
                   cacheCreationTokens: write, cacheReadTokens: read,
                   totalTokens: input + output + write + read, totalCost: 0, models: [])
    }

    @Test("rate is cache reads over the prompt side, output excluded")
    func perDayRate() {
        #expect(du(input: 10, output: 500, write: 10, read: 80).cacheHitRate == 0.8)
        #expect(du(input: 100, output: 100).cacheHitRate == 0)
        #expect(du(read: 100).cacheHitRate == 1)
    }

    @Test("a day with no prompt side has no rate")
    func noPromptSide() {
        #expect(du(output: 500).cacheHitRate == nil)
        #expect(du().cacheHitRate == nil)
        #expect(du(output: 500).promptTokens == 0)
    }

    @Test("the aggregate is prompt-weighted, not a mean of daily rates")
    func weightedAggregate() {
        let days = [
            du(input: 900, read: 100, date: "2026-08-01"),      // 10% on a big day
            du(input: 0, read: 100, date: "2026-08-02"),        // 100% on a tiny day
        ]
        // Σreads ÷ Σprompt = 200 / 1100, nowhere near mean(10%, 100%) = 55%.
        let rate = DailyUsage.cacheHitRate(across: days)!
        #expect(abs(rate - 200.0 / 1100.0) < 0.0001)
    }

    @Test("an output-only period has no aggregate rate")
    func emptyAggregate() {
        #expect(DailyUsage.cacheHitRate(across: []) == nil)
        #expect(DailyUsage.cacheHitRate(across: [du(output: 5)]) == nil)
    }

    @Test("percent formats a fraction as a whole percent")
    func percentFormat() {
        #expect(Format.percent(0.874) == "87%")
        #expect(Format.percent(1.0) == "100%")
        #expect(Format.percent(0) == "0%")
    }
}

@Suite("Rate axis floor")
struct RateAxisFloorTests {
    @Test("floor tracks the 10th percentile, not the minimum")
    func percentileFloor() {
        // An August-like month: rates cluster 88–99% with one collapsed day.
        let rates = [0.073, 0.88, 0.893, 0.934, 0.936, 0.946, 0.95, 0.953, 0.956,
                     0.956, 0.962, 0.963, 0.964, 0.967, 0.967, 0.967, 0.969,
                     0.974, 0.975, 0.977, 0.982, 0.989]
        #expect(ChartKit.rateAxisFloor(rates) == 0.8)   // p10 ≈ 0.893 → 0.8, outlier ignored
    }

    @Test("a uniformly high month caps the floor at 0.9")
    func highMonth() {
        #expect(ChartKit.rateAxisFloor([0.97, 0.98, 0.99, 1.0]) == 0.9)
        #expect(ChartKit.rateAxisFloor([]) == 0.9)
    }

    @Test("a genuinely low month keeps its band visible")
    func lowMonth() {
        #expect(ChartKit.rateAxisFloor([0.55, 0.6, 0.65, 0.7, 0.72, 0.75, 0.8, 0.82, 0.85, 0.9]) == 0.5)
    }
}
