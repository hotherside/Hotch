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
    private var onboardingWindowController: OnboardingWindowController!
    private let spotlight = OnboardingSpotlight()
    private var placementPulse: DispatchWorkItem?
    /// Set when Sparkle is about to quit and relaunch a new version, so the
    /// running Focus timer is handed over rather than finished.
    private var relaunchingForUpdate = false
    private var storeObservation: Timer?
    private var cancellables: Set<AnyCancellable> = []

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
        if settings.clipboardHistoryEnabled { clipboardStore.start() }
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
        // AnchorManager builds the native notch surface only when selected.
        settingsWindowController = SettingsWindowController(settings: settings,
                                                            store: store)
        onboardingWindowController = OnboardingWindowController(settings: settings)
        settingsWindowController.onShowWelcome = { [weak self] in
            self?.spotlight.dismiss(animated: false)
            self?.onboardingWindowController.show()
        }
        settingsWindowController.onPreviewAlert = { [weak self] in self?.previewAlert() }
        onboardingWindowController.onOpenSettings = { [weak self] in self?.settingsWindowController.show() }
        onboardingWindowController.onExplainInstall = { InstallLocation.warnIfNotInstalled() }
        onboardingWindowController.onPlacementChange = { [weak self] in self?.pulsePlacement() }
        onboardingWindowController.onFinish = { [weak self] origin in
            // Only an explicit finish points at the companion, keeping launch quiet.
            self?.showWhereHotchLives(from: origin)
        }
        spotlight.isOpen = { [weak self] in
            guard let self else { return false }
            return self.anchors.isShown || self.statusItemController.popoverWindow != nil
        }

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

        // All placements share stores and actions; the native notch keeps its
        // original panel while the other anchors open the compact card.
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
                self?.presentActivityPreview(sample)
            }
        }
        statusItemController.onChooseAnchor = { anchor in HotchPrefs.shared.anchor = anchor }

        HotchPrefs.shared.$anchor
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] anchor in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.anchors.apply(anchor)
                        self?.configureAlertPresenter()
                    }
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
        anchors.onNotchActivity = { [weak self] activity in self?.liveActivities.post(activity, cooldown: 0) }
        liveActivities.panelIsOpen = { [weak self] in self?.anchors.isShown ?? false }
        configureAlertPresenter()
        liveWatcher = LiveActivityWatcher(controller: liveActivities)

        // Horizontal swipes turn the card's and popover's sections. Watching,
        // not taking: neither surface ever swallows a scroll meant for another app.
        swipeMonitor = PageSwipeMonitor()
        swipeMonitor.panelTarget = { [weak self] in self?.anchors.cardFrame }
        swipeMonitor.onPanelSwipe = { [weak self] delta in self?.anchors.changePage(by: delta) }
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

        // HMotion reads the current OS values. Invalidate the models our
        // SwiftUI roots already observe so open surfaces also re-read those
        // values immediately, without waiting for the next telemetry update.
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.settings.objectWillChange.send()
                HotchPrefs.shared.objectWillChange.send()
                self.store.objectWillChange.send()
                self.sessionStore.objectWillChange.send()
                self.clipboardStore.objectWillChange.send()
                self.focusStore.objectWillChange.send()
                self.system.objectWillChange.send()
                self.anchors.refreshPlacement()
            }
            .store(in: &cancellables)

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
                let watching = self.anchors.isShown
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
                        guard let clipboard = self?.clipboardStore else { return }
                        clipboard.enabled = enabled
                        if enabled { clipboard.start() } else { clipboard.stop() }
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

        // Updates read the app's state when Sparkle asks, so a scheduled
        // window never lands on the welcome or a Focus run, and a downloaded
        // update relaunches only when nothing is open or running.
        let updates = AppUpdater.shared
        updates.moment = { [weak self] in
            guard let self else { return UpdatePolicy.Moment() }
            return UpdatePolicy.Moment(
                welcomeOpen: self.onboardingWindowController.isOpen,
                settingsOpen: self.settingsWindowController.isOpen,
                cardOpen: self.anchors.isShown || self.statusItemController.popoverWindow != nil,
                focusRunning: self.focusStore.isRunning,
                backpackActive: self.backpack.isOn)
        }
        updates.onWillRelaunch = { [weak self] in self?.relaunchingForUpdate = true }
        updates.start()

        // Completed upgrades stay quiet. A fresh install, or an introduction
        // closed before finishing, gets the native welcome instead of Settings
        // and a competing automatic panel reveal.
        if settings.shouldShowWelcome {
            onboardingWindowController.show()
        }

        // Last, and only in the case that is actually broken: running from the
        // disk image instead of Applications. Welcome says so in its letter
        // rather than stacking an alert on the greeting; otherwise the alert
        // is deferred by one turn of the run loop so the menu bar icon is
        // already there to point at.
        if !InstallLocation.isProperlyInstalled {
            hotchLog.log("not installed: running from \(InstallLocation.bundlePath, privacy: .public)")
            if !settings.shouldShowWelcome {
                DispatchQueue.main.async {
                    InstallLocation.warnIfNotInstalled()
                }
            }
        }
    }

    private func configureAlertPresenter() {
        guard let liveActivities else { return }
        if HotchPrefs.shared.anchor == .notch {
            // A nil presenter is the original native notch-wing animation.
            liveActivities.presenter = nil
        } else {
            liveActivities.presenter = { [weak self] activity, done in
                guard let self else { done(); return }
                self.anchors.present(activity, done: done)
            }
        }
    }

    /// Where the companion now rests, or the menu bar icon.
    private var companionFrame: CGRect? {
        anchors.restingFrame ?? (HotchPrefs.shared.anchor == .menuBar ? statusItemController.iconFrame : nil)
    }

    /// Placement changed during welcome: once the companion has moved (a new
    /// side glides across), a brief ring shows where it went.
    private func pulsePlacement() {
        placementPulse?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let frame = self.companionFrame else { return }
                self.spotlight.pulse(around: frame)
            }
        }
        placementPulse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.settle + 0.3, execute: work)
    }

    /// Welcome is done: the signal travels from the window to the companion
    /// and a note says how to open it, instead of opening the card unasked.
    private func showWhereHotchLives(from origin: CGRect) {
        placementPulse?.cancel()
        let prefs = HotchPrefs.shared
        let target = companionFrame
        let message = WelcomeCopy.whereItLives(prefs.anchor, side: prefs.edgeSide, realNotch: anchors.hasRealNotch,
                                               iconVisible: prefs.anchor != .menuBar || target != nil)
        spotlight.reveal(target: target, from: origin, message: message,
                         shortcut: prefs.shortcutEnabled ? WelcomeCopy.shortcutHint : nil)
    }

    private func previewAlert() {
        let sample = LiveActivity(icon: .symbol("checkmark.circle.fill"),
                                  leading: "All done", trailing: "Your companion will let you know",
                                  tint: HP.ok, trailingTint: HP.ok, dot: true,
                                  key: "welcome-sample")
        // Alerts speak through the resting anchor. A pinned card may still be
        // open behind Settings, so close it before demonstrating the alert.
        anchors.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.settle) { [weak self] in
            self?.presentActivityPreview(sample)
        }
    }

    private func presentActivityPreview(_ activity: LiveActivity) {
        if HotchPrefs.shared.anchor == .notch { liveActivities?.post(activity, cooldown: 0) }
        else { anchors.present(activity) {} }
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
        // An update relaunch is not the user quitting, so the run carries on
        // in the new version instead.
        if relaunchingForUpdate {
            focusStore?.handOffForRelaunch()
        } else {
            focusStore?.stop()
        }
        storeObservation?.invalidate()
    }
}
