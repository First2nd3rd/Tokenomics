import Testing
import Foundation
import SwiftUI
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

    /// The color `assign` produces for a given hue + ladder rank.
    private func ladderColor(hue: Double, rank: Int) -> Color {
        Color(hue: hue, saturation: 0.72, brightness: max(0.46, 0.90 - 0.26 * Double(rank)))
    }

    @Test("two models take ADJACENT ladder steps, not the two extremes")
    func adjacentSteps() {
        let entries = ModelColors.assign(
            ["claude-opus-4-8", "claude-fable-5"], price: Self.price)

        // Fable (pricier) top rank; Opus one RANK (two base steps) darker.
        #expect(entries[0].color == ladderColor(hue: 0.07, rank: 0))
        #expect(entries[1].color == ladderColor(hue: 0.07, rank: 1))
    }

    @Test("a newly-arrived pricier model shifts the others down one step")
    func rankShift() {
        let alone = ModelColors.assign(["claude-opus-4-8"], price: Self.price)
        #expect(alone[0].color == ladderColor(hue: 0.07, rank: 0))     // alone → top step

        let joined = ModelColors.assign(
            ["claude-opus-4-8", "claude-fable-5"], price: Self.price)
        #expect(joined[0].model == "claude-fable-5")
        #expect(joined[0].color == ladderColor(hue: 0.07, rank: 0))    // newcomer takes the top
        #expect(joined[1].color == ladderColor(hue: 0.07, rank: 1))    // opus: one rank down
    }

    @Test("ranks past the ladder floor clamp instead of going negative")
    func floorClamp() {
        let many = (0..<8).map { "claude-model-\($0)" }
        let entries = ModelColors.assign(many) { _ in 0 }
        #expect(entries.last?.color == Color(hue: 0.07, saturation: 0.72, brightness: 0.46))
    }

    @Test("shortName strips the claude prefix and trailing date")
    func shortName() {
        #expect(ModelColors.shortName("claude-haiku-4-5-20251001") == "haiku-4-5")
        #expect(ModelColors.shortName("gpt-5.5") == "gpt-5.5")
    }
}
