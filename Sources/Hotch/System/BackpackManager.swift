import Foundation
import Combine
import IOKit
import IOKit.ps
import ServiceManagement
import Security
#if canImport(BackpackShared)
import BackpackShared
#endif

/// Backpack mode: close the lid, agents keep running.
///
/// Hotch asks its root helper (registered with `SMAppService`, approved once in
/// System Settings > Login Items) to set `SleepDisabled`, then keeps the session
/// honest from this side: a heartbeat every 30 s, guardrails every 15 s, and the
/// lid watched every 2 s. The helper restores sleep on its own if this side goes
/// quiet, quits or crashes, so nothing here has to be right for the Mac to sleep
/// again eventually; it only has to be right for the Mac to sleep *promptly*.
@MainActor
final class BackpackManager: ObservableObject {
    /// The app's instance. Wire `activeAgentCount` at launch; until then it reads
    /// 0, which ends a session after the 10 minute grace.
    static let shared = BackpackManager(activeAgentCount: { 0 })

    enum State: Equatable {
        case unavailable(String)
        case needsApproval
        case off
        case on(since: Date)
        case ending
    }

    enum EndReason: Equatable {
        case user
        case agentsFinished
        case lowBattery(percent: Int)
        case thermal(String)
        case timeLimit
        case lidOpened
        /// The helper ended the session by itself (heartbeat gap, hard cap, restart).
        case helperEnded(String)
        /// Four heartbeats in a row failed. The helper restores on its own.
        case helperUnreachable(String)

        var label: String {
            switch self {
            case .user: return "turned off"
            case .agentsFinished: return "agents finished"
            case .lowBattery(let percent): return "battery at \(percent)%"
            case .thermal(let level): return "Mac running hot (\(level))"
            case .timeLimit: return "4 hour limit"
            case .lidOpened: return "lid opened"
            case .helperEnded(let why): return "helper ended it: \(why)"
            case .helperUnreachable: return "helper stopped answering"
            }
        }
    }

    struct Summary: Equatable {
        var startedAt: Date
        var endedAt: Date
        var lidClosedFor: TimeInterval
        var agentsFinished: Int
        var batteryStart: Int?
        var batteryEnd: Int?
        var reason: EndReason
        /// Nil when the lid never closed during the session.
        var screenLock: ScreenLockResult?
        var notes: [String]

        var awakeFor: TimeInterval { endedAt.timeIntervalSince(startedAt) }

        var headline: String {
            var parts = ["Awake \(Self.duration(awakeFor))"]
            parts.append(agentsFinished == 1 ? "1 agent finished" : "\(agentsFinished) agents finished")
            if let start = batteryStart, let end = batteryEnd { parts.append("battery \(start)% → \(end)%") }
            parts.append("ended: \(reason.label)")
            return parts.joined(separator: " · ")
        }

        static func duration(_ seconds: TimeInterval) -> String {
            let minutes = Int(seconds / 60)
            return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        }
    }

    enum Limits {
        static let batteryFloor = 20
        static let timeLimit = BackpackXPC.appTimeLimit
        static let agentsIdleFor: TimeInterval = 5 * 60
        static let graceWithoutAgents: TimeInterval = 10 * 60
        static let heartbeatEvery = BackpackXPC.heartbeatInterval
        static let guardrailsEvery: TimeInterval = 15
        static let lidEvery: TimeInterval = 2
        static let heartbeatFailuresBeforeGivingUp = 4
    }

    @Published private(set) var state: State = .off
    /// Set when the user can see it: at the end if the lid is open, otherwise at
    /// the moment the lid reopens.
    @Published private(set) var lastSummary: Summary?
    @Published private(set) var endReason: EndReason?
    @Published private(set) var lidIsClosed = false
    /// Last thing that went wrong starting or stopping, for the UI.
    @Published private(set) var lastError: String?
    /// Turn on Low Power Mode for the session.
    @Published var lowPowerWhileOn = true
    /// Reopening the lid ends the session, so a later close sleeps normally.
    var endsWhenLidOpens = true

    /// Number of Claude and Codex sessions currently working. Read every 15 s
    /// while on.
    var activeAgentCount: @MainActor () -> Int
    let isDryRun: Bool
    private let env: BackpackEnvironment

    private var session: SessionInfo?
    private var isStarting = false
    private var pendingSummary: Summary?
    private var heartbeatFailures = 0
    private var sessionLoops: [Task<Void, Never>] = []
    private var lidLoop: Task<Void, Never>?
    private var approvalPoll: Task<Void, Never>?
    private var appNapGuard: NSObjectProtocol?

    private struct SessionInfo {
        var startedAt: Date
        var batteryStart: Int?
        var agents: AgentWatch
        var lidClosedAt: Date?
        var lidClosedTotal: TimeInterval = 0
        var screenLock: ScreenLockResult?
        var notes: [String] = []
    }

    init(activeAgentCount: @escaping @MainActor () -> Int, dryRun: Bool = false, environment: BackpackEnvironment? = nil) {
        self.activeAgentCount = activeAgentCount
        self.isDryRun = dryRun
        self.env = environment ?? (dryRun ? .dryRun() : .live())
        refresh()
    }

    // MARK: UI conveniences (the names the panel already uses)

    typealias Phase = State
    var phase: State { state }

    var isOn: Bool {
        if case .on = state { return true }
        return false
    }

    var footerLine: String {
        isOn ? "Mac stays awake with the lid closed" : "lid closed, agents keep going"
    }

    /// Button actions. The outcome shows up in `state` and `lastError`.
    func start() { Task { await startSession() } }
    func stop() { Task { await stopSession() } }

    // MARK: Availability

    /// Re-reads signing, install location and helper status. Cheap; call it when
    /// the panel opens.
    func refresh() {
        switch state {
        case .on, .ending: return
        default: state = availability()
        }
        if state != .needsApproval { approvalPoll?.cancel(); approvalPoll = nil }
    }

    private func availability() -> State {
        if let problem = env.installProblem() { return .unavailable(problem) }
        if env.lidClosed() == nil { return .unavailable("this Mac has no lid") }
        let signing = env.signing()
        if !signing.satisfiesHelperRequirement {
            return .unavailable(signing.isAdHoc ? "needs a signed build" : "needs a build signed by team \(BackpackXPC.teamIdentifier)")
        }
        switch env.service.status {
        case .notRegistered, .enabled: return .off
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable("helper is missing from the app bundle")
        @unknown default: return .unavailable("unknown helper status")
        }
    }

    /// Opens System Settings > Login Items and watches for the approval for up to
    /// 3 minutes, so the state flips without the user coming back to Hotch.
    func openApprovalSettings() {
        env.service.openApprovalSettings()
        approvalPoll?.cancel()
        guard env.runsTimers else { return }
        approvalPoll = Task { @MainActor [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.state != .needsApproval { return }
            }
        }
    }

    /// Ends any session and removes the helper from launchd. For a Settings
    /// "Remove helper" button.
    func removeHelper() async {
        await stopSession()
        do { try await env.service.unregister() } catch { lastError = error.localizedDescription }
        refresh()
    }

    // MARK: Start and stop

    @discardableResult
    func startSession(lowPower: Bool? = nil) async -> Bool {
        // A second tap while the first is still talking to the helper.
        guard !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        refresh()
        lastError = nil
        guard state == .off || state == .needsApproval else { return false }

        if env.service.status == .notRegistered {
            // A first registration normally lands in .requiresApproval (and can
            // throw while doing so); only report an error if it landed elsewhere.
            do { try env.service.register() } catch { lastError = error.localizedDescription }
            refresh()
            if state == .needsApproval { lastError = nil }
        }
        guard state == .off, env.service.status == .enabled else { return false }

        let begun: (ok: Bool, note: String?)
        do {
            let version = try await env.helper.version()
            guard version.protocolVersion == BackpackXPC.protocolVersion else {
                lastError = "helper speaks protocol \(version.protocolVersion), Hotch expects \(BackpackXPC.protocolVersion); quit and reopen Hotch"
                env.helper.disconnect()
                return false
            }
            begun = try await env.helper.begin(lowPower: lowPower ?? lowPowerWhileOn)
        } catch {
            lastError = "could not reach the helper: \(error.localizedDescription)"
            env.helper.disconnect()
            return false
        }
        guard begun.ok else {
            lastError = begun.note ?? "the helper could not disable sleep"
            env.helper.disconnect()
            return false
        }

        let t = env.now()
        let closed = env.lidClosed() ?? false
        session = SessionInfo(
            startedAt: t,
            batteryStart: env.battery()?.percent,
            agents: AgentWatch(initial: activeAgentCount(), at: t),
            lidClosedAt: closed ? t : nil,
            notes: begun.note.map { [$0] } ?? [])
        lidIsClosed = closed
        endReason = nil
        heartbeatFailures = 0
        state = .on(since: t)
        startLoops()
        return true
    }

    func stopSession() async {
        await end(.user)
    }

    // MARK: Ticks (driven by timers; called directly by tests)

    func heartbeatTick() async {
        guard case .on = state else { return }
        do {
            let reply = try await env.helper.heartbeat()
            heartbeatFailures = 0
            if !reply.active {
                await end(.helperEnded(reply.note ?? "no reason given"))
            }
        } catch {
            heartbeatFailures += 1
            if heartbeatFailures >= Limits.heartbeatFailuresBeforeGivingUp {
                await end(.helperUnreachable(error.localizedDescription))
            }
        }
    }

    func guardrailTick() async {
        guard case .on(let since) = state, var current = session else { return }
        let t = env.now()
        current.agents.record(activeAgentCount(), at: t)
        session = current
        if let reason = Self.guardrailVerdict(
            now: t, startedAt: since, battery: env.battery(),
            thermal: env.thermalState(), agents: current.agents) {
            await end(reason)
        }
    }

    func lidTick() async {
        guard let closed = env.lidClosed(), closed != lidIsClosed else { return }
        let t = env.now()
        lidIsClosed = closed
        if closed {
            guard case .on = state else { return }
            session?.lidClosedAt = t
            // Lock first, before anything else can go wrong: an awake Mac in a bag
            // must not be one lid-open away from an unlocked desktop.
            let lock = env.lockScreen()
            session?.screenLock = lock
            if case .unavailable(let why) = lock {
                session?.notes.append("screen not locked: \(why)")
            }
        } else {
            if let closedAt = session?.lidClosedAt {
                session?.lidClosedTotal += t.timeIntervalSince(closedAt)
                session?.lidClosedAt = nil
            }
            if case .on = state, endsWhenLidOpens {
                await end(.lidOpened)
            }
            if let pending = pendingSummary {
                pendingSummary = nil
                lastSummary = pending
            }
            if case .on = state {} else { stopLidLoop() }
        }
    }

    /// The guardrails as a pure function. Order is urgency: heat, battery, time,
    /// then agents.
    nonisolated static func guardrailVerdict(now: Date, startedAt: Date, battery: BatteryReading?,
                                             thermal: ProcessInfo.ThermalState, agents: AgentWatch) -> EndReason? {
        if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            return .thermal(thermal == .critical ? "critical" : "serious")
        }
        if let battery, !battery.onAC, battery.percent <= Limits.batteryFloor {
            return .lowBattery(percent: battery.percent)
        }
        if now.timeIntervalSince(startedAt) >= Limits.timeLimit {
            return .timeLimit
        }
        if agents.allFinished(at: now, sessionStart: startedAt) {
            return .agentsFinished
        }
        return nil
    }

    // MARK: Ending

    private func end(_ reason: EndReason) async {
        guard case .on = state, var current = session else { return }
        state = .ending
        stopSessionLoops()

        switch reason {
        case .helperEnded, .helperUnreachable:
            break // already restored, or the disconnect below makes it restore now
        default:
            do {
                let reply = try await env.helper.end()
                if !reply.ok { current.notes.append(reply.note ?? "the helper could not restore sleep") }
            } catch {
                current.notes.append("the helper did not answer; it restores sleep on its own within 3 minutes")
            }
        }
        // Always let go of the connection. A helper that is stuck sees its owner
        // leave and restores at once; a healthy one is idle and exits after 30 s
        // instead of staying resident for as long as Hotch runs.
        env.helper.disconnect()

        let t = env.now()
        if let closedAt = current.lidClosedAt {
            current.lidClosedTotal += t.timeIntervalSince(closedAt)
            current.lidClosedAt = nil
        }
        current.agents.record(activeAgentCount(), at: t)
        let summary = Summary(
            startedAt: current.startedAt,
            endedAt: t,
            lidClosedFor: current.lidClosedTotal,
            agentsFinished: current.agents.finished,
            batteryStart: current.batteryStart,
            batteryEnd: env.battery()?.percent,
            reason: reason,
            screenLock: current.screenLock,
            notes: current.notes)
        session = nil
        endReason = reason
        state = availability()

        if lidIsClosed {
            // Shown when the lid opens; the lid loop keeps running until then.
            pendingSummary = summary
        } else {
            lastSummary = summary
            stopLidLoop()
        }
    }

    // MARK: Loops

    private func startLoops() {
        guard env.runsTimers else { return }
        stopSessionLoops()
        // Hotch is a menu bar app with nothing on screen once the lid closes. App
        // Nap would stretch these timers past the helper's 3 minute timeout.
        appNapGuard = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Backpack mode is on")
        sessionLoops = [
            every(Limits.heartbeatEvery) { await $0.heartbeatTick() },
            every(Limits.guardrailsEvery) { await $0.guardrailTick() },
        ]
        lidLoop?.cancel()
        lidLoop = every(Limits.lidEvery) { await $0.lidTick() }
    }

    private func stopSessionLoops() {
        sessionLoops.forEach { $0.cancel() }
        sessionLoops = []
        if let token = appNapGuard {
            ProcessInfo.processInfo.endActivity(token)
            appNapGuard = nil
        }
    }

    private func stopLidLoop() {
        lidLoop?.cancel()
        lidLoop = nil
    }

    private func every(_ seconds: TimeInterval, _ body: @escaping @MainActor (BackpackManager) async -> Void) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await body(self)
            }
        }
    }
}

// MARK: - Agents

/// Decides when the agents are done. Ends after 5 continuous minutes at zero,
/// but only once at least one agent was seen working, or after a 10 minute grace
/// when the session started with none (time to kick one off after closing up).
struct AgentWatch: Equatable {
    private(set) var sawAgents: Bool
    private(set) var lastCount: Int
    private(set) var zeroSince: Date?
    /// Sum of drops in the active count. A session that starts and finishes
    /// between two 15 s samples is not counted.
    private(set) var finished = 0

    init(initial: Int, at time: Date) {
        lastCount = initial
        sawAgents = initial > 0
        zeroSince = initial == 0 ? time : nil
    }

    mutating func record(_ count: Int, at time: Date) {
        if count < lastCount { finished += lastCount - count }
        lastCount = count
        if count > 0 {
            sawAgents = true
            zeroSince = nil
        } else if zeroSince == nil {
            zeroSince = time
        }
    }

    func allFinished(at time: Date, sessionStart: Date) -> Bool {
        guard let zeroSince, time.timeIntervalSince(zeroSince) >= BackpackManager.Limits.agentsIdleFor else { return false }
        return sawAgents || time.timeIntervalSince(sessionStart) >= BackpackManager.Limits.graceWithoutAgents
    }
}

// MARK: - Environment

struct BatteryReading: Equatable {
    var percent: Int
    var onAC: Bool
}

enum ScreenLockResult: Equatable {
    case locked
    case unavailable(String)
    /// Dry run: the lock was not attempted.
    case skipped
}

struct SigningCheck: Equatable {
    /// Would the helper accept this process (same check it runs on connect).
    var satisfiesHelperRequirement: Bool
    var isAdHoc: Bool
    var teamID: String?
}

@MainActor
protocol BackpackDaemonService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    func openApprovalSettings()
}

@MainActor
protocol BackpackHelperLink: AnyObject {
    func version() async throws -> (protocolVersion: Int, build: String)
    func begin(lowPower: Bool) async throws -> (ok: Bool, note: String?)
    func end() async throws -> (ok: Bool, note: String?)
    func heartbeat() async throws -> (active: Bool, note: String?)
    func status() async throws -> (sleepDisabled: Bool, active: Bool, note: String?)
    func disconnect()
}

/// Everything the manager touches outside itself. `.live()` for the app,
/// `.dryRun()` to exercise the flow with no helper, tests pass their own.
struct BackpackEnvironment {
    var now: () -> Date
    var battery: () -> BatteryReading?
    var thermalState: () -> ProcessInfo.ThermalState
    var lidClosed: () -> Bool?
    var lockScreen: () -> ScreenLockResult
    var signing: () -> SigningCheck
    var installProblem: () -> String?
    var service: BackpackDaemonService
    var helper: BackpackHelperLink
    var runsTimers: Bool

    @MainActor
    static func live() -> BackpackEnvironment {
        BackpackEnvironment(
            now: Date.init,
            battery: PowerReadings.battery,
            thermalState: { ProcessInfo.processInfo.thermalState },
            lidClosed: PowerReadings.lidClosed,
            lockScreen: ScreenLocker.lockNow,
            signing: CodeSigning.checkSelf,
            installProblem: CodeSigning.installProblem,
            service: SMAppDaemonService(),
            helper: XPCHelperLink(),
            runsTimers: true)
    }

    /// Real sensors, simulated helper and service, no screen lock. Safe on any
    /// build, including ad-hoc.
    @MainActor
    static func dryRun(helper: DryRunHelperLink? = nil, service: DryRunDaemonService? = nil) -> BackpackEnvironment {
        BackpackEnvironment(
            now: Date.init,
            battery: PowerReadings.battery,
            thermalState: { ProcessInfo.processInfo.thermalState },
            lidClosed: { PowerReadings.lidClosed() ?? false },
            lockScreen: { .skipped },
            signing: { SigningCheck(satisfiesHelperRequirement: true, isAdHoc: false, teamID: BackpackXPC.teamIdentifier) },
            installProblem: { nil },
            service: service ?? DryRunDaemonService(),
            helper: helper ?? DryRunHelperLink(),
            runsTimers: true)
    }
}

// MARK: - Live implementations

enum PowerReadings {
    /// Internal battery via IOPSCopyPowerSourcesInfo. Nil on Macs without one.
    static func battery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return BatteryReading(percent: percent, onAC: onAC)
        }
        return nil
    }

    /// IOPMrootDomain `AppleClamshellState`. Nil on Macs without a lid.
    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Bool
    }
}

enum ScreenLocker {
    static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
    private typealias LockFunction = @convention(c) () -> Int32

    /// Looks the symbol up without calling it.
    static var isAvailable: Bool { resolve() != nil }

    static func lockNow() -> ScreenLockResult {
        guard let lock = resolve() else {
            return .unavailable("SACLockScreenImmediate not found in login.framework")
        }
        _ = lock()
        return .locked
    }

    private static func resolve() -> LockFunction? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }
}

enum CodeSigning {
    static func checkSelf() -> SigningCheck {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return SigningCheck(satisfiesHelperRequirement: false, isAdHoc: true, teamID: nil)
        }
        var staticCode: SecStaticCode?
        SecCodeCopyStaticCode(code, [], &staticCode)
        let satisfies = requirement().map { SecCodeCheckValidity(code, [], $0) == errSecSuccess } ?? false
        return describe(staticCode, satisfies: satisfies)
    }

    /// Same check against a bundle on disk; used by the harness.
    static func check(bundleAt url: URL) -> SigningCheck {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return SigningCheck(satisfiesHelperRequirement: false, isAdHoc: true, teamID: nil)
        }
        let satisfies = requirement().map { SecStaticCodeCheckValidity(staticCode, [], $0) == errSecSuccess } ?? false
        return describe(staticCode, satisfies: satisfies)
    }

    /// SMAppService records the bundle's path; a translocated or disk-image copy
    /// would register a daemon that vanishes.
    static func installProblem() -> String? {
        let path = Bundle.main.bundleURL.path
        if Bundle.main.bundleURL.pathExtension != "app" { return "run Hotch from its app bundle" }
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return "move Hotch to Applications first" }
        return nil
    }

    private static func requirement() -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(BackpackXPC.appRequirement as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func describe(_ code: SecStaticCode?, satisfies: Bool) -> SigningCheck {
        var info: CFDictionary?
        if let code {
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        }
        let dictionary = info as? [String: Any] ?? [:]
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let adHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || team == nil
        return SigningCheck(satisfiesHelperRequirement: satisfies, isAdHoc: adHoc, teamID: team)
    }
}

@MainActor
final class SMAppDaemonService: BackpackDaemonService {
    private let service = SMAppService.daemon(plistName: BackpackXPC.daemonPlistName)

    /// A daemon that has never been registered reports `.notFound`, not
    /// `.notRegistered`. Only call it missing when the files really are gone, or
    /// the first registration can never happen.
    var status: SMAppService.Status {
        let status = service.status
        guard status == .notFound else { return status }
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let plist = contents.appendingPathComponent("Library/LaunchDaemons/\(BackpackXPC.daemonPlistName)")
        let helper = contents.appendingPathComponent("MacOS/HotchBackpackHelper")
        let files = FileManager.default
        return files.fileExists(atPath: plist.path) && files.isExecutableFile(atPath: helper.path)
            ? .notRegistered : .notFound
    }
    /// First call puts the helper in Login Items as "requires approval".
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum BackpackLinkError: LocalizedError {
    case noProxy
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noProxy: return "no XPC proxy"
        case .timedOut: return "the helper did not answer within 10 s"
        }
    }
}

/// Resumes a continuation once, whichever of reply, error handler or timeout
/// comes first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func succeed(_ value: T) { take()?.resume(returning: value) }
    func fail(_ error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}

@MainActor
final class XPCHelperLink: BackpackHelperLink {
    private var connection: NSXPCConnection?

    func version() async throws -> (protocolVersion: Int, build: String) {
        try await call { helper, done in helper.helperVersion { done(($0, $1)) } }
    }

    func begin(lowPower: Bool) async throws -> (ok: Bool, note: String?) {
        try await call { helper, done in helper.begin(lowPower: lowPower) { done(($0, $1)) } }
    }

    func end() async throws -> (ok: Bool, note: String?) {
        try await call { helper, done in helper.end { done(($0, $1)) } }
    }

    func heartbeat() async throws -> (active: Bool, note: String?) {
        try await call { helper, done in helper.heartbeat { done(($0, $1)) } }
    }

    func status() async throws -> (sleepDisabled: Bool, active: Bool, note: String?) {
        try await call { helper, done in helper.status { done(($0, $1, $2)) } }
    }

    /// Invalidating makes the helper see the owner go away and restore at once.
    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    private func liveConnection() -> NSXPCConnection {
        if let connection { return connection }
        // .privileged: the service lives in the system (daemon) domain.
        let c = NSXPCConnection(machServiceName: BackpackXPC.machServiceName, options: .privileged)
        c.remoteObjectInterface = BackpackXPC.makeInterface()
        // Only talk to our own helper, signed by the same team.
        c.setCodeSigningRequirement(BackpackXPC.helperRequirement)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        // Interruption (helper crashed) needs nothing here: the connection stays
        // usable, launchd relaunches the helper on the next message, and the
        // helper's launch recovery has already restored sleep by then.
        c.resume()
        connection = c
        return c
    }

    private func call<T>(_ body: (BackpackHelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        let connection = liveConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ once.fail($0) }) as? BackpackHelperProtocol else {
                once.fail(BackpackLinkError.noProxy)
                return
            }
            body(helper) { once.succeed($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { once.fail(BackpackLinkError.timedOut) }
        }
    }
}

// MARK: - Dry run

@MainActor
final class DryRunDaemonService: BackpackDaemonService {
    var status: SMAppService.Status
    /// Status after `register()`; real daemons land in `.requiresApproval`.
    var statusAfterRegister: SMAppService.Status = .requiresApproval
    private(set) var calls: [String] = []

    init(status: SMAppService.Status = .enabled) { self.status = status }

    func register() throws { calls.append("register"); status = statusAfterRegister }
    func unregister() async throws { calls.append("unregister"); status = .notRegistered }
    func openApprovalSettings() { calls.append("openApprovalSettings") }
}

/// Stands in for the helper. Tests flip its fields to simulate the helper ending
/// a session or going silent.
@MainActor
final class DryRunHelperLink: BackpackHelperLink {
    var active = false
    var lowPower = false
    var protocolVersion = BackpackXPC.protocolVersion
    var beginResult: (ok: Bool, note: String?) = (true, nil)
    /// Set to make the next heartbeat report the session as ended by the helper.
    var helperEndedReason: String?
    var heartbeatError: Error?
    private(set) var calls: [String] = []

    init() {}

    func version() async throws -> (protocolVersion: Int, build: String) {
        calls.append("version")
        return (protocolVersion, "dry-run")
    }

    func begin(lowPower: Bool) async throws -> (ok: Bool, note: String?) {
        calls.append("begin(lowPower: \(lowPower))")
        if beginResult.ok { active = true; self.lowPower = lowPower }
        return beginResult
    }

    func end() async throws -> (ok: Bool, note: String?) {
        calls.append("end")
        active = false
        return (true, nil)
    }

    func heartbeat() async throws -> (active: Bool, note: String?) {
        calls.append("heartbeat")
        if let heartbeatError { throw heartbeatError }
        if let reason = helperEndedReason { active = false; return (false, reason) }
        return (active, nil)
    }

    func status() async throws -> (sleepDisabled: Bool, active: Bool, note: String?) {
        (active, active, "dry-run")
    }

    func disconnect() {
        calls.append("disconnect")
        active = false
    }
}
