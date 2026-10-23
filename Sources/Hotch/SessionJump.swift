import AppKit
import Darwin

/// Brings forward the app a session runs in: the terminal, editor or
/// desktop app that started it.
///
/// Claude Code records each session's process, and walking up its parents
/// reaches the app (Terminal, VS Code, the Claude app). A Codex thread has
/// no process to follow, so its app is found by where it was started. This
/// is app level only: picking the exact window or tab would need the
/// Accessibility permission, which Hotch does not ask for.
@MainActor
enum SessionJump {
    @discardableResult
    static func go(to session: AgentSession) -> Bool {
        if let pid = session.pid, let app = owningApp(of: pid_t(pid)) {
            return bringForward(app)
        }
        for id in bundleIDs(for: session) {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return bringForward(app)
            }
        }
        return false
    }

    /// The nearest ancestor that is an ordinary app with a Dock icon. A
    /// session under tmux has none (tmux's server belongs to launchd).
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            let parent = parentPID(of: current)
            guard parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    private static func bundleIDs(for session: AgentSession) -> [String] {
        switch session.surface {
        case "Claude desktop", "Cowork": return ["com.anthropic.claudefordesktop"]
        case "Codex app": return ["com.openai.codex", "com.openai.chat"]
        case "VS Code": return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92"]
        case "Terminal": return ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]
        default: return []
        }
    }

    /// Through Launch Services, like a Dock click: a background app such as
    /// Hotch is not allowed to activate another app directly.
    private static func bringForward(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return app.activate() }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }
}
