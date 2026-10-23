import Foundation

/// Which direction the meters report.
///
/// Both settings describe the same fact and are exact complements, so there is no
/// correct answer — only a preference about which number a person wants to read
/// at a glance. "Used" matches every vendor's own dashboard and fills like any
/// other meter; "Remaining" answers "how much have I got left" without
/// subtracting. Rather than pick for everyone, it is a switch.
///
/// Whatever is chosen, one thing does not change: the arc and the number always
/// describe the same quantity, and the warning colour always keys off actual
/// consumption. A window at 8% remaining and one at 92% used are the same window
/// in trouble, and it must look that way in both modes.
enum UsageDisplayMode: String, CaseIterable, Sendable {
    case used
    case remaining

    /// Title in the settings picker.
    var label: String {
        switch self {
        case .used: return "Used"
        case .remaining: return "Remaining"
        }
    }

    /// The word printed after the number in the panel and popover.
    var unit: String {
        switch self {
        case .used: return "used"
        case .remaining: return "left"
        }
    }
}

/// User configuration, persisted to UserDefaults. Injected into the store and
/// the settings window; @Published so both react live to changes.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let enabledProviders = "enabledProviderIDs"
        static let legacyDisabledProviders = "disabledProviderIDs"
        static let refreshInterval = "refreshInterval"
        /// Renamed from `migratedFromNotchPeekBundleID`, which stopped being
        /// accurate once there were two old bundle ids to come from. The prefix is
        /// load-bearing: see the skip in `migrateLegacyDefaults`.
        static let migratedFromLegacy = "migratedFromLegacyBundleIDs"
        static let hasLaunchedBefore = "hasLaunchedBefore"
        static let displayMode = "usageDisplayMode"
        static let prunedInheritedDefaults = "prunedInheritedDefaultProviders"
        static let clipboardHistory = "clipboardHistoryEnabled"

        /// Keys that record what this app has already done, as opposed to anything
        /// the user chose. Never carried across from an old bundle identifier: a
        /// stale copy would claim a migration this domain never performed.
        static let bookkeeping: Set<String> = [
            migratedFromLegacy, hasLaunchedBefore, prunedInheritedDefaults,
            // The name this key had before there were two old domains to come from.
            "migratedFromNotchPeekBundleID",
        ]
    }

    /// False exactly once, on the very first launch of a fresh install.
    ///
    /// An accessory app has no window and no Dock icon, so there is nothing on
    /// screen to tell a new user that Settings exists, let alone that a provider
    /// has to be connected before any number can appear. It is claimed rather
    /// than merely read: the flag flips the first time it is asked, so this can
    /// only ever be true once no matter who calls it.
    func claimFirstLaunch() -> Bool {
        guard !defaults.bool(forKey: Key.hasLaunchedBefore) else { return false }
        defaults.set(true, forKey: Key.hasLaunchedBefore)
        return true
    }

    /// The set that was on by default back when preferences stored a *disabled*
    /// list. Kept only to interpret that format — subtracting from the wrong
    /// universe would switch a provider back on that the user had turned off.
    ///
    /// It is no longer what a fresh install starts with. The justification was
    /// that both worked with no setup: Claude read the Claude Code CLI's own
    /// credential, and Codex read the CLI's session logs. Neither is true any
    /// more — that Claude path was deleted because it raised a Keychain prompt
    /// nobody could satisfy, and the Codex log fallback is age-gated — so the
    /// list outlived its own reason, and all it did was put two rows on a fresh
    /// install that could not produce a number and that nobody had asked for.
    static let legacyDefaultEnabled: Set<String> = ["claude", "codex"]

    /// Providers that have been removed from the app. Gemini went on 20 Oct
    /// 2026: Google ended Google sign-in for individual Gemini CLI users on
    /// 18 Jun 2026, which was the only thing the provider could read.
    static let retiredProviderIDs: Set<String> = ["gemini"]

    /// Providers shown in the panel. Stored as the enabled set so a provider
    /// that needs setup does not appear as an empty row on first launch.
    @Published var enabledProviderIDs: Set<String> {
        didSet {
            defaults.set(Array(enabledProviderIDs).sorted(), forKey: Key.enabledProviders)
        }
    }

    /// Background refresh cadence in seconds. The panel additionally forces a
    /// refresh every time it expands, regardless of this value.
    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    /// Whether the meters report consumption or what is left.
    ///
    /// Defaults to `.used`, because a meter that fills as you spend needs no
    /// caption to be read correctly — but it is a preference, not a verdict.
    @Published var displayMode: UsageDisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: Key.displayMode) }
    }

    /// A snapshot-time override, so a render can be produced in either mode
    /// without touching the user's stored preference. Nil in normal operation.
    nonisolated(unsafe) static var displayModeOverride: UsageDisplayMode?

    /// Whether the clipboard page records anything at all. The store keeps its
    /// short history in memory only and honours the concealed-type marks, but
    /// a clipboard watcher is still the most privacy-shaped thing in the app,
    /// so it gets a real off switch that stops the polling entirely.
    @Published var clipboardHistoryEnabled: Bool {
        didSet { defaults.set(clipboardHistoryEnabled, forKey: Key.clipboardHistory) }
    }

    /// xAI team ID for the Grok management API. Not a secret, unlike the
    /// management key itself which lives in the Keychain.
    @Published var grokTeamID: String {
        didSet {
            defaults.set(grokTeamID.trimmingCharacters(in: .whitespacesAndNewlines),
                         forKey: GrokProvider.teamIDDefaultsKey)
        }
    }

    /// No sub-30s option any more. The vendor usage endpoints answer 429 when
    /// polled that hard — which is what made the Claude row keep falling back to
    /// a different data source — and each provider now enforces its own floor
    /// regardless, so a faster setting here would only have been a lie.
    static let refreshChoices: [(label: String, seconds: TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
    ]

    static let defaultRefreshInterval: TimeInterval = 60

    private let defaults: UserDefaults

    /// Bundle identifiers this app wrote preferences under before, **newest
    /// first**. UserDefaults is keyed by bundle identifier, and both renames
    /// changed it, so preferences would silently reset to defaults without this.
    static let legacyDefaultsDomains = [
        "com.hojaejung.hojnotch",     // HojNotch
        "com.unleashlive.notchpeek",  // NotchPeek
    ]

    /// Copies preferences over from the old bundle identifiers, once.
    ///
    /// Walks newest-first and only fills in keys the new domain does not already
    /// have, which does two jobs with one rule: a value the user has since changed
    /// is never overwritten by a stale one, and where both old domains hold the
    /// same key the newer one wins.
    static func migrateLegacyDefaults(into defaults: UserDefaults) {
        guard defaults.object(forKey: Key.migratedFromLegacy) == nil else { return }
        // Set before copying, deliberately. The loop below skips keys the new
        // domain already has, so writing the guard first is also what stops a
        // *stale copy of the guard itself* being carried across from the old
        // domain — which for the HojNotch domain is already `true`, and would have
        // marked this migration done before it had run.
        defaults.set(true, forKey: Key.migratedFromLegacy)

        for domain in legacyDefaultsDomains {
            guard let legacy = UserDefaults(suiteName: domain),
                  let old = legacy.persistentDomain(forName: domain),
                  !old.isEmpty else { continue }

            var carried: [String] = []
            for (key, value) in old where defaults.object(forKey: key) == nil {
                if Key.bookkeeping.contains(key) { continue }
                defaults.set(value, forKey: key)
                carried.append(key)
            }
            if !carried.isEmpty {
                hotchLog.log("carried \(carried.count) preference(s) over from \(domain)")
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        AppSettings.migrateLegacyDefaults(into: defaults)
        self.defaults = defaults

        if let stored = defaults.stringArray(forKey: Key.enabledProviders) {
            // Providers that no longer exist are dropped from the stored set,
            // and the cleaned set written back so this happens once.
            let kept = Set(stored).subtracting(AppSettings.retiredProviderIDs)
            self.enabledProviderIDs = kept
            if kept.count != Set(stored).count {
                defaults.set(Array(kept).sorted(), forKey: Key.enabledProviders)
                hotchLog.log("removed retired provider(s) from the enabled set")
            }
        } else if let legacyDisabled = defaults.stringArray(forKey: Key.legacyDisabledProviders) {
            // Migrate the short-lived disabled-set format, which only ever
            // covered the two original providers. An empty result would leave
            // the app with nothing to show at all, so that falls back to the
            // defaults rather than starting up blank.
            let migrated = AppSettings.legacyDefaultEnabled.subtracting(legacyDisabled)
            let resolved = migrated.isEmpty ? AppSettings.legacyDefaultEnabled : migrated
            self.enabledProviderIDs = resolved
            defaults.removeObject(forKey: Key.legacyDisabledProviders)
            // didSet does not fire during init, so persist the migration here
            // or it would be recomputed on every launch.
            defaults.set(Array(resolved).sorted(), forKey: Key.enabledProviders)
        } else {
            // Nothing stored: a fresh install. It starts with no rows at all, and
            // `seedEnabled` fills them in from what this Mac can actually report.
            // Not persisted here — didSet does not fire during init, and the seed
            // is the write that should land.
            self.enabledProviderIDs = []
        }

        self.grokTeamID = defaults.string(forKey: GrokProvider.teamIDDefaultsKey) ?? ""

        // Defaults on; `bool(forKey:)` defaults to false, so absence has to be
        // told apart from a stored false.
        self.clipboardHistoryEnabled = defaults.object(forKey: Key.clipboardHistory) as? Bool ?? true

        self.displayMode = AppSettings.displayModeOverride
            ?? defaults.string(forKey: Key.displayMode).flatMap(UsageDisplayMode.init(rawValue:))
            ?? .used

        // Snap to a known choice so the settings picker always has a selection.
        // Anything stored from the old sub-30s choices lands on the default,
        // which is also the migration off the cadence that got users throttled.
        let stored = defaults.double(forKey: Key.refreshInterval)
        let choices = AppSettings.refreshChoices.map(\.seconds)
        if choices.contains(stored) {
            self.refreshInterval = stored
        } else {
            self.refreshInterval = AppSettings.defaultRefreshInterval
            defaults.set(AppSettings.defaultRefreshInterval, forKey: Key.refreshInterval)
        }
    }

    /// Switches on exactly the providers that already have a working sign-in.
    ///
    /// Called once, on the first launch of a fresh install, before the store is
    /// built from the enabled set. Someone who already runs the Codex CLI gets a
    /// live Codex row on their first hover with nothing to configure; someone who
    /// does not gets no Codex row, rather than an empty one they never asked for
    /// and have to work out how to remove.
    func seedEnabled(_ ids: Set<String>) {
        enabledProviderIDs = ids
        let summary = ids.isEmpty ? "nothing — no provider is set up yet"
                                  : ids.sorted().joined(separator: ", ")
        hotchLog.log("first launch: switched on \(summary)")
    }

    /// One-time correction for installs that already inherited the old default of
    /// Claude and Codex switched on whether or not either could report anything.
    ///
    /// Without this the fix would miss the very people who hit the problem. Anyone
    /// who has launched Hotch once has that pair *stored*, so `claimFirstLaunch`
    /// is false for them and the new default never applies — the two dead rows
    /// would outlive the change that removed them.
    ///
    /// Deliberately narrow. It runs only when the stored set is *exactly* the old
    /// default, since anything else is a set the user has actually chosen, and even
    /// then it switches off only what is not set up on this Mac. So the worst it can
    /// do is remove a row that was showing an explanation instead of a number, and
    /// someone who really does have the Codex CLI signed in keeps their Codex row.
    func pruneInheritedDefaults(isConfigured: (String) -> Bool) {
        guard !defaults.bool(forKey: Key.prunedInheritedDefaults) else { return }
        defaults.set(true, forKey: Key.prunedInheritedDefaults)

        guard enabledProviderIDs == AppSettings.legacyDefaultEnabled else { return }
        let kept = enabledProviderIDs.filter(isConfigured)
        guard kept != enabledProviderIDs else { return }

        let dropped = enabledProviderIDs.subtracting(kept).sorted().joined(separator: ", ")
        enabledProviderIDs = kept
        hotchLog.log("switched off inherited default provider(s) with nothing to report: \(dropped)")
    }

    func isEnabled(_ providerID: String) -> Bool {
        enabledProviderIDs.contains(providerID)
    }

    func setEnabled(_ enabled: Bool, providerID: String) {
        if enabled {
            enabledProviderIDs.insert(providerID)
        } else {
            enabledProviderIDs.remove(providerID)
        }
    }
}
