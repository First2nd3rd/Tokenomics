import Testing
import Foundation
@testable import Tokenomics

@Suite("Pricing sources")
struct PricingSourceTests {
    @Test("parseModelsDev maps per-million costs to per-token prices")
    func parseModelsDevMapsUnits() throws {
        // Arrange — models.dev shape: provider → models → id → cost (USD per 1M).
        let json = """
        {
          "anthropic": { "models": { "claude-fable-5": {
            "cost": { "input": 10, "output": 50, "cache_read": 1, "cache_write": 12.5 }
          } } },
          "openai": { "models": { "gpt-9": {
            "cost": { "input": 5, "output": 30 }
          } } },
          "openrouter": { "models": { "anthropic/claude-fable-5": {
            "cost": { "input": 99, "output": 99 }
          } } }
        }
        """

        // Act
        let table = try #require(PricingStore.parseModelsDev(Data(json.utf8)))

        // Assert — per-token, first-party providers only. Expectations are written
        // as the same division the parser performs, so they match bit-for-bit.
        let fable = try #require(table["claude-fable-5"])
        #expect(fable.input == 10.0 / 1_000_000)
        #expect(fable.output == 50.0 / 1_000_000)
        #expect(fable.cacheCreation == 12.5 / 1_000_000)
        #expect(fable.cacheRead == 1.0 / 1_000_000)
        #expect(table["gpt-9"]?.input == 5.0 / 1_000_000)
        #expect(table["anthropic/claude-fable-5"] == nil)   // aggregator skipped
        #expect(table.count == 2)
    }

    @Test("parseModelsDev skips models without a numeric input cost")
    func parseModelsDevSkipsFreeform() throws {
        let json = """
        { "anthropic": { "models": {
            "claude-something": { "cost": { "output": 5 } },
            "claude-priced":    { "cost": { "input": 3, "output": 15 } }
        } } }
        """
        let table = try #require(PricingStore.parseModelsDev(Data(json.utf8)))
        #expect(table.count == 1)
        #expect(table["claude-priced"] != nil)
    }

    @Test("layering: LiteLLM beats models.dev beats the bundled snapshot")
    func layeringPrecedence() {
        // Arrange — the same model priced differently by each source.
        let modelsDev = ["claude-opus-4-8": ModelPricing(input: 1, output: 0, cacheCreation: 0, cacheRead: 0),
                         "only-models-dev": ModelPricing(input: 2, output: 0, cacheCreation: 0, cacheRead: 0)]
        let liteLLM = ["claude-opus-4-8": ModelPricing(input: 3, output: 0, cacheCreation: 0, cacheRead: 0)]

        // Act
        let table = PricingStore.layered(modelsDev: modelsDev, liteLLM: liteLLM)

        // Assert
        #expect(table["claude-opus-4-8"]?.input == 3)            // LiteLLM wins
        #expect(table["only-models-dev"]?.input == 2)            // models.dev fills the gap
        #expect(table["claude-sonnet-4-6"]?.input == 0.000003)   // bundled floor survives
    }

    @Test("a model only in the bundled snapshot resolves, including its -fast tier")
    func bundledFableResolves() throws {
        let table = PricingStore.layered(modelsDev: [:], liteLLM: [:])

        let fable = try #require(Pricing.resolve("claude-fable-5", in: table))
        #expect(fable.input == 0.00001)

        // "-fast" = base × 6, and dated ids resolve via the prefix rule.
        let fast = try #require(Pricing.resolve("claude-fable-5-fast", in: table))
        #expect(fast.input == 0.00001 * Pricing.fastMultiplier)
        #expect(Pricing.resolve("claude-fable-5-20260601", in: table)?.input == 0.00001)
    }
}
