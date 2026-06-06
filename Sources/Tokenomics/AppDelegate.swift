import AppKit

/// The menu bar item: shows today's running token total, refreshing on a timer,
/// with a dropdown of projection and comparison detail. Presentation only — all
/// numbers come from `Dashboard` / the provider layer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 60

    private var statusItem: NSStatusItem!
    private let store = UsageStore()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪙 …"

        rebuildMenu(dashboard: nil, error: nil)
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        PricingStore.shared.refreshIfStale()   // background, daily at most
        store.refresh { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                let dashboard = Dashboard.make(from: snapshot, now: Date())
                let tokens = dashboard.headline?.totalTokens ?? 0
                self.statusItem.button?.title = "🪙 " + Format.tokensShort(tokens)
                self.rebuildMenu(dashboard: dashboard, error: nil)
            case .failure(let error):
                self.statusItem.button?.title = "🪙 —"
                self.rebuildMenu(dashboard: nil, error: error)
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu(dashboard: Dashboard?, error: Error?) {
        let menu = NSMenu()

        if let d = dashboard, let h = d.headline {
            let dayLabel = d.isToday ? "Today" : h.date
            menu.addItem(info("📅 \(dayLabel) · \(h.date)"))

            let usedLabel = d.isToday ? "Used so far" : "Used"
            menu.addItem(info("\(usedLabel)   \(Format.grouped(h.totalTokens))   \(Format.cost(h.totalCost))"))

            if let pt = d.projectedTokens, let pc = d.projectedCost {
                menu.addItem(info("Projected    ~\(Format.tokensShort(pt))   ~\(Format.cost(pc))"))
                // Deltas compare today's *projected* end-of-day total against prior
                // *completed* days — intentional "where today is heading" framing.
                if let avg = d.avgTokens, let delta = Format.deltaPct(pt, vs: avg) {
                    menu.addItem(info("    vs 7-day avg   \(delta)"))
                }
                if let prev = d.previousDay, let delta = Format.deltaPct(pt, vs: prev.totalTokens) {
                    menu.addItem(info("    vs \(prev.date)   \(delta)"))
                }
            } else if d.isToday {
                menu.addItem(info("Projected    — (warming up)"))
            }

            menu.addItem(.separator())
            if let avg = d.avgTokens, let avgCost = d.avgCost {
                menu.addItem(info("7-day avg    \(Format.tokensShort(avg))   \(Format.cost(avgCost))"))
            }
            if let prev = d.previousDay {
                menu.addItem(info("\(prev.date)   \(Format.tokensShort(prev.totalTokens))   \(Format.cost(prev.totalCost))"))
            }

            if !h.models.isEmpty {
                menu.addItem(.separator())
                menu.addItem(info("Models: \(h.models.joined(separator: ", "))"))
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
