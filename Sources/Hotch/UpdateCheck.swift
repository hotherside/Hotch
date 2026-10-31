import Foundation

/// `--check-updates`: when an update may interrupt, asserted without Sparkle,
/// a feed, a download or a window.
///
/// The promises being kept are the ones a screenshot cannot show: an update
/// window never appears over the welcome or a Focus run, and an update that
/// downloaded itself never relaunches Hotch while something is open or
/// running. Plus the guard that keeps the check modes, the snapshot renders
/// and `swift run` from starting Sparkle without a feed to read.
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
        check("waits for a quiet minute, not a quiet instant", UpdatePolicy.quietFor >= 30)

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
