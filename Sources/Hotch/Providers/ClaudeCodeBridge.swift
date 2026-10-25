import Foundation

/// Asks Claude Code for the plan usage, instead of signing in to Claude itself.
///
/// Anthropic's terms do not allow a third-party app to offer Claude.ai sign-in
/// or to hold its tokens, so Hotch no longer has a Claude credential of any kind.
/// Claude Code already has one, and its SDK mode answers a `get_usage` control
/// request with exactly what its own `/usage` screen shows:
///
/// ```
/// claude -p --input-format stream-json --output-format stream-json --verbose
/// -> {"type":"control_request","request_id":"r1","request":{"subtype":"initialize"}}
/// -> {"type":"control_request","request_id":"r2","request":{"subtype":"get_usage","skip_behaviors":true}}
/// <- {"type":"control_response","response":{"subtype":"success","request_id":"r2","response":{...}}}
/// ```
///
/// No prompt is sent and no model runs: this is account metering, the same read
/// the CLI makes for its own screen. It answers in about 0.3 s. The child is
/// started with `--safe-mode` (no hooks, MCP servers, plugins or CLAUDE.md) and
/// `--no-session-persistence` (no transcript), in a scratch directory of
/// Hotch's own, so asking for usage cannot run anything the user configured
/// and leaves no session behind.
///
/// Hotch never reads, copies or writes Claude Code's credential. Signing in is
/// Claude Code's own `claude auth login`, run as a child process, and signing
/// out is not something Hotch does at all.
enum ClaudeCodeBridge {
    // MARK: - Locating Claude Code

    /// One Claude Code binary on this Mac.
    struct Install: Sendable, Hashable {
        /// What gets executed.
        var url: URL
        /// Symlinks resolved, for display and de-duplication.
        var resolved: URL
        var version: String?
        /// Where it came from, in words: "Claude desktop", "native installer".
        var source: String
    }

    /// Every place Claude Code is installed, newest version first.
    ///
    /// Absolute paths, because an `LSUIElement` app launched by the window
    /// server inherits almost no PATH. The Claude desktop app keeps its own
    /// managed copies under Application Support, one directory per version; the
    /// native installer links `~/.local/bin/claude` into a versioned file; npm,
    /// bun and Volta put a launcher in their own bin directories.
    static func installs() -> [Install] {
        let fm = FileManager.default
        let home = FS.home
        var candidates: [(path: String, source: String)] = []

        // Desktop-managed: .../claude-code/<version>/<hash>/claude.app/Contents/MacOS/claude
        let managed = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: managed.path)) ?? [])
            .filter { SemVer.find(in: $0) == $0 }
            .sorted { SemVer.isNewer($0, than: $1) }
        for version in versions {
            let dir = managed.appendingPathComponent(version)
            let hashes = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            for hash in hashes {
                let binary = dir.appendingPathComponent(hash)
                    .appendingPathComponent("claude.app/Contents/MacOS/claude")
                candidates.append((binary.path, "Claude desktop"))
            }
        }

        candidates.append((home.appendingPathComponent(".local/bin/claude").path, "native installer"))
        candidates.append((home.appendingPathComponent(".claude/local/claude").path, "local install"))
        candidates.append(("/opt/homebrew/bin/claude", "Homebrew"))
        candidates.append(("/usr/local/bin/claude", "/usr/local"))
        candidates.append((home.appendingPathComponent(".npm-global/bin/claude").path, "npm"))
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        for node in ((try? fm.contentsOfDirectory(atPath: nvm.path)) ?? []).sorted(by: { SemVer.isNewer($0, than: $1) }) {
            candidates.append((nvm.appendingPathComponent(node).appendingPathComponent("bin/claude").path, "npm (nvm \(node))"))
        }
        candidates.append((home.appendingPathComponent(".bun/bin/claude").path, "bun"))
        candidates.append((home.appendingPathComponent(".volta/bin/claude").path, "Volta"))

        var seen = Set<String>()
        var found: [Install] = []
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            let url = URL(fileURLWithPath: candidate.path)
            let resolved = url.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { continue }
            found.append(Install(url: url,
                                 resolved: resolved,
                                 version: version(of: url, resolved: resolved),
                                 source: candidate.source))
        }

        // Newest version first; candidate order breaks ties, so the desktop's
        // own copy wins over an identical version elsewhere. Unknown versions
        // go last rather than being guessed at.
        return found.enumerated().sorted { lhs, rhs in
            switch (lhs.element.version, rhs.element.version) {
            case let (a?, b?):
                if a == b { return lhs.offset < rhs.offset }
                return SemVer.isNewer(a, than: b)
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static let locateLock = NSLock()
    nonisolated(unsafe) private static var located: (install: Install?, at: Date)?

    /// The newest Claude Code, cached briefly. A handful of stats, so the
    /// settings window can ask on every redraw.
    static func locate(maxAge: TimeInterval = 30, now: Date = Date()) -> Install? {
        locateLock.lock()
        if let located, now.timeIntervalSince(located.at) < maxAge {
            locateLock.unlock()
            return located.install
        }
        locateLock.unlock()
        let newest = installs().first
        locateLock.lock()
        located = (newest, now)
        locateLock.unlock()
        return newest
    }

    static var isInstalled: Bool { locate() != nil }

    /// Anthropic's native installer, for the "not found" row.
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    // MARK: Versions

    private static let versionLock = NSLock()
    nonisolated(unsafe) private static var versionCache: [String: (mtime: Date, version: String?)] = [:]

    /// The version an install reports, read from its path where the installer
    /// put it there, from npm's package.json next to the script, and only as
    /// a last resort by running `--version` (cached against the file's mtime,
    /// so it runs once per binary, not once per poll).
    static func version(of url: URL, resolved: URL) -> String? {
        // ".../claude-code/2.1.299/<hash>/claude.app/..." and
        // "~/.local/share/claude/versions/2.1.205" both carry it.
        for component in resolved.pathComponents.reversed() where SemVer.find(in: component) == component {
            return component
        }
        // npm: ".../node_modules/@anthropic-ai/claude-code/cli.js"
        let package = resolved.deletingLastPathComponent().appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: package),
           let root = JSONWalk.object(data) as? [String: Any],
           root["name"] as? String == "@anthropic-ai/claude-code",
           let version = JSONWalk.string(root["version"]) {
            return version
        }

        let mtime = FS.modificationDate(resolved)
        versionLock.lock()
        if let cached = versionCache[resolved.path], cached.mtime == mtime {
            versionLock.unlock()
            return cached.version
        }
        versionLock.unlock()

        let output = runCaptured(url, arguments: ["--version"], timeout: 5)
        let version = output.flatMap { SemVer.find(in: $0.stdout) }
        versionLock.lock()
        versionCache[resolved.path] = (mtime, version)
        versionLock.unlock()
        return version
    }

    // MARK: - Working directory

    /// The child runs here, never in a project: a scratch folder of Hotch's own,
    /// so no project settings or CLAUDE.md can apply, and so the session scanner
    /// can recognise (and hide) the registry entry Claude Code writes for it.
    static let workDirectoryName = "hotch-claude-code"

    static func workDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(workDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether a working directory is Hotch's own scratch folder. Decided from
    /// the string alone: `URL(fileURLWithPath:)` would stat every session's
    /// project folder on every scan.
    static func isOwnWorkDirectory(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == workDirectoryName
    }

    // MARK: - Sign-in state

    /// What Claude Code is signed in with, as far as Hotch can tell without
    /// ever looking at the credential itself.
    enum SignIn: Equatable, Sendable {
        case unknown
        /// A Claude subscription. `plan` is in display form ("Max").
        case signedIn(plan: String?)
        case signedOut
        /// An API key or a long-lived token without the profile scope: Claude
        /// Code works, but there are no plan windows to read.
        case noPlan(reason: String)
    }

    private static let signInLock = NSLock()
    nonisolated(unsafe) private static var signInState: (value: SignIn, at: Date)?
    nonisolated(unsafe) private static var signInRefreshing = false

    /// The last known sign-in state, refreshed by `claude auth status` (about
    /// 0.1 s) when older than `maxAge`. Blocks only when nothing has ever been
    /// learned and `blockingIfUnknown` is set, which is the first launch; every
    /// other caller gets the cached answer and a background refresh.
    static func signIn(maxAge: TimeInterval = 60, blockingIfUnknown: Bool = false) -> SignIn {
        guard locate() != nil else { return .signedOut }
        signInLock.lock()
        let current = signInState
        let stale = current.map { Date().timeIntervalSince($0.at) > maxAge } ?? true
        let shouldRefresh = stale && !signInRefreshing
        if shouldRefresh { signInRefreshing = true }
        signInLock.unlock()

        guard shouldRefresh else { return current?.value ?? .unknown }
        if current == nil && blockingIfUnknown {
            let fresh = readAuthStatus()
            store(fresh)
            return fresh
        }
        DispatchQueue.global(qos: .utility).async {
            store(readAuthStatus())
        }
        return current?.value ?? .unknown
    }

    /// The cached answer only, never starting anything. For offline callers
    /// (`--snapshot`, `--diag`).
    static var cachedSignIn: SignIn {
        signInLock.lock()
        defer { signInLock.unlock() }
        return signInState?.value ?? .unknown
    }

    /// Forgets the cached state, for right after a sign-in.
    static func invalidateSignIn() {
        signInLock.lock()
        signInState = nil
        signInLock.unlock()
        locateLock.lock()
        located = nil
        locateLock.unlock()
    }

    static func note(_ value: SignIn) {
        store(value)
    }

    private static func store(_ value: SignIn) {
        signInLock.lock()
        // An inconclusive read never overwrites a definite answer.
        if value != .unknown || signInState == nil {
            signInState = (value, Date())
        }
        signInRefreshing = false
        signInLock.unlock()
    }

    /// `claude auth status --json`: `{"loggedIn": bool, "authMethod": ...}`.
    /// Read for the two flags only; nothing in it is a secret, and Claude Code
    /// reads its own credential to answer.
    static func readAuthStatus() -> SignIn {
        guard let install = locate(),
              let output = runCaptured(install.url, arguments: ["auth", "status", "--json"], timeout: 5),
              let start = output.stdout.firstIndex(of: "{"),
              let root = JSONWalk.object(String(output.stdout[start...])) as? [String: Any],
              let loggedIn = root["loggedIn"] as? Bool else { return .unknown }
        guard loggedIn else { return .signedOut }
        let method = (JSONWalk.string(root["authMethod"]) ?? "").lowercased()
        if let provider = JSONWalk.string(root["apiProvider"]), provider != "firstParty" {
            return .noPlan(reason: "Claude Code uses \(providerName(provider))")
        }
        if method.contains("api") && method.contains("key") {
            return .noPlan(reason: "Claude Code uses an API key")
        }
        return .signedIn(plan: PlanName.display(JSONWalk.string(root["subscriptionType"])))
    }

    static func providerName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "bedrock": return "Amazon Bedrock"
        case "vertex": return "Google Vertex"
        case "foundry": return "Microsoft Foundry"
        case "gateway": return "a gateway"
        default: return raw
        }
    }

    // MARK: - get_usage

    /// What one `get_usage` exchange established.
    struct UsageReply: Sendable {
        var cliVersion: String?
        /// From the initialize reply's `account`: "none" when not signed in.
        var tokenSource: String?
        var apiProvider: String?
        var apiKeySource: String?
        var accountSubscription: String?
        /// get_usage `subscription_type`: "pro", "max", "team", "enterprise".
        var subscriptionType: String?
        var rateLimitsAvailable: Bool
        /// `rate_limits` was an object rather than null.
        var hasRateLimits: Bool
        var windows: [UsageWindow]
        var extras: [String]
        /// Diagnostics: which keys `rate_limits` carried, and how many
        /// `limits[]` rows (nil when the array was absent).
        var rateLimitKeys: [String]
        var limitRows: Int?
        var elapsed: TimeInterval

        /// The plan in display form, from whichever half said.
        var plan: String? {
            PlanName.display(subscriptionType) ?? PlanName.display(accountSubscription)
        }

        var signIn: SignIn {
            if let apiProvider, apiProvider != "firstParty" {
                return .noPlan(reason: "Claude Code uses \(ClaudeCodeBridge.providerName(apiProvider))")
            }
            if tokenSource == "none" { return .signedOut }
            if subscriptionType != nil || rateLimitsAvailable || accountSubscription != nil {
                if !rateLimitsAvailable {
                    return .noPlan(reason: "Claude Code's sign-in cannot read plan usage")
                }
                return .signedIn(plan: plan)
            }
            if apiKeySource != nil || tokenSource != nil {
                return .noPlan(reason: "Claude Code uses an API key")
            }
            return .signedOut
        }
    }

    enum FetchOutcome: Sendable {
        case reply(UsageReply)
        case notInstalled
        case failed(String)
    }

    /// The flags that keep the child inert. Older builds that do not know one
    /// of them refuse to start, so the exchange is retried once without.
    static let quietFlags = ["--safe-mode", "--no-session-persistence"]

    /// One initialize + get_usage exchange. Blocking: call it from a detached
    /// task. A watchdog terminates the child, which is also what unblocks a
    /// pending read.
    static func fetchUsage(install: Install? = nil, timeout: TimeInterval = 12) -> FetchOutcome {
        guard let install = install ?? locate() else { return .notInstalled }
        switch exchange(install: install, extraFlags: quietFlags, timeout: timeout) {
        case .rejectedFlags:
            hotchLog.log("claude code \(install.version ?? "?") rejected the quiet flags, retrying without")
            if case .done(let outcome) = exchange(install: install, extraFlags: [], timeout: timeout) {
                return outcome
            }
            return .failed("Claude Code did not answer")
        case .done(let outcome):
            return outcome
        }
    }

    private enum Exchange {
        case done(FetchOutcome)
        case rejectedFlags
    }

    private static func exchange(install: Install,
                                 extraFlags: [String],
                                 timeout: TimeInterval) -> Exchange {
        let started = Date()
        let process = Process()
        process.executableURL = install.url
        process.arguments = ["-p"] + extraFlags + ["--input-format", "stream-json",
                                                    "--output-format", "stream-json",
                                                    "--verbose"]
        process.currentDirectoryURL = workDirectory()
        var environment = ChildProcess.environment(binary: install.url,
                                                     directory: process.currentDirectoryURL)
        // A usage read has no business updating anything.
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let stderr = StderrCollector(pipe: errors)

        do {
            try process.run()
        } catch {
            return .done(.failed("could not start Claude Code: \(error.localizedDescription)"))
        }

        let watchdog = DispatchWorkItem {
            ChildProcess.stop(process)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            ChildProcess.stop(process)
        }

        ChildProcess.send(["type": "control_request", "request_id": "r1",
                           "request": ["subtype": "initialize"]], to: input)
        ChildProcess.send(["type": "control_request", "request_id": "r2",
                           "request": ["subtype": "get_usage", "skip_behaviors": true]], to: input)

        let reader = JSONLineStream(handle: output.fileHandleForReading)
        var account: [String: Any] = [:]
        var cliVersion: String? = install.version
        var usage: [String: Any]?
        var sawAnything = false

        while let object = reader.nextObject() {
            sawAnything = true
            guard object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any] else { continue }
            let requestID = response["request_id"] as? String
            if response["subtype"] as? String == "error" {
                let message = JSONWalk.string(response["error"]) ?? "error"
                if requestID == "r2" { return .done(.failed("get_usage refused: \(message)")) }
                continue
            }
            let body = response["response"] as? [String: Any] ?? [:]
            if requestID == "r1" {
                account = body["account"] as? [String: Any] ?? [:]
                cliVersion = JSONWalk.string(body["claude_code_version"]) ?? cliVersion
            } else if requestID == "r2" {
                usage = body
                break
            }
        }

        guard let usage else {
            let tail = stderr.text
            if !sawAnything && tail.lowercased().contains("unknown option") && !extraFlags.isEmpty {
                return .rejectedFlags
            }
            let reason = process.isRunning ? "timed out" : "exited"
            let detail = tail.split(separator: "\n").last.map(String.init) ?? ""
            return .done(.failed("Claude Code \(reason) without answering get_usage"
                                 + (detail.isEmpty ? "" : " (\(detail.prefix(160)))")))
        }

        let rateLimits = usage["rate_limits"] as? [String: Any]
        let parsed: (windows: [UsageWindow], extras: [String], limitRows: Int?) =
            rateLimits.map(parse(rateLimits:)) ?? ([], [], nil)
        return .done(.reply(UsageReply(
            cliVersion: cliVersion,
            tokenSource: JSONWalk.string(account["tokenSource"]),
            apiProvider: JSONWalk.string(account["apiProvider"]),
            apiKeySource: JSONWalk.string(account["apiKeySource"]),
            accountSubscription: JSONWalk.string(account["subscriptionType"]),
            subscriptionType: JSONWalk.string(usage["subscription_type"]),
            rateLimitsAvailable: usage["rate_limits_available"] as? Bool ?? false,
            hasRateLimits: rateLimits != nil,
            windows: parsed.windows,
            extras: parsed.extras,
            rateLimitKeys: rateLimits.map { $0.keys.sorted() } ?? [],
            limitRows: parsed.limitRows,
            elapsed: Date().timeIntervalSince(started)
        )))
    }

    // MARK: - Parsing rate_limits

    /// Turns `get_usage.rate_limits` into windows and extras.
    ///
    /// The shape, read out of Claude Code 2.1.299's own schema: the plain
    /// windows `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`
    /// (each `{utilization, resets_at}`), `model_scoped[]` (`{display_name,
    /// utilization, resets_at}`), `extra_usage`, and — passed through from the
    /// usage endpoint when the read was live — the server's own `limits[]`
    /// rows, `{kind, group, percent, resets_at, severity, is_active, scope}`.
    ///
    /// `limits[]` wins when it is there: it is the server saying which meters
    /// apply, and each row is classified on its `kind` (`session`,
    /// `weekly_all`, `weekly_scoped`), never on a key name — the endpoint has
    /// shipped internal codenames as keys before. The plain windows are the
    /// fallback for a reply without rows (an older CLI, or one answering from
    /// a cached reading).
    static func parse(rateLimits: [String: Any]) -> (windows: [UsageWindow], extras: [String], limitRows: Int?) {
        var windows: [UsageWindow] = []
        var labels = Set<String>()
        func add(_ window: UsageWindow) {
            guard labels.insert(window.label).inserted else { return }
            windows.append(window)
        }

        let rows = rateLimits["limits"] as? [[String: Any]]
        for row in rows ?? [] {
            guard let percent = JSONWalk.double(row["percent"]) else { continue }
            let kind = (JSONWalk.string(row["kind"]) ?? "").lowercased()
            let group = (JSONWalk.string(row["group"]) ?? "").lowercased()
            let scopeDict = row["scope"] as? [String: Any]
            let scopeName = JSONWalk.string((scopeDict?["model"] as? [String: Any])?["display_name"])
                ?? JSONWalk.string((scopeDict?["surface"] as? [String: Any])?["display_name"])
            let resets = DateParse.date(from: row["resets_at"])

            let windowKind: WindowKind
            switch kind {
            case "session": windowKind = .session
            case "weekly_all": windowKind = .week
            case "weekly_scoped": windowKind = .weekScoped
            default:
                // A meter this build has never seen. Its group still says what
                // family it belongs to; without one it is logged and left out
                // rather than shown as a row nobody can interpret.
                if group == "session" {
                    windowKind = .session
                } else if group == "weekly" {
                    windowKind = scopeName == nil ? .week : .weekScoped
                } else {
                    hotchLog.log("claude usage: ignoring limits row of kind '\(kind)' group '\(group)'")
                    continue
                }
            }
            add(window(kind: windowKind, scope: scopeName, percent: percent, resets: resets))
        }

        if windows.isEmpty {
            func bucket(_ key: String) -> (Double, Date?)? {
                guard let dict = rateLimits[key] as? [String: Any],
                      let utilization = JSONWalk.double(dict["utilization"]) else { return nil }
                return (utilization, DateParse.date(from: dict["resets_at"]))
            }
            if let (used, resets) = bucket("five_hour") {
                add(window(kind: .session, scope: nil, percent: used, resets: resets))
            }
            if let (used, resets) = bucket("seven_day") {
                add(window(kind: .week, scope: nil, percent: used, resets: resets))
            }
            let scoped = rateLimits["model_scoped"] as? [[String: Any]]
            for row in scoped ?? [] {
                guard let name = JSONWalk.string(row["display_name"]),
                      let used = JSONWalk.double(row["utilization"]) else { continue }
                add(window(kind: .weekScoped, scope: name, percent: used,
                           resets: DateParse.date(from: row["resets_at"])))
            }
            // Legacy per-model weeks, only when the scoped list is absent:
            // when it is present it is the server's current word on them.
            if scoped == nil {
                for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                    if let (used, resets) = bucket(key) {
                        add(window(kind: .weekScoped, scope: name, percent: used, resets: resets))
                    }
                }
            }
        }

        var extras: [String] = []
        if let extra = rateLimits["extra_usage"] as? [String: Any], let line = extraUsageLine(extra) {
            extras.append(line)
        }
        return (WindowRank.sorted(windows), extras, rows?.count)
    }

    private static func window(kind: WindowKind, scope: String?, percent: Double, resets: Date?) -> UsageWindow {
        let label: String
        let minutes: Int
        switch kind {
        case .session:
            label = "Session"; minutes = 300
        case .week:
            label = "Week"; minutes = 7 * 1440
        case .weekScoped:
            label = "\(scope ?? "Scoped") week"; minutes = 7 * 1440
        case .day:
            label = "Day"; minutes = 1440
        case .other:
            label = scope ?? "Other"; minutes = 0
        }
        return UsageWindow(label: label,
                           usedPercent: min(100, max(0, percent)),
                           resetsAt: resets,
                           windowMinutes: minutes > 0 ? minutes : nil,
                           kind: kind,
                           scope: kind == .weekScoped ? scope : nil)
    }

    /// "Extra usage $12.40 of $50". Amounts arrive in minor units (cents for
    /// USD). Shown only when extra usage is switched on or has been spent.
    static func extraUsageLine(_ extra: [String: Any]) -> String? {
        let enabled = extra["is_enabled"] as? Bool ?? false
        let used = (JSONWalk.double(extra["used_credits"]) ?? 0) / 100
        let limit = JSONWalk.double(extra["monthly_limit"]).map { $0 / 100 }
        guard enabled || used > 0 else { return nil }
        let currency = (JSONWalk.string(extra["currency"]) ?? "USD").uppercased()
        var line = "Extra usage \(Fmt.money(used, currency: currency))"
        if let limit, limit > 0 { line += " of \(Fmt.money(limit, currency: currency))" }
        if !enabled { line += " (off)" }
        return line
    }

    // MARK: - Small subprocess runs

    /// Runs a short command and captures its output, with a watchdog.
    static func runCaptured(_ binary: URL,
                            arguments: [String],
                            timeout: TimeInterval) -> (stdout: String, status: Int32)? {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory()
        var environment = ChildProcess.environment(binary: binary,
                                                     directory: process.currentDirectoryURL)
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        _ = StderrCollector(pipe: errors)
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { ChildProcess.stop(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    // MARK: - Retiring Hotch's own old credential

    /// Hotch's own file from when it ran its own Claude sign-in. Expired, and
    /// not something Hotch may hold any more, so the new version deletes it.
    static let legacyCredentialName = "claude-oauth"

    private static let retireLock = NSLock()
    nonisolated(unsafe) private static var retired = false

    static var legacyCredentialPresent: Bool { CredentialStore.exists(legacyCredentialName) }

    /// Deletes `~/Library/Application Support/Hotch/claude-oauth.json`, once per
    /// launch. Only ever Hotch's own file; nothing of Claude Code's is touched.
    static func retireLegacyCredential() {
        retireLock.lock()
        defer { retireLock.unlock() }
        guard !retired else { return }
        retired = true
        // A support folder still under an old app name may carry one too.
        CredentialStore.migrateFromLegacyDirectoryIfNeeded()
        guard CredentialStore.exists(legacyCredentialName) else { return }
        CredentialStore.delete(legacyCredentialName)
        hotchLog.log("deleted Hotch's own retired Claude sign-in file")
    }
}

// MARK: - Signing in, through Claude Code

/// Runs `claude auth login --claudeai`: Claude Code's own sign-in, which opens
/// the browser and stores Claude Code's own credential. Hotch only starts it,
/// waits for it, and reads nothing it produces beyond the exit status and the
/// fallback link it prints.
enum ClaudeCodeLogin {
    enum Failure: Error, Equatable {
        case notInstalled
        case timedOut
        case cancelled
        case failed(String)

        /// The row's words for it.
        var message: String {
            switch self {
            case .notInstalled: return "Claude Code not found. Install it first."
            case .timedOut: return "Sign-in timed out. Try again."
            case .cancelled: return "Sign-in cancelled."
            case .failed(let detail): return detail.isEmpty ? "Sign-in did not finish." : detail
            }
        }
    }

    static let arguments = ["auth", "login", "--claudeai"]
    static let timeout: TimeInterval = 300

    /// For the settings window. Cancelling the calling task stops the child.
    /// `onLink` receives the "If the browser didn't open, visit:" link when
    /// Claude Code prints one.
    static func run(timeout: TimeInterval = ClaudeCodeLogin.timeout,
                    onLink: (@Sendable (URL) -> Void)? = nil) async -> Result<Void, Failure> {
        guard let install = ClaudeCodeBridge.locate(maxAge: 0) else { return .failure(.notInstalled) }

        let process = Process()
        process.executableURL = install.url
        process.arguments = arguments
        process.currentDirectoryURL = ClaudeCodeBridge.workDirectory()
        process.environment = ChildProcess.environment(binary: install.url,
                                                       directory: process.currentDirectoryURL)
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let state = LoginState(input: input)

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: chunk, as: UTF8.self)
            state.append(text)
            if let link = ClaudeCodeLogin.link(in: text) { onLink?(link) }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, Failure>, Never>) in
                state.continuation = continuation
                process.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    if state.cancelled { state.finish(.failure(.cancelled)); return }
                    if state.timedOut { state.finish(.failure(.timedOut)); return }
                    if status == 0 { state.finish(.success(())); return }
                    state.finish(.failure(.failed(state.lastLine)))
                }
                // Cancelled before it started: never start it.
                if state.cancelled || Task.isCancelled {
                    state.finish(.failure(.cancelled))
                    return
                }
                do {
                    try process.run()
                } catch {
                    state.finish(.failure(.failed("Could not start Claude Code: \(error.localizedDescription)")))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    state.timedOut = true
                    ChildProcess.stop(process)
                }
            }
        } onCancel: {
            state.cancelled = true
            ChildProcess.stop(process)
        }
    }

    /// For `Hotch --connect-claude`: the child gets the terminal itself, so
    /// whatever Claude Code asks (a pasted code, a choice) the person answers
    /// directly. Blocks until it exits or the timeout passes.
    static func runInTerminal(install: ClaudeCodeBridge.Install,
                              timeout: TimeInterval = ClaudeCodeLogin.timeout) -> Result<Void, Failure> {
        let process = Process()
        process.executableURL = install.url
        process.arguments = arguments
        process.environment = ChildProcess.environment(binary: install.url,
                                                       directory: process.currentDirectoryURL)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do { try process.run() } catch {
            return .failure(.failed("could not start Claude Code: \(error.localizedDescription)"))
        }
        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            if process.isRunning { timedOut.set(); ChildProcess.stop(process) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut.isSet { return .failure(.timedOut) }
        return process.terminationStatus == 0
            ? .success(())
            : .failure(.failed("claude auth login exited with status \(process.terminationStatus)"))
    }

    static func link(in text: String) -> URL? {
        guard let range = text.range(of: #"https://\S+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}

/// Mutable state shared between a login child's handlers and its waiter.
private final class LoginState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var done = false
    /// Held so the child's stdin stays open while it waits for the browser:
    /// closing it early reads as end-of-input to a prompt for a pasted code.
    private let input: Pipe
    var continuation: CheckedContinuation<Result<Void, ClaudeCodeLogin.Failure>, Never>?
    var cancelled = false
    var timedOut = false

    init(input: Pipe) { self.input = input }

    func append(_ text: String) {
        lock.lock()
        output += text
        if output.count > 16_000 { output = String(output.suffix(8_000)) }
        lock.unlock()
    }

    var lastLine: String {
        lock.lock()
        defer { lock.unlock() }
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("https://") }
        return lines.last.map { String($0.prefix(160)) } ?? ""
    }

    func finish(_ result: Result<Void, ClaudeCodeLogin.Failure>) {
        lock.lock()
        guard !done, let continuation else { lock.unlock(); return }
        done = true
        self.continuation = nil
        lock.unlock()
        try? input.fileHandleForWriting.close()
        continuation.resume(returning: result)
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
