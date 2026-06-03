import AppKit

/// Phase 1: a menu bar item showing the latest day's token total, refreshing
/// on a timer, with a dropdown of details. Presentation only — all numbers
/// come from `UsageStore` / the provider layer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 60

    private var statusItem: NSStatusItem!
    private let store = UsageStore()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪙 …"

        rebuildMenu(snapshot: nil, error: nil)
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        store.refresh { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                let tokens = snapshot.latest?.totalTokens ?? 0
                self.statusItem.button?.title = "🪙 " + Format.tokensShort(tokens)
                self.rebuildMenu(snapshot: snapshot, error: nil)
            case .failure(let error):
                self.statusItem.button?.title = "🪙 —"
                self.rebuildMenu(snapshot: nil, error: error)
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu(snapshot: UsageSnapshot?, error: Error?) {
        let menu = NSMenu()

        if let today = snapshot?.latest {
            menu.addItem(info("📅 \(today.date)"))
            menu.addItem(info("Tokens   \(Format.grouped(today.totalTokens))"))
            menu.addItem(info("Cost     \(Format.cost(today.totalCost))"))

            if let prev = snapshot?.previous,
               let delta = Format.deltaPct(today.totalTokens, vs: prev.totalTokens) {
                menu.addItem(info("vs \(prev.date)   \(delta)"))
            }

            if !today.models.isEmpty {
                menu.addItem(.separator())
                menu.addItem(info("Models: \(today.models.joined(separator: ", "))"))
            }
        } else if let error {
            menu.addItem(info("⚠︎ \(error.localizedDescription)"))
            menu.addItem(info("Check: npm i -g ccusage"))
        } else {
            menu.addItem(info("Loading…"))
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem(title: "Quit Tokenomics",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    /// A non-interactive informational row.
    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
