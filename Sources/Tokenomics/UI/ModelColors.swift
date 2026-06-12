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

    /// Ordered model→color, grouped by vendor (same hue) and shaded by PRICE within
    /// the vendor: the priciest model gets the lightest shade, descending from
    /// there, so shade rank reads as price rank. Ties break by name (newer-looking
    /// ids lighter); unpriced models sort to the darkest end. The order also
    /// defines the stack order and legend order.
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
            let count = vendorModels.count
            for (i, model) in vendorModels.enumerated() {
                let brightness = count <= 1 ? 0.82 : 0.92 - 0.46 * (Double(i) / Double(count - 1))
                entries.append(Entry(model: model, color: Color(hue: hue, saturation: 0.72, brightness: brightness)))
            }
        }
        return entries
    }

    /// Representative color for a vendor/model hue, matching the by-model chart's
    /// single-model shade (same saturation/brightness `assign` uses when a vendor has
    /// one model), so other surfaces can color-match the chart.
    static func color(for model: String) -> Color {
        Color(hue: hue(for: model), saturation: 0.72, brightness: 0.82)
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
