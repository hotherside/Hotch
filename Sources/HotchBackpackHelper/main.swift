import Foundation
import os
#if canImport(BackpackShared)
import BackpackShared
#endif

// HotchBackpackHelper: the root LaunchDaemon behind Backpack mode.
//
//   (no arguments)        daemon mode, launched by launchd via SMAppService
//   --dry-run             same state machine, pmset writes printed not run,
//                         marker in a temp folder, anonymous XPC listener plus a
//                         scripted client. Options: --marker PATH,
//                         --idle-exit SECONDS, --crash-after-begin
//   --self-test           scripted scenarios with assertions; exit 1 on failure
//   --version

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("\(BackpackXPC.helperBuild) (protocol \(BackpackXPC.protocolVersion))")
    exit(0)
}
if arguments.contains("--self-test") {
    exit(SelfTest.run() ? 0 : 1)
}
if arguments.contains("--dry-run") {
    DryRun.run(arguments)
}
Daemon.run()

enum Daemon {
    static func run() -> Never {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data(
                "HotchBackpackHelper runs as root under launchd. Use --dry-run or --self-test to exercise it.\n".utf8))
            exit(EX_CONFIG)
        }

        let logger = Logger(subsystem: BackpackXPC.machServiceName, category: "helper")
        let log: (String) -> Void = { message in logger.notice("\(message, privacy: .public)") }
        let core = BackpackHelperCore(
            power: SystemPower(log: log),
            markers: MarkerStore(path: BackpackXPC.markerPath),
            now: Date.init,
            log: log)
        core.requestExit = { exit(0) }

        // Before accepting any connection: a marker here is a session that never
        // got restored (reboot, power loss, helper killed).
        core.queue.sync { core.recoverAtLaunch() }

        let delegate = HelperListenerDelegate(core: core, requirement: BackpackXPC.appRequirement)
        let listener = NSXPCListener(machServiceName: BackpackXPC.machServiceName)
        listener.delegate = delegate
        listener.resume()

        let timer = Runtime.startTicking(core, every: 5)
        let signals = Runtime.handleSignals(core)
        withExtendedLifetime((listener, delegate, timer, signals)) {
            dispatchMain()
        }
    }
}

enum DryRun {
    static func run(_ args: [String]) -> Never {
        let out: (String) -> Void = { line in
            print(line)
            fflush(stdout)
        }
        let markerPath = value(after: "--marker", in: args)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("hotch-backpack-dry-run/backpack-active.json").path
        let idleExit = value(after: "--idle-exit", in: args).flatMap(Double.init) ?? BackpackXPC.idleExitDelay
        let crashAfterBegin = args.contains("--crash-after-begin")

        // Real reads only. Nothing below writes to the power system.
        let real = SystemPower(log: out)
        let sleepDisabled = real.readSleepDisabled()
        let modes = real.readPowerModes()
        let lid = real.readLidClosed()

        out("HotchBackpackHelper --dry-run")
        out("  nothing on this Mac is changed: pmset writes are printed, not run")
        out("  marker: \(markerPath)")
        out("  read from this Mac: SleepDisabled=\(describe(sleepDisabled)), "
            + "\(modes.map { "\($0.key) " + $0.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") } ?? "no power mode setting"), "
            + "lid \(lid.map { $0 ? "closed" : "open" } ?? "unknown")")
        out("  listener: anonymous NSXPCListener (the mach service needs launchd, which a dry run leaves alone)")
        out("  client requirement, enforced in daemon mode only: \(BackpackXPC.appRequirement)")

        let power = SimulatedPower(sleepDisabled: sleepDisabled ?? false, modes: modes, lidClosed: lid)
        power.echo = { out("  [dry-run] would run: /usr/bin/\($0)") }
        let core = BackpackHelperCore(
            power: power,
            markers: MarkerStore(path: markerPath),
            now: Date.init,
            log: { out("  [helper] \($0)") })
        core.idleExitDelay = idleExit
        core.requestExit = {
            out("\ndry-run finished: the daemon would exit here")
            exit(0)
        }

        out("\n0. launch recovery")
        core.queue.sync { core.recoverAtLaunch() }

        let delegate = HelperListenerDelegate(core: core, requirement: nil)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()

        let timer = Runtime.startTicking(core, every: 1)
        let signals = Runtime.handleSignals(core)
        let endpoint = listener.endpoint
        DispatchQueue.global().async {
            DemoClient.run(endpoint: endpoint, core: core, markerPath: markerPath,
                           crashAfterBegin: crashAfterBegin, out: out)
        }
        withExtendedLifetime((listener, delegate, timer, signals)) {
            dispatchMain()
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func describe(_ value: Bool?) -> String {
        value.map { $0 ? "1" : "0" } ?? "unknown"
    }
}

/// Plays Hotch's side over a real XPC connection, using the same interface the
/// app uses.
enum DemoClient {
    static func run(endpoint: NSXPCListenerEndpoint, core: BackpackHelperCore, markerPath: String,
                    crashAfterBegin: Bool, out: @escaping (String) -> Void) {
        func connect() -> (NSXPCConnection, BackpackHelperProtocol) {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = BackpackXPC.makeInterface()
            connection.resume()
            let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
                out("  [client] XPC error: \(error.localizedDescription)")
            } as! BackpackHelperProtocol
            return (connection, proxy)
        }
        func reply(_ text: String) { out("  [client] \(text)") }

        let (first, helper) = connect()

        out("\n1. helperVersion")
        helper.helperVersion { version, build in reply("protocol \(version), build \(build)") }

        out("\n2. status")
        helper.status { sleep, active, note in reply("sleepDisabled \(sleep), active \(active), \(note ?? "")") }

        out("\n3. begin(lowPower: true)")
        helper.begin(lowPower: true) { ok, note in reply("ok \(ok)\(note.map { ", \($0)" } ?? "")") }
        if let marker = try? String(contentsOfFile: markerPath, encoding: .utf8) {
            out("  marker now on disk:")
            marker.split(separator: "\n").forEach { out("    \($0)") }
        }

        if crashAfterBegin {
            out("\nsimulating a crash: exiting with the session on and the marker left behind.")
            out("Run --dry-run again with the same --marker to see launch recovery.")
            _exit(3)
        }

        out("\n4. heartbeat")
        helper.heartbeat { active, note in reply("active \(active)\(note.map { ", \($0)" } ?? "")") }

        out("\n5. status")
        helper.status { sleep, active, note in reply("sleepDisabled \(sleep), active \(active), \(note ?? "")") }

        out("\n6. end")
        helper.end { ok, note in reply("ok \(ok)\(note.map { ", \($0)" } ?? "")") }

        out("\n7. begin(lowPower: false), then drop the connection as if Hotch crashed")
        helper.begin(lowPower: false) { ok, note in reply("ok \(ok)\(note.map { ", \($0)" } ?? "")") }
        first.invalidate()
        for _ in 0..<30 where core.queue.sync(execute: { core.session != nil }) {
            usleep(100_000)
        }

        out("\n8. a new connection asks for status")
        let (second, again) = connect()
        again.status { sleep, active, note in reply("sleepDisabled \(sleep), active \(active), \(note ?? "")") }
        second.invalidate()

        out("\nwaiting for idle exit (\(Int(core.idleExitDelay)) s with no session and no connections)")
    }
}
