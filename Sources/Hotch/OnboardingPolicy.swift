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
