import SwiftUI
import ServiceManagement

/// How the intraday rate chart is drawn. Persisted via @AppStorage.
enum RateChartStyle: String, CaseIterable, Identifiable {
    case line, stacked, model
    var id: String { rawValue }
    var label: String {
        switch self {
        case .line: return "Line"
        case .stacked: return "Stacked by type"
        case .model: return "Stacked by model"
        }
    }
}

/// Backs the "Launch at Login" toggle via SMAppService (macOS 13+). Registering
/// adds the app to System Settings → General → Login Items, where the user can
/// also turn it off. Used only from the main thread (AppDelegate / SwiftUI).
final class LoginItemModel: ObservableObject {
    @Published var enabled = false

    init() { refresh() }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            // Registration can fail (e.g. app not in /Applications); fall through
            // and reflect whatever the real status is.
        }
        refresh()
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var login: LoginItemModel
    @AppStorage("menuBarIcon") private var menuBarIcon: MenuBarIcon = .solid
    @AppStorage("rateChartStyle") private var rateStyle: RateChartStyle = .line

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login",
                       isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
            } footer: {
                Text("Start Tokenomics automatically when you log in.")
            }

            Section {
                Picker("Menu bar icon", selection: $menuBarIcon) {
                    ForEach(MenuBarIcon.allCases) { Text($0.label).tag($0) }
                }
                Picker("Rate chart", selection: $rateStyle) {
                    ForEach(RateChartStyle.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("The cube mark shown in the menu bar, and how the dashboard's intraday usage chart is drawn.")
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

// MARK: - Data & Sync

struct DataPane: View {
    @AppStorage("syncEnabled") private var syncEnabled = false
    @AppStorage(DeviceIdentity.displayNameKey) private var machineName = ""
    @AppStorage("archiveEnabled") private var archiveEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Sync across Macs", isOn: $syncEnabled)
                if syncEnabled {
                    TextField("This Mac's name", text: $machineName,
                              prompt: Text(Host.current().localizedName ?? "This Mac"))
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Cross-Machine Sync")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aggregate usage from your other Macs via iCloud Drive. Only token counts leave this Mac — never prompts, file paths, or keys — and nothing is sent until you turn this on.")
                    if syncEnabled {
                        Text("The name identifies this Mac to your other Macs.")
                    }
                    if syncEnabled && ICloudDriveFolder().directoryURL == nil {
                        Text("iCloud Drive looks turned off — sync stays local-only. Enable it in System Settings → Apple ID → iCloud → iCloud Drive.")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Toggle("Keep a usage history", isOn: $archiveEnabled)
            } header: {
                Text("History Archive")
            } footer: {
                Text("Preserve a permanent daily/monthly history on this Mac so reports survive Claude clearing its logs. Only token counts are stored — about 5 MB per month in Application Support.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Subscription

struct SubscriptionPane: View {
    @AppStorage(CostBasisStore.claudePlanKey) private var claudePlan: ClaudePlan = .api
    @AppStorage(CostBasisStore.gptPlanKey) private var gptPlan: GPTPlan = .api
    @AppStorage(CostBasisStore.claudeCustomKey) private var claudeCustomFee: Double = 100
    @AppStorage(CostBasisStore.gptCustomKey) private var gptCustomFee: Double = 20

    var body: some View {
        Form {
            Section {
                planPicker("Claude plan", $claudePlan)
                if claudePlan == .custom { feeField($claudeCustomFee) }
            } footer: {
                Text("Compared against Claude's API-equivalent cost to show this month's subscription break-even on the dashboard.")
            }

            Section {
                planPicker("GPT plan", $gptPlan)
                if gptPlan == .custom { feeField($gptCustomFee) }
            } footer: {
                Text("Compared against Codex/GPT's API-equivalent cost.")
            }
        }
        .formStyle(.grouped)
    }

    /// A picker over any SubscriptionPlan enum (Claude / GPT share this).
    private func planPicker<P: SubscriptionPlan>(_ title: String, _ selection: Binding<P>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Array(P.allCases)) { Text($0.label).tag($0) }
        }
    }

    /// Monthly fee row, shown when a vendor's plan is Custom.
    private func feeField(_ value: Binding<Double>) -> some View {
        TextField("Monthly fee", value: value, format: .currency(code: "USD"))
            .multilineTextAlignment(.trailing)
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: MenuBarIcon.soft.image(height: 64))
                    Text("Tokenomics")
                        .font(.title3.weight(.semibold))
                    Text("Version \(version)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Claude, Codex & WorkBuddy token usage, live in your menu bar.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                Link("Tokenomics on GitHub",
                     destination: URL(string: "https://github.com/First2nd3rd/Tokenomics")!)
            }
        }
        .formStyle(.grouped)
    }
}
