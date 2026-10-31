import AppKit

/// `--demo-tour` runs the real anchors on the snapshot fixture and plays one
/// fixed sequence, so the README and marketing showcase can be recorded with
/// the app's own motion instead of an imitation of it.
///
/// Nothing is fetched or scanned: the stores hold the same demo data as the
/// snapshot renders. Placements live in a scratch defaults domain that is
/// cleared before and after, so a tour never moves the person's own Hotch, and
/// a 14" MacBook Pro notch is stood in on whatever display it runs on.
///
/// It prints `ready`, waits for a line on stdin (a recorder's cue, or Return in
/// a terminal), then prints `step <seconds> <name>` as each step starts, so two
/// takes (light and dark) can be lined up frame for frame. `--demo-tour-now`
/// starts without waiting. Appearance follows `--snapshot-dark`.
@MainActor
final class DemoTour {
    static let suite = "com.hojaejung.hotch.demo-tour"

    private let anchors: AnchorManager
    private let prefs = HotchPrefs.shared
    private let alerts = LiveActivityController()
    private var started = Date()

    /// The same alert the snapshot parts show, held long enough to read.
    private var alert: LiveActivity {
        var activity = LiveActivity(icon: .brand("codex"), leading: "Refactor upload…", trailing: "needs approval",
                                    tint: .white, trailingTint: HP.amber, dot: true, key: "need-demo")
        activity.hold = 4.0
        return activity
    }

    static func runAndExit(dark: Bool, waitForCue: Bool) -> Never {
        // Every override is set before anything reads the shared instances.
        UserDefaults.standard.removePersistentDomain(forName: suite)
        HotchPrefs.defaultsOverride = UserDefaults(suiteName: suite)
        let history = UsageHistoryStore(persists: false)
        Snapshot.seedDemoHistory(into: history)
        UsageHistoryStore.sharedOverride = history
        AppSettings.displayModeOverride = .used
        NotchGeometryResolver.simulatedNotch = CGSize(width: Snapshot.sampleNotchWidth,
                                                     height: Snapshot.sampleNotchClearance)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let tour = DemoTour()
        print("ready")
        fflush(stdout)
        if waitForCue {
            Thread.detachNewThread {
                _ = readLine()
                DispatchQueue.main.async { MainActor.assumeIsolated { tour.begin() } }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { tour.begin() } }
        }
        app.run()
        exit(0)
    }

    private init() {
        let store = UsageStore(providers: [ClaudeProvider(allowRemote: false), CodexProvider(allowRemote: false)])
        store.usages = Snapshot.demoUsages()
        store.lastRefresh = Date().addingTimeInterval(-32)
        let sessions = SessionStore()
        sessions.sessions = Snapshot.demoSessions()
        sessions.lastScan = Date().addingTimeInterval(-4)
        let clipboard = ClipboardStore()
        clipboard.items = Snapshot.demoClipboardItems()
        let focus = FocusStore(persists: false)
        Snapshot.seedDemoFocus(into: focus)
        let system = SystemMonitor.shared
        system.applyDemo(SystemDemo.make())

        anchors = AnchorManager(deps: CardDeps(store: store, sessionStore: sessions, clipboard: clipboard,
                                               focus: focus, system: system, backpack: BackpackManager.shared,
                                               pages: PopoverPageModel()))
        anchors.onNotchActivity = { [alerts] activity in alerts.post(activity, cooldown: 0) }
        alerts.panelIsOpen = { [weak anchors] in anchors?.isShown ?? false }

        prefs.anchor = .menuBar
        prefs.edgeSide = .right
        prefs.edgeOffset = 0.3
        prefs.floatX = 1
        prefs.floatY = 0.4
        prefs.bottomOffset = 0.355
        prefs.notchAlerts = true
        prefs.advancedSensors = false
    }

    /// Seconds from the cue. Each page holds long enough for a caption and its line.
    private var steps: [(at: TimeInterval, name: String, run: () -> Void)] {
        [
            (0.0, "edge", { [self] in prefs.edgeSide = .right; anchors.apply(.edge) }),
            (2.0, "open-ai", { [self] in anchors.open(.ai) }),
            (6.5, "open-desk", { [self] in anchors.open(.desk) }),
            (11.0, "open-mac", { [self] in anchors.open(.mac) }),
            (15.5, "close", { [self] in anchors.dismiss() }),
            (17.0, "alert-edge", { [self] in anchors.present(alert) {} }),
            (22.0, "notch", { [self] in anchors.apply(.notch) }),
            (24.0, "open-notch", { [self] in anchors.open(.home) }),
            (29.0, "close-notch", { [self] in anchors.dismiss() }),
            (30.5, "alert-notch", { [self] in alerts.post(alert, cooldown: 0) }),
            (36.0, "pill", { [self] in anchors.apply(.pill) }),
            (37.2, "alert-pill", { [self] in anchors.present(alert) {} }),
            (41.0, "orb", { [self] in anchors.apply(.orb) }),
            (42.2, "alert-orb", { [self] in anchors.present(alert) {} }),
            (46.0, "dock", { [self] in prefs.edgeSide = .bottom; anchors.apply(.edge) }),
            (47.2, "alert-dock", { [self] in anchors.present(alert) {} }),
            (52.0, "end", { [self] in finish() }),
        ]
    }

    private func begin() {
        started = Date()
        run(0)
    }

    /// Each step is timed from the one before it, so a stall on the main
    /// thread delays what follows instead of bunching it up.
    private func run(_ index: Int) {
        let list = steps
        let step = list[index]
        print(String(format: "step %.3f %@", Date().timeIntervalSince(started), step.name))
        fflush(stdout)
        step.run()
        // Where things landed, so a recording can be annotated afterwards.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let frames = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }
                .map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" }
            print("frames \(step.name) \(frames.joined(separator: " "))")
            fflush(stdout)
        }
        guard index + 1 < list.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + list[index + 1].at - step.at) { [self] in
            MainActor.assumeIsolated { run(index + 1) }
        }
    }

    private func finish() {
        anchors.apply(.menuBar)
        UserDefaults.standard.removePersistentDomain(forName: Self.suite)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
    }
}
