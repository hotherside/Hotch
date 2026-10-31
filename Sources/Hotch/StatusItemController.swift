import AppKit
import ServiceManagement
import SwiftUI

/// Menu bar surface.
///
/// Left click opens a compact version of the notch panel (see
/// StatusPopoverView): meters, percentages and reset countdowns in the same
/// units and brand colours as the panel. That is the primary surface for anyone
/// on a display without a notch, and it beats a list of sentences in a menu.
///
/// Right click keeps a plain menu for the things that are actions rather than
/// readings — refresh, settings, launch at login, quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store: UsageStore
    private let sessionStore: SessionStore
    private let clipboard: ClipboardStore
    private let focus: FocusStore
    private let system: SystemMonitor
    private let backpack: BackpackManager
    private let popoverPages = PopoverPageModel()
    private let menu = NSMenu()
    /// The card under the menu bar icon: the same card, window and motion as
    /// the edge rail's, with its own section memory. It replaced an
    /// NSPopover, which resized itself on its own timing while the card
    /// animated, so every section change moved differently.
    private lazy var menuCard: CardPanelController = {
        var deps = CardDeps(store: store, sessionStore: sessionStore, clipboard: clipboard, focus: focus,
                            system: system, backpack: backpack, pages: popoverPages)
        deps.openSettings = { [weak self] in
            self?.hideCard()
            self?.onOpenSettings?()
        }
        deps.signInClaude = { [weak self] in self?.onSignInClaude?() }
        deps.refresh = { [weak self] in self?.onRefreshRequested?() }
        deps.quit = { NSApp.terminate(nil) }
        deps.jump = { [weak self] session in
            SessionJump.go(to: session) { [weak self] success in
                if success { self?.hideCard() }
            }
        }
        return CardPanelController(deps: deps)
    }()
    private var outsideMonitor: Any?
    private var escMonitor: Any?

    var onRefreshRequested: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSignInClaude: (() -> Void)?
    var onChooseAnchor: ((HotchPrefs.Anchor) -> Void)?

    /// The glyph is constant now, so it is drawn once rather than cached
    /// against the numbers it no longer depends on.
    private var hasRenderedImage = false
    private var renderedTitle: String?
    /// Tracked alongside the title because the same text can need either
    /// treatment: in Remaining mode "15%" is a crisis and in Used mode it is
    /// nothing, so a title-only comparison would skip the restyle when the mode
    /// changed without the number moving.
    private var renderedCritical: Bool?
    /// Same story for the needs-input dot: it can appear or vanish while the
    /// percentage text stays identical.
    private var renderedNeedsInput: Bool?
    private var isShowingMenu = false

    init(store: UsageStore,
         sessionStore: SessionStore,
         clipboard: ClipboardStore,
         focus: FocusStore,
         system: SystemMonitor,
         backpack: BackpackManager) {
        self.store = store
        self.sessionStore = sessionStore
        self.clipboard = clipboard
        self.focus = focus
        self.system = system
        self.backpack = backpack
        super.init()

        if let button = statusItem.button {
            button.image = HotchIcon.statusBarImage()
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.title = " –"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.delegate = self
        rebuildMenu()
        updateTitle()
    }

    // MARK: - Pages

    /// The popover's window while it is shown, for the swipe monitor to route
    /// scroll gestures by window identity — the settings window scrolls too,
    /// and it must not turn pages.
    var popoverWindow: NSWindow? {
        menuCard.isShown ? menuCard.panel : nil
    }

    /// The menu bar icon on screen, for welcome to point at. Nil when macOS
    /// has hidden it because the menu bar is full. Occlusion is not asked:
    /// an auto-hiding menu bar covers the icon without the bar being full.
    var iconFrame: CGRect? {
        guard let button = statusItem.button, let window = button.window, window.isVisible else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 0, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return nil }
        return frame
    }

    func changePopoverPage(by delta: Int) {
        popoverPages.change(by: delta)
    }

    // MARK: - Click routing

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondary {
            showMenu()
        } else {
            togglePopover()
        }
    }

    /// The keyboard shortcut, when Hotch lives in the menu bar only.
    func togglePopoverFromShortcut() {
        togglePopover()
    }

    private func togglePopover() {
        if menuCard.isShown {
            hideCard()
            return
        }
        guard let button = statusItem.button, let window = button.window else { return }
        // Opening is a deliberate request for current numbers. The providers'
        // own throttles decide whether that reaches the network.
        onRefreshRequested?()
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        menuCard.pinned = true
        // Hangs from just under the icon, top fixed, like Control Center.
        menuCard.show(origin: .top, alignment: .top, showsTabs: true, appButtons: true) { size in
            let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
            let x = min(max(icon.midX - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
            let top = min(icon.minY - 6, visible.maxY - 4)
            return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
        popoverPages.isShown = true
        installMonitors()
    }

    private func hideCard() {
        guard menuCard.isShown else { return }
        menuCard.hide()
        popoverPages.isShown = false
        removeMonitors()
    }

    /// Closes like a menu: a click anywhere else, or Esc.
    private func installMonitors() {
        removeMonitors()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideCard() }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.menuCard.isShown else { return }
                self.hideCard()
                handled = true
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        outsideMonitor = nil
        escMonitor = nil
    }

    private func showMenu() {
        // performClick is being called from inside the button's own action. A
        // status item with a menu attached shows the menu instead of sending the
        // action, so this does not recurse — but a hung menu bar is a bad way to
        // discover that assumption was wrong on some macOS version.
        guard !isShowingMenu else { return }
        isShowingMenu = true
        defer { isShowingMenu = false }

        rebuildMenu()
        // Attaching the menu makes the status item highlight and position it the
        // way a real menu bar menu does; detaching again afterwards keeps the
        // left click free for the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Title

    /// Glyph plus a mini meter per window of the tightest provider, and its
    /// percentage as text, in whichever direction the user chose. The percentage
    /// turns red when something is nearly out, since a template image cannot carry
    /// that signal.
    func updateTitle() {
        guard let button = statusItem.button else { return }

        let mode = AppSettings.shared.displayMode
        // One glyph, always. The readout used to carry the notch mark *plus* up
        // to two mini meters, which read as two separate icons sitting in the
        // menu bar rather than as one app — and the meters restated a shape the
        // percentage beside them already gave. The mark alone is the identity;
        // the number is the reading.
        if !hasRenderedImage {
            button.image = HotchIcon.statusBarImage()
            hasRenderedImage = true
        }

        // Always the fullest window, then read in the chosen direction — so both
        // modes report the same subscription and only the number differs.
        let consumed = store.highestConsumedPercent
        let shown = consumed.map { mode == .used ? $0 : 100 - $0 }

        // **A running timer owns the menu bar.**
        //
        // The usage percentage is an ambient number — worth knowing, changing
        // slowly, and never urgent to the second. A running countdown is the
        // opposite: it is the thing you started deliberately and want to check
        // without opening anything, and it is over in minutes. While one is
        // running it takes the slot; the percentage is a hover or a click away
        // and comes straight back when the timer ends.
        let timer = FocusDisplay.menuTitle(focus, now: Date())
        let title = (timer.map { " \($0)" }
            ?? shown.map { " \(Fmt.percent($0))" }
            ?? " –") + systemReadouts

        // The warning keys off consumption, never off the displayed number: in
        // Remaining mode the number falls as things get worse, so a naive
        // comparison would light up red on a healthy account and stay black on a
        // dying one. A timer in the slot is never the warning colour — it is
        // not reporting a limit.
        let isCritical = timer == nil && (consumed ?? 0) >= NotchTheme.highConsumedThreshold
        let needsInput = sessionStore.needsInputCount > 0
        guard title != renderedTitle || isCritical != renderedCritical
                || needsInput != renderedNeedsInput else { return }
        renderedTitle = title
        renderedCritical = isCritical
        renderedNeedsInput = needsInput

        // Always the attributed form, both ways. Assigning plain `title` after an
        // attributed one does not reliably drop the attributes, so a percentage
        // that dropped back below the threshold could stay red.
        let composed = NSMutableAttributedString()
        if needsInput {
            // A session is sitting on (what is probably) a permission prompt.
            // This lives in the title, not the glyph: the glyph is a template
            // image, and a template image cannot carry a colour — the same
            // reason the critical percentage is text-red. Amber, because a
            // session waiting on a keystroke is a nudge, not the warning red of
            // a nearly-spent window.
            composed.append(NSAttributedString(
                string: " \u{25CF}",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.30, alpha: 1),
                    .baselineOffset: 1.5,
                ]
            ))
        }
        composed.append(NSAttributedString(
            string: title,
            attributes: [
                // Monospaced digits throughout, which the countdown needs far
                // more than the percentage did: a proportional clock jitters
                // its own width every second.
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12,
                                                       weight: isCritical ? .semibold : .regular),
                .foregroundColor: isCritical ? NSColor.systemRed : NSColor.labelColor
            ]
        ))
        button.attributedTitle = composed
    }

    /// iStat-style readouts after the usage number, when switched on in
    /// Settings. Plain monochrome text, so they sit in the menu bar like the
    /// system's own items; the colour stays reserved for the warning.
    private var systemReadouts: String {
        let prefs = HotchPrefs.shared
        guard prefs.wantsMenuBarSystem, let snap = system.latest else { return "" }
        var parts: [String] = []
        if prefs.menuBarCPU { parts.append("CPU \(SysFmt.percent(snap.cpu.total))%") }
        if prefs.menuBarMemory, snap.memory.totalBytes > 0 {
            let used = Double(snap.memory.usedBytes) / Double(snap.memory.totalBytes) * 100
            parts.append("MEM \(SysFmt.percent(used))%")
        }
        if prefs.menuBarNetwork {
            parts.append("↓\(SysFmt.rateShort(snap.network.downBytesPerSecond)) ↑\(SysFmt.rateShort(snap.network.upBytesPerSecond))")
        }
        return parts.isEmpty ? "" : "  " + parts.joined(separator: "  ")
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        // The timer controls, reachable without opening anything. The menu is
        // the one Hotch surface that exists on every Mac in every state, which
        // makes it the reliable home for an action people bind to muscle
        // memory. Contextual: a running timer offers only the stop.
        if focus.isRunning {
            // Pause or resume first — the reversible action outranks the
            // final one.
            if focus.isPaused {
                let resume = NSMenuItem(title: "Resume Timer",
                                        action: #selector(resumeTimer), keyEquivalent: "")
                resume.target = self
                menu.addItem(resume)
            } else {
                let pause = NSMenuItem(title: "Pause Timer",
                                       action: #selector(pauseTimer), keyEquivalent: "")
                pause.target = self
                menu.addItem(pause)
            }
            // Named after the task rather than the mechanism, so the menu says
            // what stopping actually ends. Not "Stop & Log": the line went into
            // the log when the run started, so the only thing left to do is
            // stop.
            let label = focus.runningLabel.map { "Stop \u{2014} \($0)" } ?? "Stop"
            let stop = NSMenuItem(title: label, action: #selector(stopTimer), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        } else {
            // Lengths one level down: five more flat items would be most of
            // this menu, whose job is the actions people reach for blind. The
            // menu cannot ask what you are working on, so a run started here is
            // unnamed unless a name is already sitting in the field.
            let start = NSMenuItem(title: "Start Focus Timer", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for minutes in FocusSetup.durations {
                let item = NSMenuItem(title: "\(minutes) minutes",
                                      action: #selector(startTimer(_:)), keyEquivalent: "")
                item.target = self
                item.tag = minutes
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let openEnded = NSMenuItem(title: "Stopwatch",
                                       action: #selector(startOpenEnded), keyEquivalent: "")
            openEnded.target = self
            submenu.addItem(openEnded)
            start.submenu = submenu
            menu.addItem(start)

            // The most recent *finished* task, continuable without opening
            // anything — clamshell users have no notch to hover.
            if let last = focus.finishedEntries.last {
                let verb = last.isContinuable ? "Resume" : "Start Again"
                let resume = NSMenuItem(title: "\(verb) \u{2014} \(last.displayTitle)",
                                        action: #selector(resumeLast), keyEquivalent: "")
                resume.target = self
                menu.addItem(resume)
            }
        }

        // Discovery opens the explanation first, including setup or the
        // reason this Mac cannot use the mode. Activation lives in that card.
        let backpackItem = NSMenuItem(title: "Backpack Mode…",
                                      action: #selector(openBackpackOverview), keyEquivalent: "")
        backpackItem.target = self
        menu.addItem(backpackItem)
        if backpack.isOn {
            let end = NSMenuItem(title: "End Backpack Mode", action: #selector(endBackpack), keyEquivalent: "")
            end.target = self
            menu.addItem(end)
        }

        // Where Hotch lives, switchable in one move.
        let anchorItem = NSMenuItem(title: "Show Hotch As", action: nil, keyEquivalent: "")
        let anchorMenu = NSMenu()
        for anchor in HotchPrefs.Anchor.allCases {
            let item = NSMenuItem(title: anchor.label, action: #selector(chooseAnchor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = anchor.rawValue
            item.state = HotchPrefs.shared.anchor == anchor ? .on : .off
            anchorMenu.addItem(item)
        }
        anchorItem.submenu = anchorMenu
        menu.addItem(anchorItem)

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Absent from a copy built without a feed, where it could only fail.
        let updates = AppUpdater.shared
        if updates.isRunning {
            // No action while a check is already running: the menu enables
            // items by whether they have one.
            let check = NSMenuItem(title: updates.actionTitle,
                                   action: updates.canAct ? #selector(checkForUpdates) : nil,
                                   keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        // Attribution lives here as well as in Settings, so it is visible without
        // opening a window.
        let credit = NSMenuItem(title: HotchAbout.credit, action: nil, keyEquivalent: "")
        credit.isEnabled = false
        credit.attributedTitle = NSAttributedString(
            string: "Hotch \(HotchAbout.version)  \u{00B7}  \(HotchAbout.credit)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(credit)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Hotch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Launch at login

    /// Both this menu and the Settings window offer the toggle, so the
    /// behaviour lives in `LoginItem` and neither surface owns it.
    private var launchAtLoginEnabled: Bool { LoginItem.isEnabled }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(!launchAtLoginEnabled)
        rebuildMenu()
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        onRefreshRequested?()
    }

    @objc private func startTimer(_ sender: NSMenuItem) {
        focus.start(minutes: sender.tag)
    }

    @objc private func startOpenEnded() {
        focus.start(minutes: nil)
    }

    @objc private func pauseTimer() {
        focus.pause()
    }

    @objc private func resumeTimer() {
        focus.resumeRun()
    }

    @objc private func resumeLast() {
        guard let last = focus.finishedEntries.last else { return }
        focus.resume(last)
    }

    @objc private func stopTimer() {
        focus.stop()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates()
    }

    @objc private func chooseAnchor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let anchor = HotchPrefs.Anchor(rawValue: raw) else { return }
        onChooseAnchor?(anchor)
    }

    @objc private func openBackpackOverview() {
        // Let NSMenu finish tracking before presenting another native window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.backpack.refresh()
            self.popoverPages.backpackCard = true
            if !self.menuCard.isShown { self.togglePopover() }
        }
    }

    @objc private func endBackpack() {
        backpack.stop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
