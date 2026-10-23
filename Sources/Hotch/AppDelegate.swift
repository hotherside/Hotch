import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: UsageStore!
    private var sessionStore: SessionStore!
    private var clipboardStore: ClipboardStore!
    private var focusStore: FocusStore!
    private var model: PanelModel!
    private var system: SystemMonitor!
    private var backpack: BackpackManager!
    private var liveActivities: LiveActivityController!
    private var anchors: AnchorManager!
    private var liveWatcher: LiveActivityWatcher!
    private var swipeMonitor: PageSwipeMonitor!
    private var statusItemController: StatusItemController!
    private var settingsWindowController: SettingsWindowController!
    private var storeObservation: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// How long after launch the one-time reveal unfolds the panel.
    ///
    /// A second, not immediately. The status item is still being placed and the
    /// first refresh is still in flight, and a panel dropping out of the bezel
    /// before the desktop has settled reads as a glitch rather than as the app
    /// introducing itself.
    private static let revealDelay: TimeInterval = 1.0
    /// How long it then stays open with nobody hovering it. Long enough to
    /// notice something appeared, read six words and look at where they came
    /// from; short enough that ignoring it costs nothing.
    private static let revealHold: TimeInterval = 6.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Drawn identity for alerts and the app switcher; the bundle carries
        // the same artwork as AppIcon.icns.
        NSApp.applicationIconImage = HotchIcon.appIconImage()
        installMainMenu()

        settings = AppSettings.shared

        // Which rows exist has to be settled before the store is built from them.
        // On the first launch of a fresh install that means: whatever this Mac can
        // already report, and nothing else.
        let firstLaunch = settings.claimFirstLaunch()
        if firstLaunch {
            settings.seedEnabled(
                ProviderReadiness.configuredIDs(among: ProviderCatalog.all.map(\.id))
            )
        } else {
            // Already launched once, so it may be carrying the old default of two
            // providers switched on regardless of whether either worked.
            settings.pruneInheritedDefaults(isConfigured: ProviderReadiness.isConfigured)
        }

        store = UsageStore(providers: [
            ClaudeProvider(),
            CodexProvider(),
            GrokProvider(),
            KimiProvider(),
            DeepSeekProvider(),
        ], settings: settings)
        sessionStore = SessionStore()
        // First scan before the first hover, so the sessions page never opens
        // onto a spinner for data that lives on the local disk.
        sessionStore.scanIfStale(0)
        clipboardStore = ClipboardStore()
        clipboardStore.enabled = settings.clipboardHistoryEnabled
        clipboardStore.start()
        focusStore = FocusStore()
        model = PanelModel()
        system = SystemMonitor.shared
        system.advancedSensors = HotchPrefs.shared.advancedSensors
        backpack = BackpackManager.shared
        // Backpack mode ends 5 minutes after this reaches 0. Only agents that
        // can make progress count: one waiting on a permission prompt cannot
        // move with the lid shut, so it is no reason to keep the Mac awake in
        // a bag. The panel is closed while the lid is shut, so nothing else is
        // scanning; keep the list fresh here.
        let sessions: SessionStore = sessionStore
        backpack.activeAgentCount = { [weak sessions] in
            guard let sessions else { return 0 }
            sessions.scanIfStale(10)
            return sessions.sessions.filter { $0.activity == .working || $0.activity == .shell }.count
        }
        // The notch panel (`NotchWindowController`) is not built any more:
        // its hidden windows still re-rendered on every system tick.
        settingsWindowController = SettingsWindowController(settings: settings,
                                                            store: store)

        statusItemController = StatusItemController(store: store,
                                                    sessionStore: sessionStore,
                                                    clipboard: clipboardStore,
                                                    focus: focusStore,
                                                    system: system,
                                                    backpack: backpack)
        statusItemController.onRefreshRequested = { [weak self] in
            self?.store.requestRefresh()
        }
        statusItemController.onOpenSettings = { [weak self] in
            self?.settingsWindowController.show()
        }
        let signIn: () -> Void = { [weak self] in self?.signInClaude() }
        statusItemController.onSignInClaude = signIn

        // The menu bar readouts keep the sampler ticking at its cheapest rate;
        // with none switched on it sleeps until a surface opens.
        HotchPrefs.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.syncMenuBarDemand() }
                }
            }
            .store(in: &cancellables)
        syncMenuBarDemand()

        // Hotch 2.1 lives on the screen edge, as a floating pill or orb, or
        // in the menu bar only; the notch panel is no longer used. Its code
        // stays in the tree (`NotchWindowController`), unstarted.
        let cardPages = PopoverPageModel()
        let deps = CardDeps(store: store, sessionStore: sessionStore, clipboard: clipboardStore,
                            focus: focusStore, system: system, backpack: backpack, pages: cardPages,
                            openSettings: { [weak self] in self?.settingsWindowController.show() },
                            signInClaude: { [weak self] in self?.signInClaude() },
                            refresh: { [weak self] in self?.store.requestRefresh() },
                            jump: { [weak self] session in self?.anchors.jump(to: session) },
                            actOnAlert: { [weak self] alert in self?.anchors.act(on: alert) })
        anchors = AnchorManager(deps: deps)
        anchors.onMenuBarToggle = { [weak self] in self?.statusItemController.togglePopoverFromShortcut() }
        anchors.apply(HotchPrefs.shared.anchor)
        anchors.applyShortcut(HotchPrefs.shared.shortcutEnabled)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.hojaejung.hotch.toggle"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.anchors.toggle() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.hojaejung.hotch.test-alert"), object: nil, queue: .main
        ) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? "need-test"
            MainActor.assumeIsolated {
                let sample = LiveActivity(icon: .symbol("bell.fill"), leading: "Sample alert", trailing: "from --test-alert",
                                          tint: HP.amber, trailingTint: HP.amber, dot: true, key: key)
                self?.anchors.present(sample) {}
            }
        }
        statusItemController.onChooseAnchor = { anchor in HotchPrefs.shared.anchor = anchor }

        HotchPrefs.shared.$anchor
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] anchor in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.anchors.apply(anchor) }
                }
            }
            .store(in: &cancellables)
        HotchPrefs.shared.$edgeSide
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.anchors.refreshPlacement() }
                }
            }
            .store(in: &cancellables)
        HotchPrefs.shared.$shortcutEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in self?.anchors.applyShortcut(enabled) }
            .store(in: &cancellables)

        // Alerts speak through the anchor: the rail tab or the pill says it.
        liveActivities = LiveActivityController()
        liveActivities.panelIsOpen = { [weak self] in self?.anchors.card.isShown ?? false }
        liveActivities.presenter = { [weak self] activity, done in
            guard let self else { done(); return }
            self.anchors.present(activity, done: done)
        }
        liveWatcher = LiveActivityWatcher(controller: liveActivities)

        // Horizontal swipes turn the card's and popover's sections. Watching,
        // not taking: neither surface ever swallows a scroll meant for another app.
        swipeMonitor = PageSwipeMonitor()
        swipeMonitor.panelTarget = { [weak self] in self?.anchors.cardFrame }
        swipeMonitor.onPanelSwipe = { delta in cardPages.change(by: delta) }
        swipeMonitor.panelContentWindow = { [weak self] in self?.anchors.cardWindow }
        swipeMonitor.popoverWindow = { [weak self] in
            self?.statusItemController.popoverWindow
        }
        swipeMonitor.onPopoverSwipe = { [weak self] delta in
            self?.statusItemController.changePopoverPage(by: delta)
        }
        swipeMonitor.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A display appearing or disappearing changes the hover targets,
                // so the cached zones have to go before the panel is re-placed.
                self?.anchors.refreshPlacement()
            }
        }

        // Cheap poll to keep the menu bar title in step with the store, and the
        // session list fresh enough for the needs-input dot. The scan cadence
        // follows attention: seconds while a surface is showing the list,
        // relaxed in the background where only the dot depends on it.
        // One second, not two: the menu bar carries the focus countdown while
        // one is running, and a clock that only advances every other second
        // reads as a stuck app.
        let titleTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let watching = self.anchors.card.isShown
                    || self.statusItemController.popoverWindow != nil
                self.sessionStore.scanIfStale(watching ? 3 : 15)
                // A timer that reached its end logs itself even with nothing
                // open to draw it.
                self.focusStore.tick()
                self.statusItemController.updateTitle()
                self.liveWatcher.check(sessions: self.sessionStore.sessions,
                                       usages: self.store.usages,
                                       system: self.system.latest,
                                       focus: self.focusStore,
                                       backpack: self.backpack)
            }
        }
        RunLoop.main.add(titleTimer, forMode: .common)
        storeObservation = titleTimer

        // The clipboard watcher follows its setting live, so toggling it in
        // the settings window acts immediately.
        settings.$clipboardHistoryEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.clipboardStore.enabled = enabled
                    }
                }
            }
            .store(in: &cancellables)

        // The refresh cadence comes from settings; the sink fires immediately
        // with the stored value, which installs the initial timer.
        settings.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in
                self?.store.startAutoRefresh(interval: interval)
            }
            .store(in: &cancellables)

        // Toggling providers reshapes the panel right away. The publisher fires
        // before the property is written, so the new value is passed through.
        settings.$enabledProviderIDs
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.store.applyProviderFilter(enabledIDs: enabled)
                self.statusItemController.updateTitle()
            }
            .store(in: &cancellables)

        store.requestRefresh()

        // First launch of a fresh install with nothing set up: show Settings
        // unprompted. There is no window and no Dock icon, so otherwise the panel
        // would open empty with no discoverable way to fix that. Opening it once is
        // the whole onboarding.
        //
        // Skipped when the seed above found a working provider: there are real
        // numbers in the panel already, and a window opening by itself would just
        // be something to dismiss.
        if firstLaunch && settings.enabledProviderIDs.isEmpty {
            hotchLog.log("first launch with nothing set up, opening settings")
            settingsWindowController.show()
        }

        // A full menu bar leaves the status item with no room at all, and an app
        // with no Dock icon and no visible status item has, from the outside,
        // not launched — the reports are people reinstalling something that was
        // already running. So the first launch introduces itself: the panel
        // unfolds once, unasked, with a line saying where to find it again.
        // Every launch after this one is silent.
        //
        // Keyed off the `firstLaunch` computed at the top rather than asking
        // again. `claimFirstLaunch` writes the flag as it answers, so a second
        // call returns false and this would never fire for anyone.
        //
        // Unconditional where the Settings window above is not: the reveal is
        // about the app being findable, which is exactly as true for someone
        // whose providers were seeded successfully.
        if firstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.revealDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    hotchLog.log("first launch, revealing the panel")
                    // The monitor owns the collapse, so it is what has to be
                    // told to hold on: left to itself, its next poll finds the
                    // pointer nowhere near the notch and takes the panel away
                    // 160ms after it arrived.
                    // Say where Hotch lives by opening the card from it once.
                    self.anchors.toggle()
                }
            }
        }

        // Last, and only in the case that is actually broken: running from the
        // disk image instead of Applications. Deferred by one turn of the run
        // loop so the menu bar icon is already there to point at, and placed
        // after Settings so the two never fight over the front window.
        if !InstallLocation.isProperlyInstalled {
            hotchLog.log("not installed: running from \(InstallLocation.bundlePath, privacy: .public)")
            DispatchQueue.main.async {
                InstallLocation.warnIfNotInstalled()
            }
        }
    }

    private func syncMenuBarDemand() {
        system.setDemand(HotchPrefs.shared.wantsMenuBarSystem ? .menuBar : .idle, for: "menubar")
        statusItemController?.updateTitle()
    }

    private var claudeSignInTask: Task<Void, Never>?

    /// Claude's numbers come from Claude Code itself, which needs to be signed
    /// in once. The panel's button starts Claude Code's own sign-in (it opens
    /// the browser); the credential is Claude Code's, never Hotch's. Settings
    /// shows the same flow with its waiting state and a Cancel.
    private func signInClaude() {
        guard claudeSignInTask == nil else { return }
        hotchLog.log("starting Claude Code sign-in from the panel")
        claudeSignInTask = Task { @MainActor [weak self] in
            let result = await ClaudeCodeLogin.run()
            guard let self else { return }
            self.claudeSignInTask = nil
            switch result {
            case .success:
                ClaudeCodeBridge.invalidateSignIn()
                self.settings.setEnabled(true, providerID: "claude")
                ClaudeProvider.throttle.reset()
                ClaudeProvider.lastVerdict.clear()
                self.store.requestRefresh()
            case .failure(.cancelled):
                break
            case .failure:
                // The settings row explains failures in words and offers a retry.
                self.settingsWindowController.show()
            }
        }
    }

    // MARK: - The menu nobody can see

    /// Installs a main menu that is never drawn, and without which nothing in
    /// the app can be pasted into.
    ///
    /// **Do not delete this because there is no menu bar to put it in.** That is
    /// exactly the reasoning that left it out. `LSUIElement` makes Hotch an
    /// accessory app: no Dock icon, and macOS draws no menu bar for it even when
    /// it is the active app. A menu with nowhere to appear looks like dead
    /// weight — and the app shipped without one, which is why the first person
    /// who tried to paste an API key into Settings reported that copy and paste
    /// had been blocked.
    ///
    /// It had been. `NSApplication.sendEvent(_:)` dispatches Command-key
    /// combinations by offering them to `NSApp.mainMenu` first, via
    /// `performKeyEquivalent`. With no main menu there is nothing to offer them
    /// to, so ⌘V never reaches the first responder and **no text field anywhere
    /// in the app can be pasted into** — not a provider key field, not the focus
    /// timer's task name in either the notch panel or the popover. This menu is
    /// not a menu; it is the routing table for six keystrokes.
    ///
    /// The alternative was a local `NSEvent` monitor catching ⌘X/C/V/A/Z and
    /// forwarding each to the first responder by hand. Rejected: it
    /// reimplements dispatch AppKit already gets right, it has to be taught
    /// about every editable surface added afterwards, and it would still owe
    /// undo a correct answer. Six menu items are the smaller thing to maintain.
    ///
    /// Nothing here changes the app's status. An accessory app stays without a
    /// Dock icon and without a visible menu bar whether or not `mainMenu` is
    /// set; setting it only gives the key equivalents somewhere to land.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // AppKit requires every top-level item to carry its submenu on the item
        // rather than in the bar, and it treats the first one as the app menu
        // whatever it is called. So the app menu exists mostly to hold that
        // position — its one real item is a ⌘Q, which an accessory app
        // otherwise has nowhere except the status item's right-click menu.
        // `terminate:` down the responder chain is the same path that menu's
        // Quit takes, so a timer running at quit still banks its time in
        // applicationWillTerminate rather than evaporating.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Hotch",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.target = nil
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // The reason the whole function exists. Every target is nil so each item
        // routes through the responder chain to whichever field holds the caret
        // — a concrete target would bind these to one object and paste would
        // work in exactly one place.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // `undo:` and `redo:` are first-responder actions with no Swift-visible
        // declaration to point #selector at, so they are named as strings. The
        // rest are spelled through NSText, which declares them.
        let edits: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", [.command]),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        for (title, action, key, modifiers) in edits {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = nil
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        swipeMonitor?.stop()
        clipboardStore?.stop()
        // A timer running at quit logs whatever it banked rather than
        // evaporating: quitting the meter should not erase the metered time.
        focusStore?.stop()
        storeObservation?.invalidate()
    }
}
