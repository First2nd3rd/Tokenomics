import SwiftUI

/// Assigns a color to each model: same vendor → same hue with different shades,
/// different vendors → different hues.
enum ModelColors {
    struct Entry: Identifiable {
        let model: String
        let color: Color
        var id: String { model }
    }

    /// Base hue (0…1) per vendor, inferred from the model id.
    private static func hue(for model: String) -> Double {
        if model.hasPrefix("claude") { return 0.07 }                       // Anthropic — orange
        if model.hasPrefix("gpt") || model.contains("codex") { return 0.47 } // OpenAI — teal
        return 0.78                                                         // other — purple
    }

    /// Brightness is a fixed LADDER indexed by price rank — never stretched across
    /// however many models happen to be present. Each rank descends TWO base steps
    /// (0.26), landing three concurrent models on 0.90 / 0.64 / 0.46 — maximum
    /// contrast for the usual ≤3-models-per-vendor case — and a newly-arrived
    /// pricier model shifts the others down a rank rather than re-spreading
    /// everyone. Ranks past the floor all clamp there.
    private static let topBrightness = 0.90
    private static let brightnessStep = 0.26
    private static let floorBrightness = 0.46

    /// Ordered model→color, grouped by vendor (same hue) and shaded by PRICE within
    /// the vendor: the priciest model takes the top of the brightness ladder, each
    /// next rank one step darker, so shade rank reads as price rank. Ties break by
    /// name (newer-looking ids lighter); unpriced models sort to the darkest end.
    /// The order also defines the stack order and legend order.
    static func assign(_ models: [String],
                       price: (String) -> Double = { PricingStore.shared.pricing(for: $0)?.input ?? 0 }) -> [Entry] {
        let groups = Dictionary(grouping: Set(models)) { hue(for: $0) }
        var entries: [Entry] = []
        for hue in groups.keys.sorted() {
            let vendorModels = groups[hue]!.sorted { a, b in
                let pa = price(a), pb = price(b)
                if pa != pb { return pa > pb }
                return a > b
            }
            for (i, model) in vendorModels.enumerated() {
                let brightness = max(floorBrightness, topBrightness - brightnessStep * Double(i))
                entries.append(Entry(model: model, color: Color(hue: hue, saturation: 0.72, brightness: brightness)))
            }
        }
        return entries
    }

    /// Representative color for a vendor/model hue, matching the by-model chart's
    /// top-rank shade (what `assign` gives a vendor's first model), so other
    /// surfaces can color-match the chart.
    static func color(for model: String) -> Color {
        Color(hue: hue(for: model), saturation: 0.72, brightness: topBrightness)
    }

    /// A compact label for legends: drop the `claude-` prefix and trailing date.
    static func shortName(_ model: String) -> String {
        var name = model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
        if let range = name.range(of: "-20[0-9]{6}$", options: .regularExpression) {
            name.removeSubrange(range)
        }
        return name
    }
}
