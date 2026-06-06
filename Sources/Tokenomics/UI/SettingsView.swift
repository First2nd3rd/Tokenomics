import SwiftUI
import ServiceManagement

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

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 360, height: 160, alignment: .topLeading)
        .onAppear { login.refresh() }
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
