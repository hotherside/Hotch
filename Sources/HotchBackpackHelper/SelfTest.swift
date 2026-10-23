import Foundation
import Security
#if canImport(BackpackShared)
import BackpackShared
#endif

/// `--self-test`: drives the state machine with a fake clock and simulated power
/// state, asserts the exact pmset writes for every restore path, then repeats the
/// key paths over a real (anonymous, in-process) XPC connection. Never runs pmset
/// with a write and never touches launchd.
enum SelfTest {
    static func run() -> Bool {
        let t = TestRun()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotch-backpack-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        print("HotchBackpackHelper --self-test (no pmset writes run, no launchd jobs touched)")

        // MARK: Parsing

        t.section("pmset -g custom parsing")
        let appleSilicon = """
        Battery Power:
         Sleep On Power Button 1
         powermode            0
         standby              1
         sleep                1
        AC Power:
         Sleep On Power Button 1
         powermode            2
         sleep                0
        """
        t.expect(PMSetParser.powerModes(fromCustom: appleSilicon),
                 PowerModes(key: "powermode", values: ["b": 0, "c": 2]), "powermode per source")
        let older = "Battery Power:\n lowpowermode         1\n sleep 1\nAC Power:\n lowpowermode         0\n"
        t.expect(PMSetParser.powerModes(fromCustom: older),
                 PowerModes(key: "lowpowermode", values: ["b": 1, "c": 0]), "lowpowermode per source")
        t.expect(PMSetParser.powerModes(fromCustom: "AC Power:\n sleep 0\n displaysleep 10\n"), nil,
                 "no power mode setting gives nil")
        if let live = SystemPower.run(["-g", "custom"]), live.status == 0 {
            let parsed = PMSetParser.powerModes(fromCustom: live.output)
            let shown = parsed.map { modes in
                modes.key + " " + modes.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            }
            print("  info  this Mac (read-only pmset -g custom): \(shown ?? "no power mode setting")")
        }

        // MARK: Scenarios

        t.section("begin, then end from Hotch")
        do {
            let f = Fixture(root, "s1")
            let c = f.core.connectionOpened()
            let r = f.core.begin(connectionID: c, clientPID: 4242, lowPower: true)
            t.check(r.ok && r.note == nil, "begin succeeds")
            t.expect(f.power.take(), ["pmset -a disablesleep 1", "pmset -a powermode 1"], "begin writes")
            if case .marker(let m) = f.markers.read() {
                t.check(m.sleepDisabledByHotch && m.priorPowerModes == PowerModes(key: "powermode", values: ["b": 0, "c": 0]),
                        "marker records prior values")
            } else {
                t.check(false, "marker written before the writes")
            }
            f.advance(600)
            t.check(f.core.end(connectionID: c).ok, "end succeeds")
            t.expect(f.power.take(), ["pmset -a disablesleep 0", "pmset -a powermode 0"], "end restores")
            t.check(f.markers.read() == .none, "marker deleted")
            t.check(f.core.lastEnd?.reason == .clientRequest, "reason: ended by Hotch")
        }

        t.section("heartbeat timeout (3 min)")
        do {
            let f = Fixture(root, "s2")
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            _ = f.power.take()
            f.advance(30); _ = f.core.heartbeat(connectionID: c)
            f.advance(30); _ = f.core.heartbeat(connectionID: c)
            f.advance(179); f.core.tick()
            t.check(f.core.session != nil && f.power.take().isEmpty, "still on at 2 min 59 s of silence")
            f.advance(1); f.core.tick()
            t.expect(f.power.take(), ["pmset -a disablesleep 0", "pmset -a powermode 0"], "restored at 3 min")
            t.check(f.core.lastEnd?.reason == .heartbeatTimeout, "reason: heartbeat timeout")
            t.check(f.markers.read() == .none, "marker deleted")
            let hb = f.core.heartbeat(connectionID: c)
            t.check(!hb.active && hb.note == HelperEndReason.heartbeatTimeout.rawValue, "next heartbeat learns why")
            f.advance(10); f.core.tick()
            t.expect(f.power.take(), [], "lid open: no sleepnow")
        }

        t.section("connection lost (Hotch quit or crashed)")
        do {
            let f = Fixture(root, "s3")
            let owner = f.core.connectionOpened()
            let other = f.core.connectionOpened()
            _ = f.core.begin(connectionID: owner, clientPID: 1, lowPower: true)
            _ = f.power.take()
            f.core.connectionClosed(other, why: "invalidated")
            t.check(f.core.session != nil && f.power.take().isEmpty, "another connection closing changes nothing")
            f.core.connectionClosed(owner, why: "interrupted")
            t.expect(f.power.take(), ["pmset -a disablesleep 0", "pmset -a powermode 0"], "owner lost: restored")
            t.check(f.core.lastEnd?.reason == .clientDisconnected, "reason: Hotch quit or crashed")
        }

        t.section("marker recovery at launch (helper killed, reboot, power loss)")
        do {
            let crashed = Fixture(root, "s4")
            let c = crashed.core.connectionOpened()
            _ = crashed.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            _ = crashed.power.take()
            crashed.power.lidClosed = true
            // The helper dies here without restoring. A new process starts with the
            // same power state and the same marker path.
            let relaunched = Fixture(root, "s4", power: crashed.power)
            relaunched.core.recoverAtLaunch()
            t.expect(relaunched.power.take(), ["pmset -a disablesleep 0", "pmset -a powermode 0"], "restored from marker")
            t.check(relaunched.markers.read() == .none, "marker deleted")
            t.check(relaunched.core.lastEnd?.reason == .recoveredAtLaunch, "reason: recovered at launch")
            relaunched.advance(10); relaunched.core.tick()
            t.expect(relaunched.power.take(), [], "no sleepnow at launch even with the lid closed")
        }

        t.section("hard cap (4 h 15 min) despite steady heartbeats")
        do {
            let f = Fixture(root, "s5")
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: false)
            _ = f.power.take()
            for _ in 0..<509 {
                f.advance(30); _ = f.core.heartbeat(connectionID: c); f.core.tick()
            }
            t.check(f.core.session != nil && f.power.take().isEmpty, "still on at 4 h 14 min 30 s")
            f.advance(30); _ = f.core.heartbeat(connectionID: c); f.core.tick()
            t.expect(f.power.take(), ["pmset -a disablesleep 0"], "restored at 4 h 15 min")
            t.check(f.core.lastEnd?.reason == .hardCap, "reason: hard cap")
        }

        t.section("disablesleep set by hand is never touched")
        do {
            let f = Fixture(root, "s6", sleepDisabled: true)
            let c = f.core.connectionOpened()
            let r = f.core.begin(connectionID: c, clientPID: 1, lowPower: false)
            t.check(r.ok && (r.note ?? "").contains("already disabled"), "begin notes it")
            t.expect(f.power.take(), [], "begin writes nothing")
            _ = f.core.end(connectionID: c)
            t.expect(f.power.take(), [], "end writes nothing")
            t.check(f.power.sleepDisabled, "SleepDisabled still 1")
            let idle = Fixture(root, "s6b", sleepDisabled: true)
            idle.core.recoverAtLaunch()
            t.expect(idle.power.take(), [], "launch without a marker writes nothing")
        }

        t.section("power mode restored per source")
        do {
            let f = Fixture(root, "s7", modes: PowerModes(key: "powermode", values: ["b": 0, "c": 2]))
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            t.expect(f.power.take(), ["pmset -a disablesleep 1", "pmset -a powermode 1"], "begin writes")
            _ = f.core.end(connectionID: c)
            t.expect(f.power.take(), ["pmset -a disablesleep 0", "pmset -b powermode 0", "pmset -c powermode 2"],
                     "battery back to 0, charger back to 2")
        }

        t.section("power mode the user changed mid-session is kept")
        do {
            let f = Fixture(root, "s8")
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            _ = f.power.take()
            f.power.modes?.values["b"] = 2
            _ = f.core.end(connectionID: c)
            t.expect(f.power.take(), ["pmset -a disablesleep 0", "pmset -c powermode 0"], "only the untouched source")
        }

        t.section("lid still closed after restore: sleepnow")
        do {
            let f = Fixture(root, "s9")
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: false)
            _ = f.power.take()
            f.power.lidClosed = true
            f.advance(180); f.core.tick()
            t.expect(f.power.take(), ["pmset -a disablesleep 0"], "heartbeat timeout restores")
            f.advance(4); f.core.tick()
            t.expect(f.power.take(), [], "waits 5 s for macOS to sleep by itself")
            f.advance(1); f.core.tick()
            t.expect(f.power.take(), ["pmset sleepnow"], "then asks for sleep")

            let g = Fixture(root, "s9b")
            let d = g.core.connectionOpened()
            _ = g.core.begin(connectionID: d, clientPID: 1, lowPower: false)
            g.power.lidClosed = true
            _ = g.core.end(connectionID: d)
            _ = g.power.take()
            g.power.lidClosed = false
            g.advance(6); g.core.tick()
            t.expect(g.power.take(), [], "lid opened in the meantime: no sleepnow")
        }

        t.section("begin rolls back when macOS refuses")
        do {
            let f = Fixture(root, "s10")
            f.power.failing = ["pmset -a disablesleep 1"]
            let c = f.core.connectionOpened()
            let r = f.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            t.check(!r.ok, "begin reports failure")
            t.expect(f.power.take(), ["pmset -a disablesleep 1", "pmset -a disablesleep 0"], "rolled back")
            t.check(f.core.session == nil && f.markers.read() == .none, "no session, no marker")
        }

        t.section("failed restore keeps the marker and is retried")
        do {
            let f = Fixture(root, "s11")
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            _ = f.power.take()
            f.power.failing = ["pmset -a disablesleep 0"]
            let r = f.core.end(connectionID: c)
            t.check(!r.ok, "end reports the failure")
            _ = f.power.take()
            if case .marker = f.markers.read() { t.check(true, "marker kept") } else { t.check(false, "marker kept") }
            f.power.failing = []
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            t.expect(f.power.take(), ["pmset -a disablesleep 0", "pmset -a disablesleep 1", "pmset -a powermode 1"],
                     "next begin restores the leftover first")
        }

        t.section("unreadable marker at launch")
        do {
            let f = Fixture(root, "s12", sleepDisabled: true)
            try? FileManager.default.createDirectory(at: f.markers.url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data("{ not json".utf8).write(to: f.markers.url)
            f.core.recoverAtLaunch()
            t.expect(f.power.take(), ["pmset -a disablesleep 0"], "sleep restored to be safe")
            t.check(f.markers.read() == .none, "marker deleted")
        }

        t.section("SIGTERM while on")
        do {
            let f = Fixture(root, "s13")
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            _ = f.power.take()
            f.power.lidClosed = true
            f.core.terminate()
            t.expect(f.power.take(), ["pmset -a disablesleep 0", "pmset -a powermode 0"], "restored")
            t.check(f.core.lastEnd?.reason == .terminated, "reason: stopped by the system")
            f.advance(10); f.core.tick()
            t.expect(f.power.take(), [], "no sleepnow on shutdown")
        }

        t.section("Macs with lowpowermode, with no power mode, and with Low Power already on")
        do {
            let a = Fixture(root, "s14", modes: PowerModes(key: "lowpowermode", values: ["b": 0, "c": 0]))
            let c = a.core.connectionOpened()
            _ = a.core.begin(connectionID: c, clientPID: 1, lowPower: true)
            _ = a.core.end(connectionID: c)
            t.expect(a.power.take(), ["pmset -a disablesleep 1", "pmset -a lowpowermode 1",
                                      "pmset -a disablesleep 0", "pmset -a lowpowermode 0"], "lowpowermode key")

            let b = Fixture(root, "s15", modes: nil)
            let d = b.core.connectionOpened()
            let r = b.core.begin(connectionID: d, clientPID: 1, lowPower: true)
            _ = b.core.end(connectionID: d)
            t.expect(b.power.take(), ["pmset -a disablesleep 1", "pmset -a disablesleep 0"], "no power mode: sleep only")
            t.check((r.note ?? "").contains("no Low Power Mode"), "note says so")

            let e = Fixture(root, "s16", modes: PowerModes(key: "powermode", values: ["b": 1, "c": 1]))
            let g = e.core.connectionOpened()
            let r2 = e.core.begin(connectionID: g, clientPID: 1, lowPower: true)
            _ = e.core.end(connectionID: g)
            t.expect(e.power.take(), ["pmset -a disablesleep 1", "pmset -a disablesleep 0"], "already low: left alone")
            t.check((r2.note ?? "").contains("already on"), "note says so")

            let h = Fixture(root, "s16b", modes: PowerModes(key: "powermode", values: ["b": 1, "c": 0]))
            let k = h.core.connectionOpened()
            _ = h.core.begin(connectionID: k, clientPID: 1, lowPower: true)
            _ = h.core.end(connectionID: k)
            t.expect(h.power.take(), ["pmset -a disablesleep 1", "pmset -a powermode 1",
                                      "pmset -a disablesleep 0", "pmset -c powermode 0"], "battery already low: only charger restored")
        }

        t.section("begin while on hands the session over")
        do {
            let f = Fixture(root, "s17")
            let old = f.core.connectionOpened()
            let new = f.core.connectionOpened()
            _ = f.core.begin(connectionID: old, clientPID: 1, lowPower: false)
            _ = f.power.take()
            let r = f.core.begin(connectionID: new, clientPID: 2, lowPower: false)
            t.check(r.ok && f.power.take().isEmpty, "second begin writes nothing")
            f.core.connectionClosed(old, why: "invalidated")
            t.check(f.core.session != nil, "old connection closing keeps it on")
            f.core.connectionClosed(new, why: "invalidated")
            t.expect(f.power.take(), ["pmset -a disablesleep 0"], "new owner closing restores")
        }

        t.section("idle exit after 30 s")
        do {
            let f = Fixture(root, "s18")
            let c = f.core.connectionOpened()
            _ = f.core.begin(connectionID: c, clientPID: 1, lowPower: false)
            f.advance(60); f.core.tick()
            t.check(f.exits == 0, "no exit while on")
            _ = f.core.end(connectionID: c)
            f.advance(60); f.core.tick()
            t.check(f.exits == 0, "no exit while a connection is open")
            f.core.connectionClosed(c, why: "invalidated")
            f.advance(29); f.core.tick()
            t.check(f.exits == 0, "no exit at 29 s idle")
            f.advance(1); f.core.tick()
            t.check(f.exits == 1, "exit at 30 s idle")
        }

        // MARK: XPC

        t.section("XPC round trip (anonymous in-process listener, no requirement)")
        do {
            let f = Fixture(root, "x1")
            let delegate = HelperListenerDelegate(core: f.core, requirement: nil)
            let listener = NSXPCListener.anonymous()
            listener.delegate = delegate
            listener.resume()
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = BackpackXPC.makeInterface()
            connection.resume()
            var errors = 0
            let helper = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in errors += 1 } as! BackpackHelperProtocol

            var version = 0
            helper.helperVersion { v, _ in version = v }
            t.expect(version, BackpackXPC.protocolVersion, "helperVersion")
            var began = false
            helper.begin(lowPower: true) { ok, _ in began = ok }
            t.check(began, "begin")
            var alive = false
            helper.heartbeat { active, _ in alive = active }
            t.check(alive, "heartbeat")
            var status = (false, false)
            helper.status { sleep, active, _ in status = (sleep, active) }
            t.check(status == (true, true), "status: sleepDisabled 1, active")
            var ended = false
            helper.end { ok, _ in ended = ok }
            t.check(ended, "end")
            t.expect(f.core.queue.sync { f.power.take() },
                     ["pmset -a disablesleep 1", "pmset -a powermode 1", "pmset -a disablesleep 0", "pmset -a powermode 0"],
                     "writes over XPC")

            helper.begin(lowPower: false) { _, _ in }
            connection.invalidate()
            var waited = 0
            while f.core.queue.sync(execute: { f.core.session != nil }) && waited < 50 {
                usleep(100_000); waited += 1
            }
            t.expect(f.core.queue.sync { f.power.take() }, ["pmset -a disablesleep 1", "pmset -a disablesleep 0"],
                     "client connection invalidated: restored")
            t.check(f.core.queue.sync { f.core.lastEnd?.reason } == .clientDisconnected, "reason: Hotch quit or crashed")
            t.expect(errors, 0, "no XPC errors")
            listener.invalidate()
        }

        t.section("code-signing requirement")
        for requirement in [BackpackXPC.appRequirement, BackpackXPC.helperRequirement] {
            var parsed: SecRequirement?
            t.check(SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess,
                    "compiles: \(requirement)")
        }
        do {
            let f = Fixture(root, "x2")
            let delegate = HelperListenerDelegate(core: f.core, requirement: BackpackXPC.appRequirement)
            let listener = NSXPCListener.anonymous()
            listener.delegate = delegate
            listener.resume()
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = BackpackXPC.makeInterface()
            connection.resume()
            var rejected = false
            var answered = false
            let helper = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in rejected = true } as! BackpackHelperProtocol
            helper.begin(lowPower: true) { _, _ in answered = true }
            t.check(rejected && !answered, "this unsigned test binary is refused before begin runs")
            t.expect(f.core.queue.sync { f.power.take() }, [], "nothing written for a refused client")
            connection.invalidate()
            listener.invalidate()
        }

        return t.finish()
    }
}

// MARK: - Test support

final class TestRun {
    private(set) var passed = 0
    private(set) var failed = 0

    func section(_ title: String) { print("\n\(title)") }

    func check(_ ok: Bool, _ label: String) {
        if ok { passed += 1; print("  PASS  \(label)") } else { failed += 1; print("  FAIL  \(label)") }
    }

    func expect<T: Equatable>(_ got: T, _ want: T, _ label: String) {
        if got == want {
            passed += 1
            print("  PASS  \(label)\(Self.show(got))")
        } else {
            failed += 1
            print("  FAIL  \(label)\n        got:  \(got)\n        want: \(want)")
        }
    }

    func finish() -> Bool {
        print("\n\(passed) passed, \(failed) failed")
        return failed == 0
    }

    private static func show<T>(_ value: T) -> String {
        if let commands = value as? [String] {
            return commands.isEmpty ? "  (no writes)" : "  " + commands.joined(separator: " | ")
        }
        return ""
    }
}

/// One helper process: fake clock, simulated power, its own marker folder.
final class Fixture {
    var now = Date(timeIntervalSince1970: 1_792_454_400) // 2026-10-20 00:00 UTC
    let power: SimulatedPower
    let markers: MarkerStore
    var core: BackpackHelperCore!
    var exits = 0

    init(_ root: URL, _ name: String,
         sleepDisabled: Bool = false,
         modes: PowerModes? = PowerModes(key: "powermode", values: ["b": 0, "c": 0]),
         power: SimulatedPower? = nil) {
        self.power = power ?? SimulatedPower(sleepDisabled: sleepDisabled, modes: modes, lidClosed: false)
        markers = MarkerStore(path: root.appendingPathComponent(name).appendingPathComponent("backpack-active.json").path)
        core = BackpackHelperCore(power: self.power, markers: markers, now: { [unowned self] in self.now }, log: { _ in })
        core.requestExit = { [unowned self] in self.exits += 1 }
    }

    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}
