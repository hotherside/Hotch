import Foundation

/// `--check-updates`: when an update may interrupt, asserted without Sparkle,
/// a feed, a download or a window.
///
/// The promises being kept are the ones a screenshot cannot show: an update
/// window never appears over the welcome or a Focus run, an update that
/// downloaded itself never relaunches Hotch while something is open or
/// running, and a restart someone asks for says so and asks first when it
/// would end something. Plus the guard that keeps the check modes, the
/// snapshot renders and `swift run` from starting Sparkle without a feed.
@MainActor
enum UpdateCheck {
    static func runBlockingAndExit() -> Never {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok    \(name)")
            } else {
                failures += 1
                let suffix = detail().isEmpty ? "" : " \u{2014} \(detail())"
                print("  FAIL  \(name)\(suffix)")
            }
        }

        typealias Moment = UpdatePolicy.Moment
        let idle = Moment()

        print("a scheduled update window")
        check("may appear when Hotch is idle", UpdatePolicy.sparkleShowsScheduledUpdate(idle))
        check("never over the welcome",
              !UpdatePolicy.sparkleShowsScheduledUpdate(Moment(welcomeOpen: true)))
        check("never during a Focus run",
              !UpdatePolicy.sparkleShowsScheduledUpdate(Moment(focusRunning: true)))
        check("never during a paused Focus run",
              !UpdatePolicy.sparkleShowsScheduledUpdate(Moment(focusPaused: true)))
        check("may appear behind an open card or Settings",
              UpdatePolicy.sparkleShowsScheduledUpdate(Moment(settingsOpen: true, cardOpen: true)))

        print("an automatic install")
        check("may relaunch when nothing is open or running", UpdatePolicy.isQuiet(idle))
        let busy: [(String, Moment)] = [
            ("the card is open", Moment(cardOpen: true)),
            ("a Focus timer is running", Moment(focusRunning: true)),
            ("Backpack mode is on", Moment(backpackActive: true)),
            ("the welcome is open", Moment(welcomeOpen: true)),
            ("Settings is open", Moment(settingsOpen: true)),
        ]
        for (reason, moment) in busy {
            check("waits while \(reason)", !UpdatePolicy.isQuiet(moment))
        }
        check("does not wait for a paused Focus run, which comes back paused",
              UpdatePolicy.isQuiet(Moment(focusPaused: true)))
        check("waits for a quiet minute, not a quiet instant", UpdatePolicy.quietFor >= 30)
        let now = Date()
        check("waits a full minute after a card closes, not until the next look",
              !UpdatePolicy.mayInstall(idle, busyAt: now.addingTimeInterval(-2), now: now))
        check("goes ahead once that minute has passed",
              UpdatePolicy.mayInstall(idle, busyAt: now.addingTimeInterval(-UpdatePolicy.quietFor), now: now))
        let updater = AppUpdater.shared
        updater.noteActivity(now: .distantPast)
        let card = CardPresence()
        card.visible = true
        card.visible = false
        check("a card opening or closing restarts the minute", updater.busyAt >= now)
        updater.noteActivity(now: .distantPast)
        let notch = PanelModel()
        notch.expanded = true
        notch.expanded = false
        check("so does the notch panel", updater.busyAt >= now)

        print("a restart someone asked for")
        check("the command says it restarts once an update has downloaded",
              AppUpdater.actionTitle(for: .ready(version: "2.4.1")) == "Restart to Install Hotch 2.4.1")
        check("and checks otherwise",
              AppUpdater.actionTitle(for: nil) == "Check for Updates\u{2026}")
        check("goes ahead at once when nothing would be lost",
              UpdatePolicy.restartWarning(idle) == nil
                && UpdatePolicy.restartWarning(Moment(settingsOpen: true, cardOpen: true)) == nil
                && UpdatePolicy.restartWarning(Moment(focusPaused: true)) == nil)
        check("asks first during a Backpack session",
              UpdatePolicy.restartWarning(Moment(backpackActive: true))?.contains("Backpack") == true)
        check("asks first during a counting Focus run",
              UpdatePolicy.restartWarning(Moment(focusRunning: true))?.contains("Focus") == true)
        check("names both when both would be interrupted",
              UpdatePolicy.restartWarning(Moment(focusRunning: true, backpackActive: true))
                .map { $0.contains("Backpack") && $0.contains("Focus") } == true)

        print("an unconfigured copy")
        // `.build/release/Hotch` has no Info.plist, so no feed and no key.
        check("has no feed to read", !AppUpdater.isConfigured)
        AppUpdater.shared.start()
        check("does not start Sparkle", !AppUpdater.shared.isRunning)

        print(failures == 0 ? "\nupdates: all checks passed"
                            : "\nupdates: \(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
