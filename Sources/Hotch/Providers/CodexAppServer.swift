import Foundation

/// Reads Codex rate limits and threads by asking the Codex CLI, over the
/// JSON-RPC protocol its own desktop app uses.
///
/// This exists because the obvious approach does not work. `chatgpt.com` is
/// behind Cloudflare bot management, so calling the usage endpoint directly with
/// the CLI's token answers `403 cf-mitigated: challenge` no matter what headers
/// are sent. Hotch asks the client OpenAI already trusts instead, and lets it
/// make the call:
///
/// ```
/// codex app-server            # stdio JSON-RPC, no daemon required
/// -> initialize
/// -> initialized              # notification, no id
/// -> account/rateLimits/read  # params MUST be null, not {}
/// <- { rateLimits: { primary: { usedPercent, windowDurationMins, resetsAt }, planType, credits },
///      rateLimitResetCredits: { availableCount } }
/// -> thread/list {"limit":10,"sortKey":"updated_at"}
/// <- { data: [ { id, name, preview, cwd, status: {type, activeFlags}, updatedAt, model, source, ... } ] }
/// ```
///
/// It spends nothing: this is account metering and local thread metadata, not
/// inference. The protocol is marked experimental by OpenAI, so everything here
/// is defensive: an unknown shape, a missing binary or a hung process yields
/// `unavailable` and the caller keeps what it had.
enum CodexAppServer {
    /// The CLI the ChatGPT desktop app ships inside its own bundle. Preferred:
    /// it is the build OpenAI keeps current with the app, so it speaks the
    /// newest protocol, and it is there on any Mac with ChatGPT installed even
    /// when no CLI ever was. The `CodexCLI.app` executable is tried before the
    /// `bin/codex` shell launcher so the watchdog's terminate reaches the real
    /// process.
    static var bundledPaths: [(path: String, source: String)] {
        var out: [(String, String)] = []
        for root in ["/Applications", FS.home.appendingPathComponent("Applications").path] {
            for app in ["ChatGPT", "Codex"] {
                let base = "\(root)/\(app).app/Contents/Resources/codex-cli"
                let executable = "\(base)/CodexCLI.app/Contents/MacOS/codex"
                // The launcher only execs the executable beside it; list it
                // only for a bundle laid out without one.
                if FileManager.default.isExecutableFile(atPath: executable) {
                    out.append((executable, "\(app) app"))
                } else {
                    out.append(("\(base)/bin/codex", "\(app) app"))
                }
            }
            out.append(("\(root)/Codex.app/Contents/Resources/codex", "Codex app"))
        }
        return out
    }

    /// Where a Homebrew, npm, or manual install puts the binary. Probed
    /// explicitly because an LSUIElement app launched by the window server
    /// inherits almost no PATH.
    static let searchPaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/opt/homebrew/opt/codex/bin/codex",
        "/run/current-system/sw/bin/codex"
    ]

    /// Every installed codex binary, in the order they are preferred.
    static func installs() -> [(url: URL, source: String)] {
        let fm = FileManager.default
        var candidates = bundledPaths
        candidates += searchPaths.map { ($0, "Homebrew or system") }
        for (relative, source) in [(".local/bin/codex", "~/.local/bin"),
                                   (".codex/bin/codex", "~/.codex/bin"),
                                   (".bun/bin/codex", "bun"),
                                   (".volta/bin/codex", "Volta"),
                                   (".npm-global/bin/codex", "npm")] {
            candidates.append((FS.home.appendingPathComponent(relative).path, source))
        }
        var seen = Set<String>()
        var out: [(URL, String)] = []
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            let url = URL(fileURLWithPath: candidate.path)
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { continue }
            out.append((url, candidate.source))
        }
        return out
    }

    static func binaryURL() -> URL? { installs().first?.url }

    static var isAvailable: Bool { binaryURL() != nil }

    // MARK: - Session

    /// One running app-server, handshake done, ready for requests.
    final class Session {
        fileprivate let input: Pipe
        fileprivate let reader: JSONLineStream
        private var nextID = 2

        fileprivate init(input: Pipe, reader: JSONLineStream) {
            self.input = input
            self.reader = reader
        }

        /// Sends one request and waits for its reply, skipping notifications.
        /// Nil on an error reply, a closed pipe or the watchdog firing.
        func request(_ method: String, params: Any) -> [String: Any]? {
            let id = nextID
            nextID += 1
            guard ChildProcess.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params],
                                    to: input) else { return nil }
            guard let response = reader.waitForResponse(id: id) else {
                hotchLog.debug("codex app-server did not answer \(method)")
                return nil
            }
            return response["result"] as? [String: Any]
        }
    }

    /// Starts `codex app-server`, performs the handshake, runs `body`, and
    /// always ends the child. Synchronous and blocking by design: call it from
    /// a detached task. The watchdog bounds the whole exchange.
    static func withSession<T>(timeout: TimeInterval = 12, _ body: (Session) -> T) -> T? {
        guard let binary = binaryURL() else { return nil }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        process.environment = ChildProcess.environment(binary: binary,
                                                       directory: process.currentDirectoryURL)

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = StderrCollector(pipe: errors)

        do {
            try process.run()
        } catch {
            hotchLog.debug("codex app-server could not start: \(error.localizedDescription)")
            return nil
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

        guard ChildProcess.send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "hotch",
                                      "title": "Hotch",
                                      "version": HotchAbout.version]]
        ], to: input) else { return nil }

        let reader = JSONLineStream(handle: output.fileHandleForReading)
        // Wait for the handshake rather than sleeping a fixed interval: a
        // request that arrives first is ignored outright.
        guard reader.waitForResponse(id: 1) != nil else {
            hotchLog.debug("codex app-server did not answer initialize")
            return nil
        }
        // The protocol's own completion of the handshake. Older servers
        // tolerated its absence; newer ones may hold requests until it lands.
        ChildProcess.send(["jsonrpc": "2.0", "method": "initialized"], to: input)

        return body(Session(input: input, reader: reader))
    }

    // MARK: - Rate limits

    /// What one rate-limit read established.
    ///
    /// `noLimits` is split out from `unavailable` on purpose. A ChatGPT account
    /// without Codex in its plan answers perfectly well and reports no windows,
    /// which is a fact about the subscription, not a failure, and not something
    /// the user can fix by installing or signing into anything.
    enum Outcome {
        case limits(windows: [UsageWindow], plan: String?, extras: [String])
        case noLimits(plan: String?, extras: [String])
        /// Could not start, could not handshake, or answered an error.
        case unavailable
    }

    static func fetchRateLimits(timeout: TimeInterval = 12) -> Outcome {
        withSession(timeout: timeout) { session -> Outcome in
            // `params` is typed as null in the protocol schema. Sending `{}` is
            // silently dropped with no error and no response.
            guard let result = session.request("account/rateLimits/read", params: NSNull()) else {
                return .unavailable
            }
            return parse(result: result)
        } ?? .unavailable
    }

    /// Both reads in one child, for `--diag-full`.
    static func fetchAll(threadLimit: Int = 10, timeout: TimeInterval = 15)
        -> (limits: Outcome, threads: [CodexThread]?, rawLimitIDs: [String]) {
        withSession(timeout: timeout) { session in
            let limitsResult = session.request("account/rateLimits/read", params: NSNull())
            let threadsResult = session.request("thread/list", params: threadListParams(limit: threadLimit))
            let ids = (limitsResult?["rateLimitsByLimitId"] as? [String: Any]).map { $0.keys.sorted() } ?? []
            return (limitsResult.map(parse(result:)) ?? .unavailable,
                    threadsResult.map(parseThreads(result:)),
                    ids)
        } ?? (.unavailable, nil, [])
    }

    /// `rateLimits` is the backward-compatible single-bucket view and mirrors
    /// the historical payload, so it is the one to trust. `rateLimitsByLimitId`
    /// breaks out per-model buckets, which are not what the panel reports.
    static func parse(result: [String: Any]) -> Outcome {
        // An absent `rateLimits` key means the shape changed under us; an empty
        // one means the account has no windows. Only the first is our problem.
        guard let snapshot = result["rateLimits"] as? [String: Any] else { return .unavailable }

        let plan = PlanName.display(JSONWalk.string(snapshot["planType"]))
            ?? PlanName.display(JSONWalk.string(result["planType"]))

        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let bucket = snapshot[key] as? [String: Any],
                  let used = JSONWalk.double(bucket["usedPercent"]) else { continue }
            windows.append(window(usedPercent: used,
                                  minutes: JSONWalk.int(bucket["windowDurationMins"]),
                                  resetsAt: DateParse.date(from: bucket["resetsAt"]),
                                  fallbackKind: key == "primary" ? .session : .week))
        }

        var extras: [String] = []
        if let resets = result["rateLimitResetCredits"] as? [String: Any],
           let count = JSONWalk.int(resets["availableCount"]), count > 0 {
            extras.append(count == 1 ? "1 reset credit" : "\(count) reset credits")
        }
        if let credits = snapshot["credits"] as? [String: Any], let line = creditsLine(credits) {
            extras.append(line)
        }

        guard !windows.isEmpty else { return .noLimits(plan: plan, extras: extras) }
        return .limits(windows: WindowRank.sorted(windows), plan: plan, extras: extras)
    }

    /// The window length decides what a bucket is, not its position: a lone
    /// `primary` bucket can be the weekly limit (it is, on Pro lite), and
    /// labelling it "Session" would be wrong.
    static func window(usedPercent: Double,
                       minutes: Int?,
                       resetsAt: Date?,
                       fallbackKind: WindowKind) -> UsageWindow {
        let kind: WindowKind
        if let minutes, minutes > 0 {
            kind = WindowKind.infer(windowMinutes: minutes, label: "")
        } else {
            kind = fallbackKind
        }
        let label: String
        switch kind {
        case .session: label = "Session"
        case .week, .weekScoped: label = "Week"
        case .day: label = "Day"
        case .other: label = minutes.map { Fmt.windowLabel(minutes: $0) } ?? "Limit"
        }
        return UsageWindow(label: label,
                           usedPercent: min(100, max(0, usedPercent)),
                           resetsAt: resetsAt,
                           windowMinutes: minutes,
                           kind: kind == .weekScoped ? .week : kind)
    }

    /// Prepaid Codex credits, only when there is something to say: an
    /// unlimited grant, or a positive balance.
    static func creditsLine(_ credits: [String: Any]) -> String? {
        if credits["unlimited"] as? Bool == true { return "Unlimited credits" }
        guard credits["hasCredits"] as? Bool == true,
              let balance = JSONWalk.double(credits["balance"]), balance > 0 else { return nil }
        let rounded = (balance * 100).rounded() / 100
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2f", rounded)
        return "\(text) credits"
    }

    // MARK: - Threads

    static func threadListParams(limit: Int) -> [String: Any] {
        ["limit": limit, "sortKey": "updated_at"]
    }

    /// The newest threads, or nil when the server could not be asked.
    static func fetchThreads(limit: Int = 10, timeout: TimeInterval = 12) -> [CodexThread]? {
        withSession(timeout: timeout) { session -> [CodexThread]? in
            session.request("thread/list", params: threadListParams(limit: limit)).map(parseThreads(result:))
        } ?? nil
    }

    static func parseThreads(result: [String: Any]) -> [CodexThread] {
        (result["data"] as? [[String: Any]] ?? []).compactMap(CodexThread.init(json:))
    }
}

/// One Codex thread as `thread/list` describes it.
struct CodexThread: Sendable, Hashable {
    enum Status: Sendable, Hashable {
        case notLoaded
        case idle
        case systemError
        /// Running. `flags` carries `waitingOnApproval` / `waitingOnUserInput`.
        case active(flags: [String])
        case unknown(String)

        var description: String {
            switch self {
            case .notLoaded: return "notLoaded"
            case .idle: return "idle"
            case .systemError: return "systemError"
            case .active(let flags): return flags.isEmpty ? "active" : "active[\(flags.joined(separator: ","))]"
            case .unknown(let raw): return raw
            }
        }
    }

    var id: String
    var name: String?
    var preview: String
    var cwd: String
    var status: Status
    var createdAt: Date?
    var updatedAt: Date
    var model: String?
    /// `cli`, `vscode`, `exec`, `appServer`, or a custom / sub-agent source.
    var source: String?
    var originator: String?
    var parentThreadID: String?
    var path: String?

    init?(json: [String: Any]) {
        guard let id = JSONWalk.string(json["id"]), !id.isEmpty else { return nil }
        self.id = id
        name = JSONWalk.string(json["name"]).flatMap { $0.isEmpty ? nil : $0 }
        preview = JSONWalk.string(json["preview"]) ?? ""
        cwd = JSONWalk.string(json["cwd"]) ?? ""
        let statusDict = json["status"] as? [String: Any]
        switch JSONWalk.string(statusDict?["type"]) ?? "" {
        case "notLoaded": status = .notLoaded
        case "idle": status = .idle
        case "systemError": status = .systemError
        case "active":
            status = .active(flags: (statusDict?["activeFlags"] as? [Any] ?? []).compactMap { $0 as? String })
        case let other: status = .unknown(other)
        }
        createdAt = DateParse.date(from: json["createdAt"])
        updatedAt = DateParse.date(from: json["updatedAt"]) ?? createdAt ?? .distantPast
        model = JSONWalk.string(json["model"])
        if let plain = json["source"] as? String {
            source = plain
        } else if let dict = json["source"] as? [String: Any] {
            source = dict.keys.sorted().first
        }
        originator = JSONWalk.string(json["originator"])
        parentThreadID = JSONWalk.string(json["parentThreadId"])
        path = JSONWalk.string(json["path"])
    }

    /// Where the thread was started, in the words the user would use.
    var surface: String? {
        let origin = (originator ?? "").lowercased()
        if origin.contains("desktop") { return "Codex app" }
        if origin.contains("vscode") || origin.contains("ide") { return "VS Code" }
        switch source {
        case "cli": return "Terminal"
        case "vscode": return origin.isEmpty ? "VS Code" : "Codex app"
        case "exec": return "codex exec"
        case "appServer": return "App server"
        default: return nil
        }
    }

    /// "gpt-5.5" reads as "GPT-5.5".
    var modelName: String? {
        guard let model, !model.isEmpty else { return nil }
        if model.lowercased().hasPrefix("gpt-") { return "GPT-" + model.dropFirst(4) }
        return model
    }
}
