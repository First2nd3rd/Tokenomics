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
    /// How many recent days the daily stacked-bar chart shows.
    private static let dailyBarDays = 14
    /// Length of the live sliding rate window. At a 60s refresh the chart shifts by
    /// 1/60 of its width per tick — a slow, steady leftward drift.
    private static let liveWindowMinutes = 60

    private var statusItem: NSStatusItem!
    private let store = UsageStore()
    private let model = DashboardModel()
    private let popover = NSPopover()
    private let loginItem = LoginItemModel()
    private var settingsWindow: NSWindow?
    private var reportWindow: NSWindow?
    private lazy var reportModel = ReportModel { [weak self] period, anchor, completion in
        guard let self else { completion(nil); return }
        self.store.report(period: period, anchor: anchor, completion: completion)
    }
    private var timer: Timer?
    private var lastSyncEnabled = false
    private var lastArchiveEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Default Custom-plan fees so the engine (raw UserDefaults) and the Settings
        // fields (@AppStorage) agree before the user edits them.
        UserDefaults.standard.register(defaults: [
            CostBasisStore.claudeCustomKey: 100,
            CostBasisStore.gptCustomKey: 20,
            "archiveEnabled": true,
        ])
        lastSyncEnabled = UserDefaults.standard.bool(forKey: "syncEnabled")
        lastArchiveEnabled = UserDefaults.standard.bool(forKey: "archiveEnabled")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                model: model,
                onRefresh: { [weak self] in self?.refresh() },
                onSettings: { [weak self] in self?.openSettings() },
                onReport: { [weak self] in self?.openReport() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyMenuBarIcon()

        // Re-render the menu-bar icon immediately when its Settings picker changes.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyMenuBarIcon()
            self?.syncSettingChanged()
            self?.archiveSettingChanged()
        }

        refresh()
        // Seed the durable archive from history already on disk (once; re-runnable),
        // so reports cover the past, not just usage from this launch onward.
        store.backfillArchiveIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // The 60s timer is paused while the Mac sleeps, so the figure goes stale until
        // the next tick after wake (and the day may have rolled over). Refresh
        // immediately on wake instead of waiting.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }

        // A long-running process caches the system timezone; on a change (e.g. travel)
        // reset it so day bucketing follows the new zone, then refresh.
        NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.refresh()
        }
    }

    /// Re-render the status image when the icon style picker changed.
    private var appliedIconStyle: MenuBarIcon?
    private func applyMenuBarIcon() {
        let style = Self.iconStyle()
        guard style != appliedIconStyle else { return }
        appliedIconStyle = style
        renderStatusItem()
    }

    private static func iconStyle() -> MenuBarIcon {
        MenuBarIcon(rawValue: UserDefaults.standard.string(forKey: "menuBarIcon") ?? "") ?? .hidden
    }

    /// The whole status item is ONE image (optional cube + two text lines):
    /// NSStatusBarButton centers images correctly at any menu-bar height
    /// (notched Macs are ~33pt), which a multi-line title is not.
    private func renderStatusItem() {
        statusItem.button?.image = StatusImage.make(lastStatusLines, icon: Self.iconStyle())
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
        var localMatrix: [String: [MinuteBucket]] = [:]

        group.enter()
        store.refreshByVendor { perVendor = $0; group.leave() }

        group.enter()
        store.refreshMatrix(now: now, lastDays: Self.matrixDays) { combined, local in
            matrix = combined; localMatrix = local; group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            self?.present(perVendor: perVendor, matrix: matrix, localMatrix: localMatrix, now: now)
        }

        // Per-machine breakdown for the by-machine view (empty when sync is off).
        store.refreshMachines(now: now) { [weak self] in self?.model.machines = $0 }

        // Publish this machine's records for other Macs and fold them into the durable
        // archive — one shared fetch; each half no-ops when its feature is off or
        // nothing changed.
        store.persistLocal()

        // Freeze any newly-finalized day into the snapshot store (guarded to one real
        // sweep per day; catches the midnight rollover during a long-running session).
        store.refreshSnapshots(now: now)
    }

    /// Flush a final publish + archive on quit so the last bit of usage is preserved
    /// (no-op when both features are off or nothing changed).
    func applicationWillTerminate(_ notification: Notification) {
        store.flushLocal()
    }

    /// React to the sync toggle: when it flips OFF, retract this Mac's published file
    /// so peers stop counting it.
    private func syncSettingChanged() {
        let enabled = UserDefaults.standard.bool(forKey: "syncEnabled")
        if lastSyncEnabled && !enabled { store.retractOwnFile() }
        lastSyncEnabled = enabled
    }

    /// React to the archive toggle: when it flips ON, backfill any history accrued
    /// while it was off. Turning it off just stops ingesting — the archive is kept.
    private func archiveSettingChanged() {
        let enabled = UserDefaults.standard.bool(forKey: "archiveEnabled")
        if enabled && !lastArchiveEnabled { store.backfillArchiveIfNeeded(force: true) }
        lastArchiveEnabled = enabled
    }

    /// Push one fully-assembled refresh into the view model (main queue). The
    /// combined daily snapshot is the merge of the per-vendor series.
    private func present(perVendor: [String: [DailyUsage]],
                         matrix: [String: [MinuteBucket]],
                         localMatrix: [String: [MinuteBucket]],
                         now: Date) {
        let snapshot = UsageSnapshot(days: CombinedProvider.merge(Array(perVendor.values)))
        let dashboard = Dashboard.make(from: snapshot, now: now)
        let series = IntradayCurve.build(matrix: matrix, now: now)

        // Headline.
        updateStatusText(dashboard, now: now)
        if dashboard.headline != nil {
            model.headline = Self.headlineText(dashboard)
            model.subtitle = Self.subtitleText(dashboard, series: series)
        } else {
            model.headline = "—"
            model.subtitle = "usage data unavailable"
        }
        model.models = dashboard.headline?.models ?? []

        // Charts.
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let todayMinutes = matrix[DayBucket.dayKey(now)] ?? Array(repeating: MinuteBucket(), count: 1440)
        model.updateRate(today: todayMinutes, nowMinute: nowMinute)
        let liveCombined = RateWindow.lastMinutes(matrix: matrix, now: now, count: Self.liveWindowMinutes)
        let liveLocal = RateWindow.lastMinutes(matrix: localMatrix, now: now, count: Self.liveWindowMinutes)
        model.updateLive(local: liveLocal, combined: liveCombined)
        model.cumToday = series.today
        model.cumTypical = series.typical
        model.cumPredicted = series.predicted

        // Per-vendor subscription break-even (this month).
        model.breakEven = BreakEven.compute(perVendor: perVendor, now: now,
                                            claude: CostBasisStore.claude(),
                                            gpt: CostBasisStore.gpt())

        // Recent days for the daily bar chart.
        model.dailyBars = Array(snapshot.days.suffix(Self.dailyBarDays))
    }

    /// Today's total from the previous refresh, for the menu bar's live "+X"
    /// increment. Day-keyed so the midnight rollover shows cost, not a bogus delta.
    private var lastStatusSample: (day: String, tokens: Int)?
    private var lastStatusLines = StatusLine.Lines(top: "—", bottom: "")

    /// Menu-bar text: two stacked lines — today's tokens on top; the freshly
    /// added tokens below while usage is flowing, today's cost when idle.
    private func updateStatusText(_ d: Dashboard, now: Date) {
        let today = DayBucket.dayKey(now)
        var delta: Int?
        if let h = d.headline {
            if let last = lastStatusSample, last.day == today {
                delta = h.totalTokens - last.tokens
            }
            lastStatusSample = (today, h.totalTokens)
        } else {
            lastStatusSample = nil
        }
        lastStatusLines = StatusLine.make(totalTokens: d.headline?.totalTokens,
                                          cost: d.headline?.totalCost, delta: delta)
        renderStatusItem()
    }

    private static func headlineText(_ d: Dashboard) -> String {
        guard let h = d.headline else { return "—" }
        return "\(Format.tokensShort(h.totalTokens)) · \(Format.cost(h.totalCost))"
    }

    /// Subtitle projection comes from the cumulative curve (`series.projectedTotal`),
    /// the same value the popover's projected line ends at. Cost is scaled by the
    /// same token multiplier so the two figures stay consistent.
    private static func subtitleText(_ d: Dashboard, series: IntradayCurve.Series) -> String {
        guard d.hasUsageToday else {
            guard let la = d.lastActive else { return "No usage yet today" }
            return "No usage yet today · last active \(Format.shortMonthDay(la.date)): "
                + "\(Format.tokensShort(la.totalTokens)) · \(Format.cost(la.totalCost))"
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
        let reportItem = NSMenuItem(title: "Reports…", action: #selector(openReport), keyEquivalent: "u")
        reportItem.target = self
        menu.addItem(reportItem)
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
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
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

    // MARK: - Reports

    @objc private func openReport() {
        if reportWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Usage Report"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: ReportView(model: reportModel))
            window.center()
            reportWindow = window
        }
        reportModel.syncOn = UserDefaults.standard.bool(forKey: "syncEnabled")
        reportModel.reload()
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        reportWindow?.makeKeyAndOrderFront(nil)
    }
}
