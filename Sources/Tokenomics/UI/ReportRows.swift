import SwiftUI

/// Row and caption pieces shared by the period report and the all-time overview.

/// Per-vendor rows: name, tokens, cost, and a share bar in the vendor's hue.
struct VendorRows: View {
    let vendors: [VendorUsage]
    let width: CGFloat

    var body: some View {
        let maxTokens = vendors.map(\.tokens).max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            ForEach(vendors) { v in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(v.vendor).font(.caption).fontWeight(.medium)
                        Spacer()
                        Text(Format.tokensShort(v.tokens)).font(.caption).foregroundStyle(.secondary)
                        Text(Format.cost(v.cost)).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    ChartKit.proportionBar(
                        fraction: maxTokens > 0 ? Double(v.tokens) / Double(maxTokens) : 0,
                        color: Self.color(for: v.vendor), width: width)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Match the dashboard's vendor palette (Claude orange, GPT teal, WorkBuddy purple).
    static func color(for vendor: String) -> Color {
        let match = Vendor.allCases.first { $0.displayName == vendor }
        return ModelColors.color(for: match?.representativeModel ?? "other")
    }
}

/// Per-model rows: top 8 by tokens plus an aggregated "Other" tail.
struct ModelRows: View {
    let models: [ModelUsage]
    let width: CGFloat

    var body: some View {
        let top = Array(models.prefix(8))
        let rest = models.dropFirst(8)
        let restTokens = rest.reduce(0) { $0 + $1.tokens }
        let restCost = rest.reduce(0.0) { $0 + $1.cost }
        let maxTokens = models.map(\.tokens).max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            ForEach(top) { m in row(ModelColors.shortName(m.model), m.tokens, m.cost, max: maxTokens) }
            if restTokens > 0 { row("Other", restTokens, restCost, max: maxTokens) }
        }
        .padding(.vertical, 2)
    }

    private func row(_ name: String, _ tokens: Int, _ cost: Double, max maxTokens: Int) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).frame(width: 120, alignment: .leading)
            ChartKit.proportionBar(fraction: maxTokens > 0 ? Double(tokens) / Double(maxTokens) : 0,
                                   color: .accentColor, width: width - 120 - 72 - 64)
            Spacer(minLength: 0)
            Text(Format.tokensShort(tokens)).font(.caption).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(Format.cost(cost)).font(.caption).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

/// The report's standing caveats (scope + price freshness), shown under whichever
/// section leads the page.
struct ReportCaveats: View {
    let syncOn: Bool
    let pricesFrozen: Bool

    var body: some View {
        if syncOn {
            Text("This Mac only — excludes the other Macs shown on the dashboard.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if !pricesFrozen {
            Text("Costs estimated at current prices.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
