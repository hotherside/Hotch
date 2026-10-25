import Foundation

/// Preference migration, welcome copy, choreography and spotlight placement
/// checks; no real defaults or windows touched. With `--snapshot-welcome
/// <dir>` it then renders the welcome for the docs (see `WelcomeSnapshot`).
enum OnboardingCheck {
    static func runBlockingAndExit() -> Never {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("  \(passed ? "ok  " : "FAIL")  \(name)")
            if !passed { failures += 1 }
        }
        check("a fresh install is recognized", !OnboardingPolicy.hasExistingPreferences([:]))
        check("global macOS settings do not imply an upgrade",
              !OnboardingPolicy.hasExistingPreferences(["AppleLanguages": ["en"], "AppleShowScrollBars": "Always"]))
        check("migration bookkeeping alone does not imply an upgrade",
              !OnboardingPolicy.hasExistingPreferences(["migratedFromLegacyBundleIDs": true]))
        for key in ["hasLaunchedBefore", "enabledProviderIDs", "disabledProviderIDs", "anchor", "refreshInterval"] {
            check("existing preference \(key) identifies an upgrade",
                  OnboardingPolicy.hasExistingPreferences([key: true]))
        }
        check("fresh clipboard history requires opt-in",
              !OnboardingPolicy.clipboardEnabled(stored: nil, existingInstall: false))
        check("upgrades preserve the old clipboard default",
              OnboardingPolicy.clipboardEnabled(stored: nil, existingInstall: true))
        for existing in [false, true] {
            for stored in [false, true] {
                check("explicit clipboard \(stored) survives existing=\(existing)",
                      OnboardingPolicy.clipboardEnabled(stored: stored, existingInstall: existing) == stored)
            }
        }
        check("fresh installs see welcome",
              !OnboardingPolicy.welcomeCompleted(stored: nil, existingInstall: false))
        check("upgrades remain quiet",
              OnboardingPolicy.welcomeCompleted(stored: nil, existingInstall: true))
        check("unfinished welcome resumes even after defaults have been written",
              !OnboardingPolicy.welcomeCompleted(stored: false, existingInstall: true))
        check("finished welcome stays finished",
              OnboardingPolicy.welcomeCompleted(stored: true, existingInstall: true))

        // The letter's words.
        check("the letter opens with the agreed greeting", WelcomeCopy.greeting == "Hello, welcome to Hotch.")
        check("the letter signs off as Hojae", WelcomeCopy.signOff == "Thanks, Hojae")
        check("the letter ends with the contact address", WelcomeCopy.contact == "hello@hotherside.com")
        check("an installed copy gets no install note", WelcomeCopy.installNote(installed: true, onDiskImage: true) == nil)
        check("a copy on the disk image is told so",
              WelcomeCopy.installNote(installed: false, onDiskImage: true) == WelcomeCopy.onDiskImage)
        check("a translocated copy is not told it is on the disk image",
              WelcomeCopy.installNote(installed: false, onDiskImage: false) == WelcomeCopy.translocated)
        check("welcome copy has no em dashes", !WelcomeCopy.all.contains { $0.contains("\u{2014}") })
        check("each screen edge is named where Hotch lands",
              WelcomeCopy.whereItLives(.edge, side: .right, realNotch: false).contains("right edge")
                && WelcomeCopy.whereItLives(.edge, side: .left, realNotch: false).contains("left edge")
                && WelcomeCopy.whereItLives(.edge, side: .bottom, realNotch: false).contains("Dock"))

        // The greeting's choreography.
        let start = WelcomeTimeline(time: 0), end = WelcomeTimeline.settled
        check("the greeting starts empty",
              start.curve == 0 && start.signal == 0 && start.glow == 0 && start.line(0) == 0 && start.footer == 0)
        check("the greeting settles complete",
              end.curve == 1 && abs(end.signal - 1) < 0.0001 && end.ripple == 1 && end.glow == 1 && end.footer == 1
                && (0..<WelcomeTimeline.lineCount).allSatisfy { end.line($0) == 1 })
        check("the curve is drawn before the signal arrives",
              WelcomeTimeline(time: 0.9).curve > 0.6 && WelcomeTimeline(time: 0.9).signal == 0)
        check("each line eases in after the one before", stride(from: 0.0, through: 3.0, by: 0.05).allSatisfy { t in
            let moment = WelcomeTimeline(time: t)
            return (1..<WelcomeTimeline.lineCount).allSatisfy { moment.line($0) <= moment.line($0 - 1) }
        })

        // Pointing at the companion: a 14-inch display with the Dock at the bottom.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)
        let note = CGSize(width: 296, height: 118)
        let targets: [(String, CGRect, SpotlightSide)] = [
            ("right edge tab", CGRect(x: 1466, y: 400, width: 46, height: 224), .left),
            ("left edge tab", CGRect(x: 0, y: 400, width: 46, height: 224), .right),
            ("edge tab near the top", CGRect(x: 1466, y: 720, width: 46, height: 224), .left),
            ("bar beside the Dock", CGRect(x: 120, y: 5, width: 230, height: 58), .above),
            ("notch", CGRect(x: 666, y: 949, width: 180, height: 33), .below),
            ("menu bar icon", CGRect(x: 1460, y: 949, width: 28, height: 33), .below),
            ("pill at the top right", CGRect(x: 1290, y: 905, width: 210, height: 32), .below),
            ("orb near the bottom", CGRect(x: 30, y: 82, width: 40, height: 40), .above),
        ]
        for (name, target, expected) in targets {
            let placed = SpotlightPlacement.note(size: note, target: target, screen: screen, visible: visible)
            let along = placed.side == .left || placed.side == .right ? note.height : note.width
            check("the note faces the open screen from the \(name)", placed.side == expected)
            check("the note stays on screen beside the \(name)",
                  visible.insetBy(dx: SpotlightPlacement.margin - 0.5, dy: SpotlightPlacement.margin - 0.5)
                    .contains(placed.frame))
            check("the note leaves the \(name) uncovered", !placed.frame.intersects(target))
            check("the arrow stays on the note's edge for the \(name)",
                  placed.arrow >= SpotlightPlacement.arrowInset && placed.arrow <= along - SpotlightPlacement.arrowInset)
        }
        let orb = SpotlightPlacement.ring(around: CGRect(x: 30, y: 82, width: 40, height: 40))
        check("the ring around the orb is round", abs(orb.radius - orb.frame.width / 2) < 0.001)

        print("Welcome checks: \(failures == 0 ? "passed" : "failed")")
        if failures == 0, let index = CommandLine.arguments.firstIndex(of: "--snapshot-welcome") {
            let next = CommandLine.arguments.index(after: index)
            let directory = next < CommandLine.arguments.endIndex ? CommandLine.arguments[next] : "build/welcome"
            MainActor.assumeIsolated { WelcomeSnapshot.run(directory: directory) }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
