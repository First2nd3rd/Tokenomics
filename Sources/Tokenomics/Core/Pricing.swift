import Foundation

/// Per-token USD prices for one model — the four fields LiteLLM exposes and that
/// get multiplied against token counts.
struct ModelPricing {
    let input: Double
    let output: Double
    let cacheCreation: Double
    let cacheRead: Double

    func cost(input i: Int, output o: Int, cacheCreation cc: Int, cacheRead cr: Int) -> Double {
        Double(i) * input
            + Double(o) * output
            + Double(cc) * cacheCreation
            + Double(cr) * cacheRead
    }

    func scaled(by factor: Double) -> ModelPricing {
        ModelPricing(input: input * factor,
                     output: output * factor,
                     cacheCreation: cacheCreation * factor,
                     cacheRead: cacheRead * factor)
    }
}

/// Price-table snapshot and model-resolution logic. The live table is owned by
/// `PricingStore`; this type provides the offline fallback and the lookup rules.
enum Pricing {
    /// Claude Code "Fast" mode (priority tier) is billed at a flat multiple of the
    /// base model's rates — derived empirically: claude-opus-4-7-fast equals exactly
    /// 6x opus-4-7 across all four token components. ccusage tags such turns by
    /// appending "-fast" to the model id.
    static let fastMultiplier = 6.0

    /// Offline fallback (LiteLLM rates) used before/without a live fetch, and as a
    /// floor for models not present in fetched data. PricingStore overlays the live
    /// LiteLLM table on top of this.
    static let bundledSnapshot: [String: ModelPricing] = [
        // Opus 4.7 / 4.8 — $5 / $25 / $6.25 / $0.50 per million tokens
        "claude-opus-4-8":           ModelPricing(input: 0.000005, output: 0.000025, cacheCreation: 0.00000625, cacheRead: 0.0000005),
        "claude-opus-4-7":           ModelPricing(input: 0.000005, output: 0.000025, cacheCreation: 0.00000625, cacheRead: 0.0000005),
        // Sonnet 4.6 — $3 / $15 / $3.75 / $0.30
        "claude-sonnet-4-6":         ModelPricing(input: 0.000003, output: 0.000015, cacheCreation: 0.00000375, cacheRead: 0.0000003),
        // Haiku 4.5 — $1 / $5 / $1.25 / $0.10
        "claude-haiku-4-5-20251001": ModelPricing(input: 0.000001, output: 0.000005, cacheCreation: 0.00000125, cacheRead: 0.0000001),
    ]

    /// Resolve pricing for a model id against `table`:
    ///   1. exact match
    ///   2. a `-fast` suffix → base model's pricing × `fastMultiplier`
    ///   3. the longest table key that is a prefix of the id (ccusage-style fuzzy)
    /// Returns nil for unknown models (e.g. `<synthetic>`) — caller treats as $0.
    static func resolve(_ model: String, in table: [String: ModelPricing]) -> ModelPricing? {
        if let exact = table[model] { return exact }

        if model.hasSuffix("-fast") {
            let base = String(model.dropLast("-fast".count))
            if let basePricing = resolve(base, in: table) {
                return basePricing.scaled(by: fastMultiplier)
            }
        }

        let prefixMatch = table.keys
            .filter { model.hasPrefix($0) }
            .max(by: { $0.count < $1.count })
        return prefixMatch.flatMap { table[$0] }
    }
}
