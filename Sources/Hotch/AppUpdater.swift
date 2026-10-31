import AppKit
import Combine
import Sparkle
import SwiftUI

/// When an update may interrupt, as pure functions so `--check-updates` can
/// assert them without Sparkle, a feed or a window.
enum UpdatePolicy {
    /// What Hotch is doing at the moment Sparkle asks.
    struct Moment: Equatable {
        var welcomeOpen = false
        var settingsOpen = false
        var cardOpen = false
        /// A Focus run whose clock is counting.
        var focusRunning = false
        /// A Focus run on pause. A relaunch brings it back paused, as it was.
        var focusPaused = false
        var backpackActive = false
    }

    /// Whether Sparkle may put a *scheduled* update window up itself.
    ///
    /// Never over the welcome, which is someone's first minute with the app,
    /// and never during a Focus run, counting or paused, which is the one time
    /// Hotch has promised to keep quiet. Otherwise Sparkle's own rules for
    /// background apps apply: it shows the window behind whatever is in front,
    /// and only takes focus right after launch. In both excluded cases the
    /// card's update line is the reminder, and nothing is lost by waiting for
    /// it to be noticed.
    static func sparkleShowsScheduledUpdate(_ moment: Moment) -> Bool {
        !moment.welcomeOpen && !moment.focusRunning && !moment.focusPaused
    }

    /// Whether an update that downloaded itself may install and relaunch now.
    ///
    /// A relaunch takes the companion off screen for a second or two, closes
    /// any window and would end a Backpack session (the helper restores sleep
    /// when Hotch goes), so it waits until nothing is open or running. Quitting
    /// installs it anyway, so the wait is never longer than the next quit.
    /// A paused Focus run does not hold it: the relaunch brings the run back
    /// paused, and Sparkle does not check again while an update waits, so
    /// holding it for a run left paused could mean weeks on an old version.
    static func isQuiet(_ moment: Moment) -> Bool {
        !moment.cardOpen && !moment.focusRunning && !moment.backpackActive
            && !moment.welcomeOpen && !moment.settingsOpen
    }

    /// Whether to install now: quiet, and quiet for `quietFor` since anything
    /// was last open or running. `busyAt` moves on whenever a card or window
    /// closes, so a card glanced at between two looks still gets its minute.
    static func mayInstall(_ moment: Moment, busyAt: Date, now: Date) -> Bool {
        isQuiet(moment) && now.timeIntervalSince(busyAt) >= quietFor
    }

    /// How long the moment has to stay quiet before a relaunch, so closing the
    /// card is not instantly followed by the companion vanishing.
    static let quietFor: TimeInterval = 60

    /// What a restart someone asked for would interrupt, for its confirmation;
    /// nil when nothing is lost and it can go ahead at once. The open card or
    /// Settings is where the request comes from, so neither counts, and a
    /// paused Focus run comes back as it was.
    static func restartWarning(_ moment: Moment) -> String? {
        let backpack = "This ends the Backpack session, so closing the lid puts your Mac to sleep again."
        let focus = "Your Focus timer keeps counting and carries on after the restart."
        switch (moment.backpackActive, moment.focusRunning) {
        case (true, true): return backpack + " " + focus
        case (true, false): return backpack
        case (false, true): return "Hotch closes for a second or two. " + focus
        case (false, false): return nil
        }
    }
}

/// In-app updates, through Sparkle.
///
/// Ask first by default: Sparkle checks the appcast once a day and shows its
/// standard window with the release notes and Install, Remind Me Later and
/// Skip This Version. Downloading and installing without asking is an opt-in
/// in Settings, and even then the relaunch waits for a quiet moment.
///
/// Hotch is a menu bar app that rarely quits, so a scheduled check usually
/// lands while it is in the background. It uses Sparkle's gentle reminders for
/// that: see `UpdatePolicy` for when the window may appear, and the card's
/// footer for the line that brings it back.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// An update waiting on the user, for the card's footer and the menu.
    enum Offer: Equatable {
        /// Found; Sparkle's window shows the notes and the choices.
        case available(version: String)
        /// Downloaded by itself and waiting for a quiet moment to install.
        case ready(version: String)
    }

    @Published private(set) var offer: Offer?
    @Published private(set) var canCheck = false
    @Published private(set) var checksAutomatically = true
    @Published private(set) var installsAutomatically = false

    /// What Hotch is doing right now. Wired by AppDelegate.
    var moment: () -> UpdatePolicy.Moment = { UpdatePolicy.Moment() }
    /// Called just before Sparkle quits the app to relaunch the new version.
    var onWillRelaunch: () -> Void = {}

    /// When something was last open or running, or a card or window closed.
    /// A downloaded update installs only a full `UpdatePolicy.quietFor` later.
    private(set) var busyAt = Date()

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var quietWatch: Timer?
    private var cancellables: Set<AnyCancellable> = []

    /// False for a copy without a feed and key in its Info.plist: `swift run`
    /// out of `.build`, the check modes and the snapshot renders. Starting
    /// Sparkle there would only put an error alert on screen.
    nonisolated static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    var isRunning: Bool { controller != nil }

    /// When Sparkle last asked the feed, for Settings.
    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    /// The update command's title, the same in the Hotch menu and Settings,
    /// so a click that will restart Hotch says so.
    var actionTitle: String { Self.actionTitle(for: offer) }

    static func actionTitle(for offer: Offer?) -> String {
        switch offer {
        case .available(let version): return "Update to Hotch \(version)\u{2026}"
        case .ready(let version): return "Restart to Install Hotch \(version)"
        case nil: return "Check for Updates\u{2026}"
        }
    }

    /// False only while Sparkle is already checking and nothing is waiting.
    var canAct: Bool { canCheck || offer != nil }

    func start() {
        guard controller == nil, AppUpdater.isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self,
                                                      userDriverDelegate: self)
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            // Logged rather than alerted: an updater that cannot start is the
            // maintainer's problem, and an alert at login would make it the
            // user's.
            hotchLog.error("updates unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.controller = controller
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.checksAutomatically = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.installsAutomatically = $0 }
            .store(in: &cancellables)
        // Settings, the welcome and Sparkle's own window: closing one is as
        // recent a sign of someone at the Mac as a card closing.
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] _ in self?.noteActivity() }
            .store(in: &cancellables)
    }

    // MARK: Actions

    /// The update command in Settings, the menu and the card: a user-initiated
    /// check, the pending update brought back to the front, or a downloaded
    /// one installed now.
    func checkForUpdates() {
        if case .ready(let version) = offer, let installNow {
            guard confirmRestart(installing: version) else { return }
            quietWatch?.invalidate()
            quietWatch = nil
            installNow()
            return
        }
        controller?.checkForUpdates(nil)
    }

    /// A card opened or closed. The quiet minute before an automatic install
    /// starts again from now. Called by the cards themselves, because a card
    /// can come and go between two looks of the quiet watch.
    func noteActivity(now: Date = Date()) {
        busyAt = now
    }

    /// A restart asked for in Settings, the menu or the card is immediate,
    /// unless it would end a Backpack session or interrupt a counting Focus
    /// run: then it asks first.
    private func confirmRestart(installing version: String) -> Bool {
        guard let warning = UpdatePolicy.restartWarning(moment()) else { return true }
        let alert = NSAlert()
        alert.icon = HotchIcon.appIconImage()
        alert.messageText = "Restart Hotch to install \(version)?"
        alert.informativeText = warning
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func setChecksAutomatically(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    func setInstallsAutomatically(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
    }

    // MARK: Quiet moments

    private func watchForQuietMoment() {
        quietWatch?.invalidate()
        busyAt = Date()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietWatch = timer
    }

    private func installIfQuiet(now: Date = Date()) {
        guard let installNow else {
            quietWatch?.invalidate()
            quietWatch = nil
            return
        }
        // Switched off since it downloaded: no relaunch unasked. It still
        // installs at quit, or now from the card's Restart.
        let moment = self.moment()
        guard installsAutomatically, UpdatePolicy.isQuiet(moment) else {
            busyAt = now
            return
        }
        guard UpdatePolicy.mayInstall(moment, busyAt: busyAt, now: now) else { return }
        hotchLog.log("installing a downloaded update at a quiet moment")
        quietWatch?.invalidate()
        quietWatch = nil
        installNow()
    }
}

// MARK: - Sparkle's updater

extension AppUpdater: SPUUpdaterDelegate {
    /// Anonymous system profiling stays off, whatever a future Sparkle default
    /// or a stray user default says: no hardware or OS details ride along with
    /// the appcast request.
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }

    /// Only reached when the user opted into automatic installs: the update has
    /// downloaded silently. Taking it over means it installs at a quiet moment
    /// rather than only at the next quit, which for Hotch can be weeks away.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        offer = .ready(version: item.displayVersionString)
        hotchLog.log("update \(item.displayVersionString, privacy: .public) downloaded; installing at a quiet moment")
        watchForQuietMoment()
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        hotchLog.log("relaunching for an update")
        onWillRelaunch()
    }
}

// MARK: - Sparkle's window

extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        let version = update.displayVersionString
        return MainActor.assumeIsolated {
            let shows = UpdatePolicy.sparkleShowsScheduledUpdate(moment())
            hotchLog.log("update \(version, privacy: .public) found: \(shows ? "Sparkle shows it" : "left to the card line", privacy: .public)")
            return shows
        }
    }

    /// Every found update gets the card line, whether Sparkle shows its window
    /// now, shows it behind other apps, or leaves it to the line entirely.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            offer = .available(version: version)
        }
    }

    /// Skipped, put off, failed or dismissed. A reminder comes back with the
    /// next scheduled check.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            if case .available = offer { offer = nil }
        }
    }
}

// MARK: - The card's line

/// The footer line that stands in for an update window Hotch chose not to
/// show, or one that went behind other apps. Click to bring it back.
struct UpdateFooterLine: View {
    let offer: AppUpdater.Offer
    var fontSize: CGFloat = 11
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(HP.ok)
                // The menu bar card's footer has three more buttons than the
                // edge card's, and the version is what gives way first.
                ViewThatFits(in: .horizontal) {
                    Text(label)
                    Text(shortLabel)
                }
                .foregroundStyle(HP.text2)
                .lineLimit(1)
            }
            .font(.system(size: fontSize))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var label: String {
        switch offer {
        case .available(let version): return "Update available \u{00B7} Hotch \(version)"
        case .ready(let version): return "Hotch \(version) ready \u{00B7} Restart"
        }
    }

    private var shortLabel: String {
        switch offer {
        case .available: return "Update available"
        case .ready: return "Restart to update"
        }
    }

    private var help: String {
        switch offer {
        case .available(let version): return "Show what's new in Hotch \(version)"
        case .ready(let version): return "Restart Hotch now to finish updating to \(version)"
        }
    }
}
