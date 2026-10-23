import Foundation

/// A read-only snapshot: resolution can be checked without opening an app.
struct SessionHost: Equatable {
    let processID: Int32
    let bundleID: String
    let name: String
}

enum SessionHandoffFailure: Error, Equatable {
    case hostUnidentified(String?)
    case hostNotRunning(String)
    case ambiguousHost(String)
    case launchRejected(String)

    var recoveryMessage: String {
        switch self {
        case .hostUnidentified(let surface):
            if surface == "Terminal" {
                return "Hotch couldn’t identify the terminal that owns this session. Open its terminal or tmux session manually, then select the session’s tab or window."
            }
            return "Hotch couldn’t identify the app that owns this session. Open \(surface ?? "the session’s app") manually, then select the session’s tab or window."
        case .hostNotRunning(let name):
            return "\(name) is no longer available. Open it manually, then select the session’s tab or window."
        case .ambiguousHost(let name):
            return "More than one \(name) app is running, and Hotch couldn’t identify which one owns this session. Open the correct app manually, then select the session’s tab or window."
        case .launchRejected(let name):
            return "macOS couldn’t open \(name). Try opening it from the Dock or Finder, then select the session’s tab or window."
        }
    }
}

enum SessionHandoffPolicy {
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
        "org.wezfurlong.wezterm",
    ]
    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "dev.zed.Zed-Preview",
    ]
    private static let desktopApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.codex",
    ]

    static func resolve(surface: String?, ancestry: [SessionHost], running: [SessionHost])
        -> Result<SessionHost, SessionHandoffFailure> {
        // Only known session hosts qualify. An unrelated regular application
        // in the process tree must not become a successful destination.
        if let host = ancestry.first(where: { isKnownHost($0.bundleID) }) { return .success(host) }

        let bundleIDs: Set<String>
        switch surface {
        case "Claude desktop", "Cowork": bundleIDs = ["com.anthropic.claudefordesktop"]
        case "Codex app": bundleIDs = ["com.openai.codex"]
        case "VS Code": bundleIDs = editors.filter { $0 != "dev.zed.Zed" && $0 != "dev.zed.Zed-Preview" }
        // "Terminal" describes a category, not an identity. Even one running
        // terminal may be unrelated to a detached or ended session.
        default: return .failure(.hostUnidentified(surface))
        }
        let matches = running.filter { bundleIDs.contains($0.bundleID) }
        guard !matches.isEmpty else { return .failure(.hostNotRunning(surface ?? "The session’s app")) }
        guard matches.count == 1 else { return .failure(.ambiguousHost(surface ?? "session host")) }
        return .success(matches[0])
    }

    static func launchWasAccepted(hasApplication: Bool, hasError: Bool, isTerminated: Bool) -> Bool {
        hasApplication && !hasError && !isTerminated
    }

    private static func isKnownHost(_ id: String) -> Bool {
        terminals.contains(id) || editors.contains(id) || desktopApps.contains(id)
            || id.hasPrefix("com.jetbrains.")
    }
}
