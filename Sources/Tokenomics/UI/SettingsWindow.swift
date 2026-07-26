import SwiftUI

/// The unified settings window (System Settings style): a sidebar of panes on the
/// left, each pane a grouped Form on the right. Settings and usage statistics both
/// live here — menu items deep-link to a pane via `SettingsPaneModel`.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, statistics, data, subscription, about

    /// Identity must be Self: `List(selection:)` binds a `SettingsPane?`, and rows
    /// are tagged with `id` — a String id would compile but never match, leaving
    /// sidebar clicks dead.
    var id: SettingsPane { self }

    var title: String {
        switch self {
        case .general:      return "General"
        case .statistics:   return "Statistics"
        case .data:         return "Data & Sync"
        case .subscription: return "Subscription"
        case .about:        return "About"
        }
    }

    /// Sidebar icon: SF Symbol on a tinted rounded square, System Settings style.
    var symbol: String {
        switch self {
        case .general:      return "gearshape.fill"
        case .statistics:   return "chart.bar.fill"
        case .data:         return "arrow.triangle.2.circlepath"
        case .subscription: return "creditcard.fill"
        case .about:        return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general:      return .gray
        case .statistics:   return .blue
        case .data:         return .green
        case .subscription: return .purple
        case .about:        return .teal
        }
    }
}

/// Sidebar selection, owned by AppDelegate so the menu-bar items ("Settings…",
/// "Statistics…") can open the window on a specific pane.
final class SettingsPaneModel: ObservableObject {
    @Published var pane: SettingsPane = .general
}

/// One place for the window's fixed geometry — panes that draw at explicit widths
/// (the statistics charts) derive from these instead of re-hardcoding them.
enum SettingsWindowMetrics {
    static let width: CGFloat = 780
    static let height: CGFloat = 640
    static let sidebarWidth: CGFloat = 198
    /// Width available to section content in the detail column: width − sidebar,
    /// minus the grouped form's outer margins and section padding (~92 pt).
    static let detailContentWidth: CGFloat = 490
}

struct SettingsRootView: View {
    @ObservedObject var panes: SettingsPaneModel
    @ObservedObject var login: LoginItemModel
    @ObservedObject var report: ReportModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    Image(systemName: pane.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(pane.tint.gradient)
                        )
                }
                .padding(.vertical, 1)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(SettingsWindowMetrics.sidebarWidth)
        } detail: {
            detail.navigationTitle(panes.pane.title)
        }
        .frame(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.height)
    }

    /// List selection is optional; ignore deselection so a pane is always shown.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { panes.pane }, set: { if let pane = $0 { panes.pane = pane } })
    }

    @ViewBuilder private var detail: some View {
        switch panes.pane {
        case .general:      GeneralPane(login: login)
        case .statistics:   ReportView(model: report)
        case .data:         DataPane()
        case .subscription: SubscriptionPane()
        case .about:        AboutPane()
        }
    }
}
