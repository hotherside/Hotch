import Foundation

/// Preference migration regression checks; no real defaults or windows touched.
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
        print("Welcome checks: \(failures == 0 ? "passed" : "failed")")
        exit(failures == 0 ? 0 : 1)
    }
}
