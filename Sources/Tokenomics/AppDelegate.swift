import AppKit
import SwiftUI

/// The menu bar item. Left-click opens a popover with today's headline figure and
/// an intraday token-rate chart; right-click shows a small Refresh/Quit menu.
/// Presentation only — all numbers come from `Dashboard` / the provider layer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 60

    private var statusItem: NSStatusItem!
    private let store = UsageStore()
    private let model = DashboardModel()
    private let popover = NSPopover()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                model: model,
                onRefresh: { [weak self] in self?.refresh() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            button.title = "🪙 …"
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Refresh

    @objc private func refresh() {
        PricingStore.shared.refreshIfStale()   // background, daily at most

        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        model.nowHour = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0)) / 60.0

        store.refresh { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                let dashboard = Dashboard.make(from: snapshot, now: Date())
                self.statusItem.button?.title = "🪙 " + Format.tokensShort(dashboard.headline?.totalTokens ?? 0)
                self.model.headline = Self.headlineText(dashboard)
                self.model.subtitle = Self.subtitleText(dashboard)
            case .failure:
                self.statusItem.button?.title = "🪙 —"
                self.model.headline = "—"
                self.model.subtitle = "usage data unavailable"
            }
        }

        store.refreshIntraday { [weak self] minutes in
            self?.model.updateRate(fromMinuteTokens: minutes)
        }
    }

    private static func headlineText(_ d: Dashboard) -> String {
        guard let h = d.headline else { return "—" }
        return "🪙 \(Format.tokensShort(h.totalTokens)) · \(Format.cost(h.totalCost))"
    }

    private static func subtitleText(_ d: Dashboard) -> String {
        guard d.isToday else {
            return d.headline.map { "Showing \($0.date)" } ?? ""
        }
        guard let pt = d.projectedTokens, let pc = d.projectedCost else {
            return "Projected — warming up"
        }
        var line = "Projected ~\(Format.tokensShort(pt)) · ~\(Format.cost(pc))"
        if let avg = d.avgTokens, let delta = Format.deltaPct(pt, vs: avg) {
            line += "   vs 7d \(delta)"
        }
        return line
    }

    // MARK: - Click handling

    @objc private func statusClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Show a transient Refresh/Quit menu without permanently attaching it (so the
    /// button keeps sending its left-click action to open the popover).
    private func showContextMenu() {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(NSMenuItem(title: "Quit Tokenomics",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
