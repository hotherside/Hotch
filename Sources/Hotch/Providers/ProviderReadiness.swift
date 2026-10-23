import Foundation

/// Whether a provider can produce a real number on this Mac right now.
///
/// One definition, because two places have to agree about it and used not to. The
/// "not set up" badge in Settings worked it out inside the view, while which rows
/// appeared in the panel came from a hardcoded list of providers assumed to work
/// with no setup. That is how a fresh install showed a Claude row and a Codex row
/// on a Mac where neither had ever been connected: the list was written when both
/// still had a zero-setup fallback, and by the time neither did, nothing tied it
/// to the truth.
///
/// Cheap enough to call on every settings redraw: file existence checks and reads
/// of Hotch's own key files. The one exception is Claude, whose sign-in lives in
/// Claude Code: that answer is cached and refreshed in the background with
/// `claude auth status` (about 0.1 s, at most once a minute), and is only waited
/// for when nothing is known yet, which is the first launch. No network, and
/// nothing that can raise a Keychain prompt.
enum ProviderReadiness {
    static func isConfigured(_ providerID: String) -> Bool {
        switch providerID {
        case "claude":
            // Installed and signed in to a Claude plan. An API-key Claude Code
            // has no plan windows to show, so it does not count.
            guard ClaudeCodeBridge.isInstalled else { return false }
            if case .signedIn = ClaudeCodeBridge.signIn(blockingIfUnknown: true) { return true }
            return false
        case "codex":
            return CodexProvider.readiness() == .ready
        case "grok":
            // A key with no team id cannot address the billing API, so it is not
            // yet a working setup.
            return ProviderKeyStore.hasKey(for: providerID) && GrokProvider.teamID != nil
        case "kimi":
            // Kimi has a second, keyless route: its own CLI's sign-in.
            return ProviderKeyStore.hasKey(for: providerID)
                || KimiProvider.hasCLISignIn
        default:
            return ProviderKeyStore.hasKey(for: providerID)
        }
    }

    /// Everything already set up, out of the ids offered.
    static func configuredIDs(among ids: [String]) -> Set<String> {
        Set(ids.filter(isConfigured))
    }
}
