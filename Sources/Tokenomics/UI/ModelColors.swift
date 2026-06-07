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

    /// Ordered model→color, grouped by vendor (same hue, brightness descending),
    /// which also defines the stack order and legend order.
    static func assign(_ models: [String]) -> [Entry] {
        let groups = Dictionary(grouping: Set(models)) { hue(for: $0) }
        var entries: [Entry] = []
        for hue in groups.keys.sorted() {
            let vendorModels = groups[hue]!.sorted()
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
