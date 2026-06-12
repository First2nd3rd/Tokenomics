import Testing
import Foundation
@testable import Tokenomics

@Suite("ModelColors")
struct ModelColorsTests {
    /// Per-token input prices used as the injected lookup (per-M for readability).
    private static let prices: [String: Double] = [
        "claude-fable-5":    10.0 / 1_000_000,
        "claude-opus-4-8":    5.0 / 1_000_000,
        "claude-opus-4-7":    5.0 / 1_000_000,
        "claude-sonnet-4-6":  3.0 / 1_000_000,
        "gpt-5.5":            5.0 / 1_000_000,
        "codex-auto-review":  0,               // unpriced → darkest
    ]
    private static func price(_ model: String) -> Double { prices[model] ?? 0 }

    @Test("within a vendor, the priciest model is first (lightest)")
    func priceOrdering() {
        let entries = ModelColors.assign(
            ["claude-sonnet-4-6", "claude-fable-5", "claude-opus-4-8"], price: Self.price)

        #expect(entries.map(\.model) == ["claude-fable-5", "claude-opus-4-8", "claude-sonnet-4-6"])
    }

    @Test("equal prices break ties by name, newer-looking id lighter")
    func tieBreak() {
        let entries = ModelColors.assign(
            ["claude-opus-4-7", "claude-opus-4-8"], price: Self.price)

        #expect(entries.map(\.model) == ["claude-opus-4-8", "claude-opus-4-7"])
    }

    @Test("unpriced models sort to the darkest end of their vendor")
    func unpricedDarkest() {
        let entries = ModelColors.assign(
            ["codex-auto-review", "gpt-5.5"], price: Self.price)

        #expect(entries.map(\.model) == ["gpt-5.5", "codex-auto-review"])
    }

    @Test("vendors stay grouped: all claude entries precede all gpt entries")
    func vendorGrouping() {
        let entries = ModelColors.assign(
            ["gpt-5.5", "claude-fable-5", "claude-sonnet-4-6"], price: Self.price)

        let vendors = entries.map { $0.model.hasPrefix("claude") }
        #expect(vendors == [true, true, false])
        // And within claude, price order still holds.
        #expect(entries[0].model == "claude-fable-5")
    }

    @Test("shortName strips the claude prefix and trailing date")
    func shortName() {
        #expect(ModelColors.shortName("claude-haiku-4-5-20251001") == "haiku-4-5")
        #expect(ModelColors.shortName("gpt-5.5") == "gpt-5.5")
    }
}
