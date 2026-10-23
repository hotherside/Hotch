import AppKit

// CLI modes all run before the GUI is ever started.
let npArguments = CommandLine.arguments

/// Optional path immediately after a flag, otherwise the given default.
func npValue(after flag: String, default fallback: String) -> String {
    guard let index = npArguments.firstIndex(of: flag) else { return fallback }
    let next = npArguments.index(after: index)
    guard next < npArguments.endIndex, !npArguments[next].hasPrefix("--") else { return fallback }
    return npArguments[next]
}

// Renders either direction without disturbing the stored preference, so a
// comparison can be produced without the user's own settings being the fixture.
// Applied before anything reads AppSettings.shared.
if npArguments.contains("--display-mode") {
    let raw = npValue(after: "--display-mode", default: UsageDisplayMode.used.rawValue)
    guard let mode = UsageDisplayMode(rawValue: raw) else {
        FileHandle.standardError.write(Data("--display-mode must be used or remaining\n".utf8))
        exit(2)
    }
    AppSettings.displayModeOverride = mode
}

// `Hotch --toggle` opens or closes the card in the running app, the same as
// ⌥⌘H, for Raycast, Shortcuts or a script.
if npArguments.contains("--toggle") {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.hojaejung.hotch.toggle"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

// Shows a sample alert on the running app, so the speaking shapes can be
// checked on screen without waiting for a real event.
if npArguments.contains("--test-alert") {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.hojaejung.hotch.test-alert"), object: nil,
        userInfo: ["key": npValue(after: "--test-alert", default: "need-test")], deliverImmediately: true)
    exit(0)
}

if npArguments.contains("--connect-claude") {
    ConnectCLI.runBlockingAndExit(dryRun: npArguments.contains("--dry-run"))
}
if npArguments.contains("--diag-full") {
    Diagnostics.runBlockingAndExit(full: true)
}
if npArguments.contains("--diag") {
    Diagnostics.runBlockingAndExit(full: false)
}
if npArguments.contains("--check-rail") {
    RailGeometryCheck.runBlockingAndExit()
}
if npArguments.contains("--check-session-handoff") {
    SessionHandoffCheck.runBlockingAndExit()
}
if npArguments.contains("--check-welcome") {
    MainActor.assumeIsolated { OnboardingCheck.runBlockingAndExit() }
}
if npArguments.contains("--check-focus") {
    MainActor.assumeIsolated {
        FocusCheck.runBlockingAndExit()
    }
}
if npArguments.contains("--check-notch") {
    MainActor.assumeIsolated { NotchGeometryCheck.runBlockingAndExit() }
}
if npArguments.contains("--check-credentials") {
    CredentialStoreCheck.runBlockingAndExit()
}
if npArguments.contains("--render-icon") {
    IconCLI.runBlockingAndExit(
        directory: npValue(after: "--render-icon", default: "build/AppIcon.iconset")
    )
}
if npArguments.contains("--render-dmg-background") {
    InstallerArtCLI.runBlockingAndExit(
        path: npValue(after: "--render-dmg-background", default: "build/dmg-background.tiff")
    )
}
// The real window, hosting real AppKit controls, clipped to the real viewport.
// --snapshot-settings renders the whole column flat instead; both are wanted.
if npArguments.contains("--snapshot-settings-window") {
    MainActor.assumeIsolated {
        Snapshot.runSettingsWindowAndExit(
            path: npValue(after: "--snapshot-settings-window",
                          default: "build/settings-window.png")
        )
    }
}
if npArguments.contains("--snapshot-settings") {
    MainActor.assumeIsolated {
        Snapshot.runSettingsAndExit(
            path: npValue(after: "--snapshot-settings", default: "build/settings.png")
        )
    }
}
if npArguments.contains("--snapshot-statusbar") {
    MainActor.assumeIsolated {
        Snapshot.runStatusBarAndExit(
            path: npValue(after: "--snapshot-statusbar", default: "build/statusbar.png")
        )
    }
}
// Which page a panel or popover snapshot renders. Combines with any of the
// snapshot modes below; the default is the home page, so existing invocations
// keep producing exactly what they always did.
let npSnapshotPage: PanelPage = {
    guard npArguments.contains("--snapshot-page") else { return .now }
    let raw = npValue(after: "--snapshot-page", default: "now")
    guard let page = PanelPage(argument: raw) else {
        FileHandle.standardError.write(
            Data("--snapshot-page must be now, ai, agents, mac, focus or clipboard\n".utf8))
        exit(2)
    }
    return page
}()
/// `--snapshot-detail cpu|gpu|memory|network|disk|power` opens that Mac tile.
let npSnapshotDetail: SystemDetailKind? = npArguments.contains("--snapshot-detail")
    ? SystemDetailKind(rawValue: npValue(after: "--snapshot-detail", default: "cpu")) : nil
/// `--snapshot-backpack` shows the Backpack card instead of the section.
let npSnapshotBackpack = npArguments.contains("--snapshot-backpack")

if npArguments.contains("--probe-thermals") {
    Snapshot.runThermalProbeAndExit()
}

if npArguments.contains("--probe-card") {
    MainActor.assumeIsolated { Snapshot.runCardProbeAndExit() }
}
if npArguments.contains("--snapshot-overview") {
    MainActor.assumeIsolated {
        Snapshot.runOverviewAndExit(path: npValue(after: "--snapshot-overview", default: "build/overview.png"),
                                   dark: npArguments.contains("--snapshot-dark"), page: npSnapshotPage)
    }
}
if npArguments.contains("--snapshot-story") {
    MainActor.assumeIsolated {
        Snapshot.runStoryAndExit(directory: npValue(after: "--snapshot-story", default: "build/story"),
                                dark: npArguments.contains("--snapshot-dark"))
    }
}

if npArguments.contains("--snapshot-anchors") {
    MainActor.assumeIsolated {
        Snapshot.runAnchorsAndExit(path: npValue(after: "--snapshot-anchors", default: "build/anchors.png"),
                                   dark: npArguments.contains("--snapshot-dark"))
    }
}
if npArguments.contains("--snapshot-parts") {
    MainActor.assumeIsolated {
        Snapshot.runPartsAndExit(directory: npValue(after: "--snapshot-parts", default: "build/parts"),
                                 dark: npArguments.contains("--snapshot-dark"))
    }
}
if npArguments.contains("--snapshot-popover-demo") {
    MainActor.assumeIsolated {
        Snapshot.runPopoverAndExit(
            demo: true,
            path: npValue(after: "--snapshot-popover-demo", default: "build/popover-demo.png"),
            page: npSnapshotPage,
            detail: npSnapshotDetail,
            backpackCard: npSnapshotBackpack,
            dark: npArguments.contains("--snapshot-dark"),
            // Two halves: the running readout, or the start row with the
            // remembered length. They cannot share a render because one
            // replaces the other.
            focusIdle: npArguments.contains("--snapshot-focus-idle"),
            // A day with more runs in it than the log will draw. The only way
            // to see the cap bite, the overflow count appear, and the tallest
            // the focus page can ever be — which is the number that decides
            // whether the popover fits a small screen.
            focusFull: npArguments.contains("--snapshot-focus-full")
        )
    }
}
if npArguments.contains("--snapshot-popover") {
    MainActor.assumeIsolated {
        Snapshot.runPopoverAndExit(
            demo: false,
            path: npValue(after: "--snapshot-popover", default: "build/popover.png"),
            page: npSnapshotPage,
            detail: npSnapshotDetail,
            dark: npArguments.contains("--snapshot-dark")
        )
    }
}
// Renders against stand-in notch hardware instead of the virtual notch every
// other mode resolves, so the wings either side of the cutout — which only
// exist on a real MacBook — can be checked without one.
let npRealNotch = npArguments.contains("--snapshot-notch")

if npArguments.contains("--snapshot-demo") {
    MainActor.assumeIsolated {
        Snapshot.runBlockingAndExit(
            demo: true,
            path: npValue(after: "--snapshot-demo", default: "build/snapshot-demo.png"),
            page: npSnapshotPage,
            detail: npSnapshotDetail,
            backpackCard: npSnapshotBackpack,
            realNotch: npRealNotch,
            focusIdle: npArguments.contains("--snapshot-focus-idle"),
            // Panel-only render on transparency, for compositing into
            // marketing images. Meaningless without a page to show, so it
            // rides the demo mode only.
            clearBackground: npArguments.contains("--snapshot-clear")
        )
    }
}
if npArguments.contains("--snapshot") {
    MainActor.assumeIsolated {
        Snapshot.runBlockingAndExit(
            demo: false,
            path: npValue(after: "--snapshot", default: "build/snapshot.png"),
            page: npSnapshotPage,
            detail: npSnapshotDetail,
            realNotch: npRealNotch
        )
    }
}

let app = NSApplication.shared

MainActor.assumeIsolated {
    // The delegate is held by this scope for the lifetime of the run loop
    // because NSApplication.delegate is a weak reference.
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
