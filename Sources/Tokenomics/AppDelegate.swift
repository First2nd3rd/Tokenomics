import AppKit
import SwiftUI

/// The menu bar item. Left-click opens a popover with today's headline figure and
/// an intraday token-rate chart; right-click shows a small Refresh/Quit menu.
/// Presentation only — all numbers come from `Dashboard` / the provider layer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 60
    /// Prior days fetched for the cumulative chart's typical-day curve — wider than
    /// Dashboard's 7-day average window to give IntradayCurve enough history.
    private static let matrixDays = 14

    private var statusItem: NSStatusItem!
    private let store = UsageStore()
    private let model = DashboardModel()
    private let popover = NSPopover()
    private let loginItem = LoginItemModel()
    private var settingsWindow: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Default Custom-plan fees so the engine (raw UserDefaults) and the Settings
        // fields (@AppStorage) agree before the user edits them.
        UserDefaults.standard.register(defaults: [
            CostBasisStore.claudeCustomKey: 100,
            CostBasisStore.gptCustomKey: 20,
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                model: model,
                onRefresh: { [weak self] in self?.refresh() },
                onSettings: { [weak self] in self?.openSettings() },
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

        // One timestamp for the whole refresh so the title, projection, and charts
        // all describe the same instant.
        let now = Date()

        // Fetch the daily series and the minute matrix together, then present them
        // in one pass: the headline projection is derived from the same curve the
        // popover draws, so the number and the chart can't disagree.
        let group = DispatchGroup()
        var perVendor: [String: [DailyUsage]] = [:]
        var matrix: [String: [MinuteBucket]] = [:]

        group.enter()
        store.refreshByVendor { perVendor = $0; group.leave() }

        group.enter()
        store.refreshMatrix(now: now, lastDays: Self.matrixDays) { matrix = $0; group.leave() }

        group.notify(queue: .main) { [weak self] in
            self?.present(perVendor: perVendor, matrix: matrix, now: now)
        }
    }

    /// Push one fully-assembled refresh into the view model (main queue). The
    /// combined daily snapshot is the merge of the per-vendor series.
    private func present(perVendor: [String: [DailyUsage]],
                         matrix: [String: [MinuteBucket]],
                         now: Date) {
        let snapshot = UsageSnapshot(days: CombinedProvider.merge(Array(perVendor.values)))
        let dashboard = Dashboard.make(from: snapshot, now: now)
        let series = IntradayCurve.build(matrix: matrix, now: now)

        // Headline.
        if let headline = dashboard.headline {
            statusItem.button?.title = "🪙 " + Format.tokensShort(headline.totalTokens)
            model.headline = Self.headlineText(dashboard)
            model.subtitle = Self.subtitleText(dashboard, series: series)
        } else {
            statusItem.button?.title = "🪙 —"
            model.headline = "—"
            model.subtitle = "usage data unavailable"
        }
        model.models = dashboard.headline?.models ?? []

        // Charts.
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let todayMinutes = matrix[DayBucket.dayKey(now)] ?? Array(repeating: MinuteBucket(), count: 1440)
        model.updateRate(today: todayMinutes, nowMinute: nowMinute)
        model.cumToday = series.today
        model.cumTypical = series.typical
        model.cumPredicted = series.predicted

        // Per-vendor subscription break-even (this month).
        model.breakEven = BreakEven.compute(perVendor: perVendor, now: now,
                                            claude: CostBasisStore.claude(),
                                            gpt: CostBasisStore.gpt())
    }

    private static func headlineText(_ d: Dashboard) -> String {
        guard let h = d.headline else { return "—" }
        return "🪙 \(Format.tokensShort(h.totalTokens)) · \(Format.cost(h.totalCost))"
    }

    /// Subtitle projection comes from the cumulative curve (`series.projectedTotal`),
    /// the same value the popover's projected line ends at. Cost is scaled by the
    /// same token multiplier so the two figures stay consistent.
    private static func subtitleText(_ d: Dashboard, series: IntradayCurve.Series) -> String {
        guard d.isToday else {
            return d.headline.map { "Showing \($0.date)" } ?? ""
        }
        guard let pt = series.projectedTotal, let h = d.headline, h.totalTokens > 0 else {
            return "Projected — warming up"
        }
        let projectedCost = h.totalCost * Double(pt) / Double(h.totalTokens)
        var line = "Projected ~\(Format.tokensShort(pt)) · ~\(Format.cost(projectedCost))"
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
            keepPopoverOnScreen(below: button)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Work around an NSPopover quirk for menu-bar items: with tall content it
    /// anchors the arrow into the menu bar and pushes the body's top off the screen
    /// (the headline hides behind the menu bar). If the popover window overflows the
    /// visible area's top, slide it back down so the whole body is on screen.
    private func keepPopoverOnScreen(below button: NSStatusBarButton) {
        guard let window = popover.contentViewController?.view.window,
              let screen = button.window?.screen ?? NSScreen.main else { return }
        let overflow = window.frame.maxY - screen.visibleFrame.maxY
        guard overflow > 0 else { return }
        var frame = window.frame
        frame.origin.y -= overflow
        window.setFrame(frame, display: true)
    }

    /// Show a transient Refresh/Quit menu without permanently attaching it (so the
    /// button keeps sending its left-click action to open the popover).
    private func showContextMenu() {
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tokenomics",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 392),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Tokenomics"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(login: loginItem))
            window.center()
            settingsWindow = window
        }
        loginItem.refresh()
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
