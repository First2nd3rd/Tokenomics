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

struct SettingsView: View {
    @ObservedObject var login: LoginItemModel
    @AppStorage("rateChartStyle") private var rateStyle: RateChartStyle = .line
    @AppStorage(CostBasisStore.claudePlanKey) private var claudePlan: ClaudePlan = .api
    @AppStorage(CostBasisStore.gptPlanKey) private var gptPlan: GPTPlan = .api
    @AppStorage(CostBasisStore.claudeCustomKey) private var claudeCustomFee: Double = 100
    @AppStorage(CostBasisStore.gptCustomKey) private var gptCustomFee: Double = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))

            row("Launch at Login",
                subtitle: "Start Tokenomics automatically when you log in.") {
                Toggle("", isOn: Binding(get: { login.enabled }, set: { login.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            row("Rate chart",
                subtitle: "How the intraday usage chart is drawn.") {
                Picker("", selection: $rateStyle) {
                    ForEach(RateChartStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }

            Divider().padding(.vertical, 2)
            Text("Subscription — for break-even")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            row("Claude plan",
                subtitle: "Compared against Claude's API-equivalent cost.") {
                planPicker($claudePlan)
            }
            if claudePlan == .custom { customFeeField($claudeCustomFee) }

            row("GPT plan",
                subtitle: "Compared against Codex/GPT's API-equivalent cost.") {
                planPicker($gptPlan)
            }
            if gptPlan == .custom { customFeeField($gptCustomFee) }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 380, height: 392, alignment: .topLeading)
        .onAppear { login.refresh() }
    }

    /// A menu picker over any SubscriptionPlan enum (Claude / GPT share this).
    private func planPicker<P: SubscriptionPlan>(_ selection: Binding<P>) -> some View {
        Picker("", selection: selection) {
            ForEach(Array(P.allCases)) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    /// Right-aligned "$ ___ / mo" field, shown when a vendor's plan is Custom.
    private func customFeeField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Spacer()
            Text("$").foregroundStyle(.secondary)
            TextField("", value: value, format: .number)
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
            Text("/ mo").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    /// One settings line: title (+ subtitle) on the left, control right-aligned.
    /// Reusable as the panel grows.
    private func row<Control: View>(_ title: String,
                                    subtitle: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            control()
        }
    }
}
