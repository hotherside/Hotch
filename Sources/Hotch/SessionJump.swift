import AppKit
import Darwin

/// Opens the host application. Selecting the session's exact tab or window
/// would require an integration the host apps do not currently expose here.
@MainActor
enum SessionJump {
    /// Completion runs on the main actor after macOS confirms an app opened.
    /// Failures keep the card available and explain how to reach the session.
    static func go(to session: AgentSession, completion: @escaping @MainActor (Bool) -> Void) {
        let runningApps = NSWorkspace.shared.runningApplications
        let hosts = runningApps.compactMap(host)
        let ancestors = session.pid.map { ancestry(of: pid_t($0)) } ?? []
        switch SessionHandoffPolicy.resolve(surface: session.surface, ancestry: ancestors, running: hosts) {
        case .failure(let failure):
            completion(false)
            showFailure(failure)
        case .success(let target):
            guard let app = runningApps.first(where: { $0.processIdentifier == target.processID }),
                  !app.isTerminated, let url = app.bundleURL else {
                completion(false)
                showFailure(.hostNotRunning(target.name))
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { opened, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let accepted = SessionHandoffPolicy.launchWasAccepted(
                            hasApplication: opened != nil,
                            hasError: error != nil,
                            isTerminated: opened?.isTerminated ?? true)
                        completion(accepted)
                        if !accepted { showFailure(.launchRejected(target.name)) }
                    }
                }
            }
        }
    }

    private static func host(_ app: NSRunningApplication) -> SessionHost? {
        guard app.activationPolicy == .regular, !app.isTerminated,
              let bundleID = app.bundleIdentifier else { return nil }
        return SessionHost(processID: app.processIdentifier, bundleID: bundleID,
                           name: app.localizedName ?? bundleID)
    }

    /// tmux may have no app ancestor because its server belongs to launchd.
    /// That is an unknown host, rather than evidence for any open terminal.
    private static func ancestry(of pid: pid_t) -> [SessionHost] {
        var result: [SessionHost] = []
        var current = pid
        for _ in 0..<32 {
            if let app = NSRunningApplication(processIdentifier: current), let item = host(app) {
                result.append(item)
            }
            let parent = parentPID(of: current)
            guard parent > 1, parent != current else { break }
            current = parent
        }
        return result
    }

    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    private static func showFailure(_ failure: SessionHandoffFailure) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Couldn’t open this session’s app"
        alert.informativeText = failure.recoveryMessage
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
