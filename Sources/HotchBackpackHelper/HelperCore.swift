import Foundation
import IOKit
#if canImport(BackpackShared)
import BackpackShared
#endif

// MARK: - Power mode snapshot

/// Which `pmset` key carries the power mode on this Mac, and its value per power
/// source.
///
/// Macs that also offer High Power Mode report `powermode` (0 automatic, 1 low,
/// 2 high); the rest report `lowpowermode` (0 or 1). Values are kept per source
/// because they can differ (Low Power on battery only is a common choice), and a
/// single `-a` restore would flatten that.
struct PowerModes: Codable, Equatable {
    /// "powermode" or "lowpowermode".
    var key: String
    /// pmset source flag without the dash ("b" battery, "c" charger, "u" UPS) to value.
    var values: [String: Int]

    /// The value that means Low Power on both keys.
    static let low = 1
}

enum PMSetParser {
    /// Parses `pmset -g custom`. Returns nil on Macs with no power mode setting.
    static func powerModes(fromCustom text: String) -> PowerModes? {
        var section: String?
        var byKey: [String: [String: Int]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch line {
            case "Battery Power:": section = "b"; continue
            case "AC Power:": section = "c"; continue
            case "UPS Power:": section = "u"; continue
            default: break
            }
            guard let source = section else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            let key = String(parts[0])
            guard key == "powermode" || key == "lowpowermode" else { continue }
            byKey[key, default: [:]][source] = value
        }
        if let values = byKey["powermode"], !values.isEmpty { return PowerModes(key: "powermode", values: values) }
        if let values = byKey["lowpowermode"], !values.isEmpty { return PowerModes(key: "lowpowermode", values: values) }
        return nil
    }
}

// MARK: - Power control

/// Everything the helper reads from or writes to the power system. The daemon
/// uses `SystemPower`; `--dry-run` and `--self-test` use `SimulatedPower`, which
/// prints or records writes instead of running them.
protocol PowerControl: AnyObject {
    func readSleepDisabled() -> Bool?
    func readPowerModes() -> PowerModes?
    func readLidClosed() -> Bool?
    /// Runs `/usr/bin/pmset` with these arguments. True on exit status 0.
    @discardableResult func pmset(_ args: [String]) -> Bool
}

/// Reads one boolean property of IOPMrootDomain. Read-only; no privileges needed.
enum RootDomain {
    static func bool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return value as? Bool
    }
}

final class SystemPower: PowerControl {
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) { self.log = log }

    func readSleepDisabled() -> Bool? { RootDomain.bool("SleepDisabled") }
    func readLidClosed() -> Bool? { RootDomain.bool("AppleClamshellState") }

    func readPowerModes() -> PowerModes? {
        guard let result = Self.run(["-g", "custom"]), result.status == 0 else { return nil }
        return PMSetParser.powerModes(fromCustom: result.output)
    }

    @discardableResult
    func pmset(_ args: [String]) -> Bool {
        guard let result = Self.run(args) else {
            log("pmset \(args.joined(separator: " ")): could not launch")
            return false
        }
        if result.status != 0 {
            log("pmset \(args.joined(separator: " ")) exited \(result.status): \(result.output)")
        }
        return result.status == 0
    }

    static func run(_ args: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Holds power state in memory and applies `pmset` arguments to it instead of
/// running them. Seeded from the real Mac in `--dry-run` (reads only), from
/// fixed values in `--self-test`.
final class SimulatedPower: PowerControl {
    var sleepDisabled: Bool
    var modes: PowerModes?
    var lidClosed: Bool?
    /// Every write, in order, as "pmset <args>".
    private(set) var commands: [String] = []
    /// Writes that should fail, as "pmset <args>".
    var failing: Set<String> = []
    /// Called for every write; `--dry-run` prints here.
    var echo: ((String) -> Void)?

    init(sleepDisabled: Bool, modes: PowerModes?, lidClosed: Bool?) {
        self.sleepDisabled = sleepDisabled
        self.modes = modes
        self.lidClosed = lidClosed
    }

    func readSleepDisabled() -> Bool? { sleepDisabled }
    func readPowerModes() -> PowerModes? { modes }
    func readLidClosed() -> Bool? { lidClosed }

    /// Returns the writes since the last call and forgets them.
    func take() -> [String] {
        defer { commands.removeAll() }
        return commands
    }

    @discardableResult
    func pmset(_ args: [String]) -> Bool {
        let command = "pmset " + args.joined(separator: " ")
        commands.append(command)
        echo?(command)
        if failing.contains(command) { return false }
        apply(args)
        return true
    }

    private func apply(_ args: [String]) {
        guard args.count == 3, args[0].hasPrefix("-"), let value = Int(args[2]) else { return }
        let flag = String(args[0].dropFirst())
        if args[1] == "disablesleep" {
            sleepDisabled = value == 1
        } else if var current = modes, current.key == args[1] {
            if flag == "a" {
                for source in current.values.keys { current.values[source] = value }
            } else if current.values[flag] != nil {
                current.values[flag] = value
            }
            modes = current
        }
    }
}

// MARK: - Marker

/// What the helper changed, written to disk before it changes anything.
struct BackpackMarker: Codable, Equatable {
    var formatVersion = 1
    var startedAt: Date
    /// True only when Hotch moved SleepDisabled from 0 to 1. A value the user set
    /// by hand is never touched.
    var sleepDisabledByHotch: Bool
    /// Power mode values before Hotch turned Low Power on. Nil when Hotch did not
    /// change the power mode.
    var priorPowerModes: PowerModes?
    var clientPID: Int32
}

final class MarkerStore {
    enum ReadResult: Equatable {
        case none
        case marker(BackpackMarker)
        case unreadable(String)
    }

    let url: URL

    init(path: String) { url = URL(fileURLWithPath: path) }

    func read() -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        do {
            let data = try Data(contentsOf: url)
            return .marker(try Self.decoder.decode(BackpackMarker.self, from: data))
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    func write(_ marker: BackpackMarker) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try Self.encoder.encode(marker).write(to: url, options: .atomic)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - State machine

enum HelperEndReason: String {
    case clientRequest = "ended by Hotch"
    case clientDisconnected = "Hotch quit or crashed"
    case heartbeatTimeout = "no heartbeat from Hotch for 3 minutes"
    case hardCap = "4 h 15 min limit reached"
    case recoveredAtLaunch = "restored a session left over from before the helper started"
    case terminated = "helper was stopped by the system"
    case beginFailed = "start failed and was rolled back"
}

/// The helper's whole state machine. Not thread-safe: every call happens on
/// `queue` (XPC handlers and the tick timer hop onto it), or on one thread in the
/// self-test.
///
/// States: idle (no session) and active (one session, owned by the connection
/// that began it). Every way out of active goes through `restore`.
final class BackpackHelperCore {
    struct Session {
        var ownerID: Int
        var startedAt: Date
        var lastHeartbeat: Date
        var marker: BackpackMarker
    }

    let queue = DispatchQueue(label: "com.hojaejung.hotch.backpack.core")
    let power: PowerControl
    let markers: MarkerStore
    let now: () -> Date
    let log: (String) -> Void

    var heartbeatTimeout = BackpackXPC.heartbeatTimeout
    var hardCap = BackpackXPC.helperHardCap
    var idleExitDelay = BackpackXPC.idleExitDelay
    /// How long after restoring sleep with the lid still shut to ask for sleep.
    var sleepCheckDelay: TimeInterval = 5
    /// Called once when idle long enough. The daemon exits here.
    var requestExit: () -> Void = {}

    private(set) var session: Session?
    private(set) var lastEnd: (reason: HelperEndReason, at: Date)?
    private(set) var exitRequested = false
    private(set) var connections: Set<Int> = []
    private var nextConnectionID = 1
    private var idleSince: Date?
    private var pendingSleepCheck: Date?

    init(power: PowerControl, markers: MarkerStore, now: @escaping () -> Date, log: @escaping (String) -> Void) {
        self.power = power
        self.markers = markers
        self.now = now
        self.log = log
    }

    // MARK: Connections

    func connectionOpened() -> Int {
        let id = nextConnectionID
        nextConnectionID += 1
        connections.insert(id)
        updateIdle()
        return id
    }

    /// Invalidation and interruption both land here. Losing the connection that
    /// owns the session means Hotch quit or crashed, so sleep goes back on.
    func connectionClosed(_ id: Int, why: String) {
        guard connections.remove(id) != nil else { return }
        log("connection \(id) \(why)")
        if let session, session.ownerID == id {
            restore(session.marker, reason: .clientDisconnected, sleepIfLidClosed: true)
        }
        updateIdle()
    }

    // MARK: Requests

    func begin(connectionID: Int, clientPID: Int32, lowPower: Bool) -> (ok: Bool, note: String?) {
        let t = now()
        if var current = session {
            current.ownerID = connectionID
            current.lastHeartbeat = t
            session = current
            log("begin while active: session handed to connection \(connectionID)")
            return (true, "already on since \(Self.clock(current.startedAt))")
        }

        // A marker with no session means an earlier restore failed. Retry it
        // first so the new session's "prior" values are the user's, not Hotch's.
        if case .marker(let stale) = markers.read() {
            log("found a leftover marker before begin; restoring it first")
            guard restore(stale, reason: .recoveredAtLaunch, sleepIfLidClosed: false) else {
                return (false, "could not restore an earlier session")
            }
        }

        var notes: [String] = []
        let sleepAlreadyDisabled = power.readSleepDisabled() ?? false
        if sleepAlreadyDisabled {
            notes.append("sleep was already disabled by hand; Hotch will leave that setting alone")
        }

        var prior: PowerModes?
        if lowPower {
            if let modes = power.readPowerModes() {
                if modes.values.values.contains(where: { $0 != PowerModes.low }) {
                    prior = modes
                } else {
                    notes.append("Low Power Mode was already on")
                }
            } else {
                notes.append("this Mac has no Low Power Mode setting")
            }
        }

        let marker = BackpackMarker(
            startedAt: t,
            sleepDisabledByHotch: !sleepAlreadyDisabled,
            priorPowerModes: prior,
            clientPID: clientPID)

        // Write-ahead: no system change without a record of how to undo it.
        do {
            try markers.write(marker)
        } catch {
            log("could not write marker at \(markers.url.path): \(error)")
            return (false, "could not write the recovery marker")
        }

        if marker.sleepDisabledByHotch {
            let wrote = power.pmset(["-a", "disablesleep", "1"])
            let confirmed = power.readSleepDisabled() != false
            if !wrote || !confirmed {
                log("disablesleep 1 failed (wrote \(wrote), confirmed \(confirmed)); rolling back")
                restore(marker, reason: .beginFailed, sleepIfLidClosed: false)
                return (false, "macOS did not accept the sleep setting")
            }
        }

        if let prior, !power.pmset(["-a", prior.key, String(PowerModes.low)]) {
            // Restore stays safe: it only puts back sources still at the low value.
            notes.append("could not turn on Low Power Mode")
        }

        session = Session(ownerID: connectionID, startedAt: t, lastHeartbeat: t, marker: marker)
        pendingSleepCheck = nil
        updateIdle()
        log("session on (connection \(connectionID), pid \(clientPID), low power \(prior != nil))")
        return (true, notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    func end(connectionID: Int) -> (ok: Bool, note: String?) {
        if let session {
            let ok = restore(session.marker, reason: .clientRequest, sleepIfLidClosed: true)
            updateIdle()
            return (ok, ok ? nil : "could not restore sleep; the helper retries at next launch")
        }
        if case .marker(let stale) = markers.read() {
            let ok = restore(stale, reason: .clientRequest, sleepIfLidClosed: false)
            updateIdle()
            return (ok, "restored a leftover session")
        }
        return (true, "not active")
    }

    /// Only the owner's heartbeat keeps the session alive.
    func heartbeat(connectionID: Int) -> (active: Bool, note: String?) {
        guard var current = session else {
            return (false, lastEnd.map { $0.reason.rawValue })
        }
        guard current.ownerID == connectionID else {
            return (true, "session belongs to another connection")
        }
        current.lastHeartbeat = now()
        session = current
        return (true, nil)
    }

    func status() -> (sleepDisabled: Bool, active: Bool, note: String?) {
        let sleepDisabled = power.readSleepDisabled() ?? false
        if let session {
            let quiet = Int(now().timeIntervalSince(session.lastHeartbeat))
            let low = session.marker.priorPowerModes != nil ? "on" : "unchanged"
            return (sleepDisabled, true,
                    "on since \(Self.clock(session.startedAt)), last heartbeat \(quiet) s ago, low power \(low)")
        }
        if let lastEnd {
            return (sleepDisabled, false, "off; last session \(lastEnd.reason.rawValue) at \(Self.clock(lastEnd.at))")
        }
        return (sleepDisabled, false, "off")
    }

    // MARK: Lifecycle

    /// Runs once at helper launch. Any marker here was left by a session that
    /// never got its restore: the app crashed and the helper with it, the Mac
    /// rebooted or lost power (SleepDisabled survives reboots), or the helper was
    /// killed.
    func recoverAtLaunch() {
        switch markers.read() {
        case .none:
            log("launch: no marker, nothing to restore")
        case .marker(let marker):
            log("launch: found marker from \(Self.clock(marker.startedAt)); restoring")
            restore(marker, reason: .recoveredAtLaunch, sleepIfLidClosed: false)
        case .unreadable(let why):
            // Hotch wrote it, so Hotch most likely disabled sleep. A Mac that never
            // sleeps in a bag is the worse failure, so sleep goes back on. The
            // power mode is left alone because its prior value is unknown.
            log("launch: marker unreadable (\(why)); restoring sleep to be safe")
            if power.pmset(["-a", "disablesleep", "0"]) { try? markers.remove() }
            lastEnd = (.recoveredAtLaunch, now())
        }
        updateIdle()
    }

    /// SIGTERM: launchd is unloading the job (unregister, shutdown, logout of the
    /// system domain). Restore before exiting.
    func terminate() {
        if let session {
            restore(session.marker, reason: .terminated, sleepIfLidClosed: false)
        }
    }

    /// Called every few seconds by a timer on `queue`.
    func tick() {
        let t = now()
        if let session {
            if t.timeIntervalSince(session.startedAt) >= hardCap {
                restore(session.marker, reason: .hardCap, sleepIfLidClosed: true)
            } else if t.timeIntervalSince(session.lastHeartbeat) >= heartbeatTimeout {
                restore(session.marker, reason: .heartbeatTimeout, sleepIfLidClosed: true)
            }
        }

        if let due = pendingSleepCheck, t >= due {
            pendingSleepCheck = nil
            // A check that comes due long after it was set means the Mac slept in
            // between, which is what was wanted.
            if session == nil, t.timeIntervalSince(due) < 60, power.readLidClosed() == true {
                log("lid still closed after restoring sleep; asking the Mac to sleep now")
                power.pmset(["sleepnow"])
            }
        }

        updateIdle()
        if let since = idleSince, !exitRequested, t.timeIntervalSince(since) >= idleExitDelay {
            exitRequested = true
            log("idle for \(Int(idleExitDelay)) s; exiting")
            requestExit()
        }
    }

    // MARK: Restore

    /// The one way sleep goes back on. Returns false only when SleepDisabled could
    /// not be cleared, in which case the marker stays so the next launch retries.
    @discardableResult
    private func restore(_ marker: BackpackMarker, reason: HelperEndReason, sleepIfLidClosed: Bool) -> Bool {
        log("restoring: \(reason.rawValue)")
        var ok = true
        if marker.sleepDisabledByHotch, !power.pmset(["-a", "disablesleep", "0"]) {
            ok = false
            log("ERROR: disablesleep 0 failed; keeping the marker so the next launch retries")
        }
        if let prior = marker.priorPowerModes {
            restorePowerModes(prior)
        }
        if ok {
            do { try markers.remove() } catch { log("could not delete marker: \(error)") }
        }
        session = nil
        lastEnd = (reason, now())

        // macOS may or may not re-evaluate a closed lid when SleepDisabled is
        // cleared, and an agent holding an idle-sleep assertion would keep the Mac
        // awake in the bag. So a few seconds later, if the lid is still shut, ask
        // for sleep outright. Never at launch: a Mac booting in clamshell mode on
        // a desk must not be put to sleep.
        if sleepIfLidClosed, marker.sleepDisabledByHotch, power.readLidClosed() == true {
            pendingSleepCheck = now().addingTimeInterval(sleepCheckDelay)
        }
        return ok
    }

    /// Puts back only sources still at the low value Hotch set. A source the user
    /// changed during the session keeps the user's choice.
    private func restorePowerModes(_ prior: PowerModes) {
        let current = power.readPowerModes()
        var targets: [String: Int] = [:]
        for (source, value) in prior.values where value != PowerModes.low {
            let currentValue = current?.key == prior.key ? current?.values[source] : nil
            if currentValue == nil || currentValue == PowerModes.low {
                targets[source] = value
            }
        }
        guard !targets.isEmpty else { return }
        let changedEverySource = prior.values.allSatisfy { $0.value != PowerModes.low }
        if changedEverySource, targets.count == prior.values.count, Set(targets.values).count == 1,
           let value = targets.values.first {
            power.pmset(["-a", prior.key, String(value)])
        } else {
            for source in targets.keys.sorted() {
                power.pmset(["-\(source)", prior.key, String(targets[source]!)])
            }
        }
    }

    private func updateIdle() {
        let idle = session == nil && connections.isEmpty && pendingSleepCheck == nil
        if !idle {
            idleSince = nil
        } else if idleSince == nil {
            idleSince = now()
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
