import AppKit
import ServiceManagement

/// Where the running app actually lives, and whether that is somewhere it can
/// work properly.
///
/// This exists because of App Translocation, which is easy to ship without ever
/// meeting. When macOS launches a quarantined app from somewhere the user has
/// not deliberately installed it — most commonly by double-clicking it inside
/// the disk image instead of dragging it across first — it does not run the
/// bundle where it sits. It copies it to a randomised read-only path under
/// `/private/var/folders/.../AppTranslocation/<uuid>/d/` and runs that, so a
/// malicious download cannot rely on the files sitting next to it.
///
/// Hotch looks completely fine when translocated. It launches, reads usage, and
/// draws the panel, because everything it needs comes from the user's home
/// directory and the Keychain rather than from beside the executable. What
/// breaks is anything that has to name the app's own location later:
///
/// - **Launch at Login.** `SMAppService.mainApp.register()` records the bundle's
///   current path. Translocated, that path is a temporary folder which is gone
///   by the next boot, so the login item either fails outright or registers a
///   ghost. The failure is silent — the menu item just does not stick.
/// - **Ejecting the image** leaves an orphaned copy running with nothing behind
///   it.
/// - **Every launch gets a new random path**, so even the state that does get
///   written is written somewhere different each time.
///
/// Verified on macOS 26.5.2 during the 1.0 release check: a quarantined copy
/// launched from outside /Applications ran from
/// `/private/var/folders/.../AppTranslocation/BF29BA62-.../d/Hotch.app`.
///
/// There is a Security framework call for this — `SecTranslocateIsTranslocatedURL`
/// — but it is C-only and not surfaced in the Swift overlay, so the path check
/// stands in for it. The marker directory name is stable and load-bearing in
/// macOS itself, which is about as much of a contract as a path ever gets.
enum InstallLocation {
    /// The randomised read-only container macOS runs untrusted-location apps in.
    private static let translocationMarker = "/AppTranslocation/"

    static var bundlePath: String { Bundle.main.bundleURL.path }

    /// True when this process is running out of a translocated copy rather than
    /// the bundle the user can see in Finder.
    static var isTranslocated: Bool {
        bundlePath.contains(translocationMarker)
    }

    /// True when the app is running straight off a mounted volume — the disk
    /// image itself, or a USB stick. Not translocated, but still not installed:
    /// ejecting pulls the app out from under itself.
    static var isOnMountedVolume: Bool {
        bundlePath.hasPrefix("/Volumes/")
    }

    /// The one question the rest of the app asks: can this copy keep a promise
    /// about where it will be tomorrow?
    static var isProperlyInstalled: Bool {
        !isTranslocated && !isOnMountedVolume
    }

    /// Shown once at launch when the app is not installed anywhere durable.
    ///
    /// Deliberately not fatal. Someone who just wants to look at Hotch before
    /// deciding where to put it should be allowed to, and refusing to start
    /// would be a worse first impression than the problem being described. The
    /// alert names the actual consequence rather than saying "please install
    /// properly", because the consequence is the part that is not obvious.
    @MainActor
    static func warnIfNotInstalled() {
        guard !isProperlyInstalled else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = HotchIcon.appIconImage()
        alert.messageText = "Move Hotch to your Applications folder"

        // Two different situations reach here and they need different first
        // sentences. Running off the mounted image is the common one and can say
        // so plainly. Translocation cannot: the bundle path it can see is a
        // temporary folder, and the *original* location is deliberately hidden
        // from the process — recovering it needs SecTranslocateCreateOriginalPathForURL,
        // which is C-only. So that branch describes what happened rather than
        // guessing where the app is, and both end on the same remedy, because
        // dragging it in Finder is what actually clears the condition.
        let cause = isOnMountedVolume
            ? "Hotch is running from the disk image rather than from your Applications folder."
            : "macOS is running Hotch from a temporary copy, which it does when an app "
              + "is opened before being moved into place."

        alert.informativeText = """
            \(cause)

            It works for now, but Launch at Login cannot be switched on, and this \
            copy is discarded when you eject the image or restart.

            Quit Hotch, drag Hotch.app into your Applications folder in Finder, \
            then open it from there.
            """
        alert.addButton(withTitle: "Open Applications Folder")
        alert.addButton(withTitle: "Continue Anyway")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
        }
    }

    /// The same explanation, for the moment someone tries the thing that cannot
    /// work rather than at launch.
    @MainActor
    static func explainLoginItemUnavailable() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = HotchIcon.appIconImage()
        alert.messageText = "Move Hotch to Applications first"
        alert.informativeText = """
            Launch at Login remembers where the app is, and this copy is running \
            from a temporary folder that will not exist at the next restart.

            Quit Hotch, drag Hotch.app into your Applications folder in Finder, \
            then open it from there and switch this on.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Launch at login

/// Opening at login, in one place because two surfaces offer it.
///
/// The toggle existed from 1.0 but lived **only in the status item menu**, which
/// is the one surface this app already knows can be unreachable: the notch eats
/// the middle of the menu bar, macOS silently drops whatever no longer fits, and
/// Hotch — something you glance at rather than work in — is exactly the icon
/// that gets pushed off the end. That is the stated reason Settings exists at
/// all, and it applies to this setting more than to any other, because someone
/// who cannot find the menu is left restarting the app by hand after every boot
/// and concluding the feature is missing. It is in Settings now, and the menu
/// keeps its item; both call this.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the change took, so a checkbox can put itself back
    /// rather than showing a state the system did not agree to.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        // A translocated copy would register a path that stops existing at the
        // next restart, and the registration failure is silent — the checkmark
        // simply never appears. Saying why beats letting someone click it three
        // times.
        guard InstallLocation.isProperlyInstalled else {
            InstallLocation.explainLoginItemUnavailable()
            return isEnabled
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Hotch: launch at login toggle failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
