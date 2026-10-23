import Foundation
#if canImport(BackpackShared)
import BackpackShared
#endif

/// Accepts connections, pins the code-signing requirement on each, and wires
/// invalidation and interruption to the state machine.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let core: BackpackHelperCore
    /// Nil only in `--dry-run` and the self-test's in-process round trip, where the
    /// client is this unsigned test binary.
    private let requirement: String?

    init(core: BackpackHelperCore, requirement: String?) {
        self.core = core
        self.requirement = requirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Checked by the system against the peer's audit token on every message;
        // a client that does not match gets its connection invalidated before any
        // method runs.
        if let requirement {
            connection.setCodeSigningRequirement(requirement)
        }
        let core = self.core
        let id = core.queue.sync { core.connectionOpened() }
        connection.exportedInterface = BackpackXPC.makeInterface()
        connection.exportedObject = HelperService(core: core, connectionID: id, clientPID: connection.processIdentifier)
        connection.invalidationHandler = {
            core.queue.async { core.connectionClosed(id, why: "invalidated") }
        }
        connection.interruptionHandler = {
            core.queue.async { core.connectionClosed(id, why: "interrupted") }
        }
        connection.resume()
        return true
    }
}

/// One per connection, so every request knows which connection sent it.
final class HelperService: NSObject, BackpackHelperProtocol {
    private let core: BackpackHelperCore
    private let connectionID: Int
    private let clientPID: Int32

    init(core: BackpackHelperCore, connectionID: Int, clientPID: Int32) {
        self.core = core
        self.connectionID = connectionID
        self.clientPID = clientPID
    }

    func begin(lowPower: Bool, reply: @escaping (Bool, String?) -> Void) {
        let core = self.core, id = connectionID, pid = clientPID
        core.queue.async {
            let result = core.begin(connectionID: id, clientPID: pid, lowPower: lowPower)
            reply(result.ok, result.note)
        }
    }

    func end(reply: @escaping (Bool, String?) -> Void) {
        let core = self.core, id = connectionID
        core.queue.async {
            let result = core.end(connectionID: id)
            reply(result.ok, result.note)
        }
    }

    func heartbeat(reply: @escaping (Bool, String?) -> Void) {
        let core = self.core, id = connectionID
        core.queue.async {
            let result = core.heartbeat(connectionID: id)
            reply(result.active, result.note)
        }
    }

    func status(reply: @escaping (Bool, Bool, String?) -> Void) {
        let core = self.core
        core.queue.async {
            let result = core.status()
            reply(result.sleepDisabled, result.active, result.note)
        }
    }

    func helperVersion(reply: @escaping (Int, String) -> Void) {
        reply(BackpackXPC.protocolVersion, BackpackXPC.helperBuild)
    }
}

enum Runtime {
    /// Drives heartbeat timeout, hard cap, the lid-closed sleep check and idle exit.
    static func startTicking(_ core: BackpackHelperCore, every seconds: Double) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: core.queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(250))
        timer.setEventHandler { core.tick() }
        timer.resume()
        return timer
    }

    /// launchd sends SIGTERM when the job is unloaded (unregistered, shutdown).
    /// Restore first, then exit.
    static func handleSignals(_ core: BackpackHelperCore) -> [DispatchSourceSignal] {
        [SIGTERM, SIGINT, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: core.queue)
            source.setEventHandler {
                core.log("signal \(number); restoring and exiting")
                core.terminate()
                exit(0)
            }
            source.resume()
            return source
        }
    }
}
