import Foundation

/// Pure preference decisions, kept separate so upgrades and a fresh install can
/// be checked without opening a window or touching the real defaults domain.
enum OnboardingPolicy {
    static let completedKey = "welcomeCompleted"

    // Only app-owned keys are evidence of an existing install. Global macOS
    // defaults (languages, scrollers, etc.) must never opt a new user in.
    static let existingPreferenceKeys: Set<String> = [
        "hasLaunchedBefore", "enabledProviderIDs", "disabledProviderIDs",
        "refreshInterval", "usageDisplayMode", "clipboardHistoryEnabled",
        "prunedInheritedDefaultProviders", "grokTeamID", "anchor", "edgeSide",
        "edgeOffset", "bottomOffset", "railDisplay", "floatDisplay", "floatX", "floatY",
        "shortcutEnabled", "menuBarCPU", "menuBarMemory", "menuBarNetwork",
        "notchAlerts", "advancedSensors", completedKey,
    ]

    static func hasExistingPreferences(_ values: [String: Any]) -> Bool {
        !existingPreferenceKeys.isDisjoint(with: values.keys)
    }

    static func clipboardEnabled(stored: Bool?, existingInstall: Bool) -> Bool {
        stored ?? existingInstall
    }

    static func welcomeCompleted(stored: Bool?, existingInstall: Bool) -> Bool {
        stored ?? existingInstall
    }
}

// MARK: - The welcome letter

/// The words of the greeting, kept beside the policy so the check can hold
/// them to the house rules: an exact sign-off and no em dashes.
enum WelcomeCopy {
    static let greeting = "Hello, welcome to Hotch."
    static let paragraphs = [
        "Hotch is a small companion for your Mac. It keeps your AI plan usage, your Claude Code and Codex sessions, and how your Mac is doing in one quiet place, ready for a glance.",
        "It stays out of the way until you need it, and lets you know when an agent finishes or needs you. Your settings and history stay on this Mac, and there’s no account to create.",
        "Setup takes about a minute. I hope Hotch makes your days a little calmer.",
    ]
    static let signOff = "Thanks, Hojae"
    static let contact = HotchAbout.email
    static let notInstalled = "Hotch is running from the disk image. Move it to Applications so it can open at login and keep working after a restart."

    static let setupTitle = "Make it yours"
    static let setupSubtitle = "Choose where Hotch lives. You can move it any time."

    static let spotlightTitle = "Hotch lives here"

    /// How to reach the companion from where it now sits.
    static func whereItLives(_ anchor: HotchPrefs.Anchor, side: HotchPrefs.EdgeSide,
                             realNotch: Bool, iconVisible: Bool = true) -> String {
        switch anchor {
        case .edge:
            switch side {
            case .right: return "On the right edge of your screen. Hover the tab to peek, or click to keep it open."
            case .left: return "On the left edge of your screen. Hover the tab to peek, or click to keep it open."
            case .bottom: return "Beside the Dock. Hover to peek, or click to keep it open."
            }
        case .notch:
            return realNotch
                ? "Around the notch. Hover there to peek, or click to keep it open."
                : "At the top of your screen. Hover there to peek, or click to keep it open."
        case .pill, .orb:
            return "Floating on your desktop. Hover to peek, click to keep it open, or drag it anywhere."
        case .menuBar:
            return iconVisible
                ? "In your menu bar. Click the icon to open it."
                : "In your menu bar. If you can’t see the icon, the menu bar may be full, so try closing another menu bar app."
        }
    }

    static let shortcutHint = "⌥⌘H opens it from anywhere."

    /// Every sentence a new user reads in the welcome, for the copy checks.
    static var all: [String] {
        var lines = [greeting, signOff, contact, notInstalled, setupTitle, setupSubtitle, spotlightTitle, shortcutHint]
        lines += paragraphs
        for anchor in HotchPrefs.Anchor.allCases {
            for side in HotchPrefs.EdgeSide.allCases {
                for notch in [false, true] {
                    lines.append(whereItLives(anchor, side: side, realNotch: notch, iconVisible: notch))
                }
            }
        }
        return lines
    }
}

// MARK: - The greeting's choreography

/// The greeting as a pure function of elapsed time, so the live window and the
/// rendered frames in the docs draw exactly the same thing. Each value runs
/// 0 to 1; with motion reduced the window starts at `settled`.
struct WelcomeTimeline: Equatable {
    static let duration: TimeInterval = 2.9
    static let settled = WelcomeTimeline(time: duration)
    /// The heading, three paragraphs, then the signature.
    static let lineCount = 2 + WelcomeCopy.paragraphs.count

    var time: TimeInterval

    private func progress(_ start: TimeInterval, _ length: TimeInterval) -> Double {
        min(max((time - start) / length, 0), 1)
    }

    private static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    /// A small overshoot, so the warm signal lands rather than appears.
    private static func backOut(_ x: Double) -> Double {
        let c1 = 1.4, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// The companion curve drawing itself.
    var curve: Double { Self.easeInOut(progress(0.15, 0.9)) }
    /// The warm signal arriving inside the curve.
    var signal: Double { Self.backOut(progress(0.9, 0.45)) }
    /// One soft ring leaving the signal, then gone.
    var ripple: Double { progress(1.05, 1.1) }
    /// Warm light spreading behind the mark.
    var glow: Double { Self.easeOut(progress(0.95, 1.3)) }
    /// Heading, paragraphs and signature, each easing up after the last.
    func line(_ index: Int) -> Double { Self.easeOut(progress(1.3 + 0.17 * Double(index), 0.6)) }
    var footer: Double { Self.easeOut(progress(2.25, 0.55)) }
}

// MARK: - Pointing at the companion

/// Where the "Hotch lives here" note sits relative to what it points at.
enum SpotlightSide: Equatable {
    case left, right, above, below
}

enum SpotlightPlacement {
    static let gap: CGFloat = 12
    static let margin: CGFloat = 10
    /// The arrow's base is kept this far from the bubble's corners.
    static let arrowInset: CGFloat = 18

    /// Faces the open screen: away from an edge tab, up from the Dock, down
    /// from the menu bar, and below a floating companion unless there is no
    /// room. The note never covers the target and stays on the visible screen.
    static func note(size: CGSize, target: CGRect, screen: CGRect, visible: CGRect)
        -> (frame: CGRect, side: SpotlightSide, arrow: CGFloat) {
        let side: SpotlightSide
        let tall = target.height > target.width
        if tall && target.maxX >= screen.maxX - 4 {
            side = .left
        } else if tall && target.minX <= screen.minX + 4 {
            side = .right
        } else if target.maxY >= visible.maxY - 2 {
            side = .below
        } else if target.minY <= visible.minY + 2 {
            side = .above
        } else {
            side = target.minY - gap - size.height >= visible.minY + margin ? .below : .above
        }

        var origin: CGPoint
        switch side {
        case .left: origin = CGPoint(x: target.minX - gap - size.width, y: target.midY - size.height / 2)
        case .right: origin = CGPoint(x: target.maxX + gap, y: target.midY - size.height / 2)
        case .below: origin = CGPoint(x: target.midX - size.width / 2, y: min(target.minY, visible.maxY) - gap - size.height)
        case .above: origin = CGPoint(x: target.midX - size.width / 2, y: max(target.maxY, visible.minY) + gap)
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        let frame = CGRect(origin: origin, size: size)

        // Measured from the bubble's top or leading edge, in view coordinates.
        let arrow: CGFloat
        switch side {
        case .left, .right:
            arrow = min(max(frame.maxY - target.midY, arrowInset), size.height - arrowInset)
        case .above, .below:
            arrow = min(max(target.midX - frame.minX, arrowInset), size.width - arrowInset)
        }
        return (frame, side, arrow)
    }

    /// A ring a little larger than the target, round for the orb.
    static func ring(around target: CGRect, padding: CGFloat = 6) -> (frame: CGRect, radius: CGFloat) {
        let frame = target.insetBy(dx: -padding, dy: -padding)
        let half = min(frame.width, frame.height) / 2
        return (frame, abs(frame.width - frame.height) < 4 ? half : min(half, 22))
    }
}
