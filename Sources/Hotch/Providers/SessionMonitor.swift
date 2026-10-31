import Darwin
import Foundation

// MARK: - Model

/// One coding-agent session on this machine, live or recently finished.
///
/// This is the answer to "what is running right now" — the thing that otherwise
/// requires cycling through terminal tabs and desktop apps to find out. Claude
/// sessions come from the files Claude Code already writes, read-only. Codex
/// threads come from `codex app-server thread/list`, cached and refreshed at
/// most every 30 seconds (`CodexThreadCache`), with the rollout files as the
/// fallback. Nothing here can raise a prompt.
struct AgentSession: Sendable, Hashable, Identifiable {
    enum Activity: Int, Sendable, Comparable {
        /// The session is blocked on the person: a permission prompt, a
        /// question, an approval. Claude Code's registry says so outright
        /// (`status: waiting`, with `waitingFor`); without it, a tool call that
        /// has sat unanswered is read as one. The one state worth interrupting
        /// someone for, so it sorts first and is what the menu bar dot reports.
        case needsInput = 0
        /// The model is mid-turn (`status: busy`).
        case working = 1
        /// The session is running a shell command the person started
        /// (`status: shell`): busy, but not the model's doing.
        case shell = 2
        /// Idle: the turn ended and the ball is in the user's court.
        case waiting = 3
        /// No live process behind it any more.
        case ended = 4

        static func < (lhs: Activity, rhs: Activity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    /// Reuses the usage rows' identity map, so Claude sessions wear clay and
    /// Codex sessions wear indigo without a second brand table.
    var providerID: String
    /// The vendor's own name for the session ("hotch-33", a Codex thread name),
    /// so this panel and the vendor's UI call the same thing by the same name.
    var name: String
    /// Last path component of the working directory.
    var projectName: String
    var activity: Activity
    /// When the transcript last moved.
    var lastEventAt: Date
    var startedAt: Date?
    /// Tokens the session's next request would carry — its prompt, cached or
    /// not, plus the turn it just produced. Nil when nothing readable said.
    ///
    /// This is the other half of "how much have I got left", and the half the
    /// usage page cannot see: a plan window with 60% remaining is no help to a
    /// session two turns from a compaction. Both vendors write the figure into
    /// their own transcripts, so it costs the same read the status already does.
    var contextTokens: Int?
    /// The model's context window, as the vendor reported or as mapped from the
    /// model id. Nil whenever `contextTokens` is, since a count without a
    /// ceiling is not a reading.
    var contextLimit: Int?
    /// What a `needsInput` session is waiting for, in the vendor's words
    /// ("permission to run Bash"), when it says.
    var waitingFor: String? = nil
    /// Where the session runs: "Terminal", "Claude desktop", "VS Code",
    /// "Cowork", "Codex app".
    var surface: String? = nil
    /// Friendly model name, "Opus 5.5", "GPT-5.5", when cheaply known.
    var model: String? = nil
    /// The session's own process, for Claude Code sessions: following its
    /// parents finds the app it runs in (`SessionJump`).
    var pid: Int32? = nil
    /// The tool call in flight: what a working session is doing this second,
    /// or what a needs-input session wants approved. Nil between calls and
    /// for Codex, whose rollouts are compressed and not read here.
    var step: AgentStep? = nil
}

/// One tool call, as a session row names it.
struct AgentStep: Sendable, Hashable {
    /// The agent's own description of the call when it gave one ("Run the
    /// unit tests"), otherwise the tool and its target ("Read Package.swift").
    /// Shown as written: rewriting the agent's words into another tense would
    /// be a guess dressed up as a reading.
    var label: String
    /// The shell command itself, for a Bash call. A permission prompt is about
    /// the command rather than its description, so needs-input rows show this.
    var command: String? = nil
    /// When the call was made; the running step's timer counts from here.
    var startedAt: Date?
    /// The SF Symbol for the kind of tool: a terminal for shell commands, a
    /// pencil for edits.
    var symbol: String = "wrench.and.screwdriver"
}

// MARK: - Store

/// Publishes the current session list to both surfaces and the menu bar dot.
///
/// Scanning is a handful of directory listings and file stats, so unlike usage
/// there is no throttle and no cache file: the filesystem *is* the cache. The
/// one remote part, Codex's `thread/list`, sits behind `CodexThreadCache`,
/// which a scan reads and refreshes in the background at most every 30 s. `scanIfStale` still coalesces, because three
/// surfaces asking on their own timers should not mean three concurrent walks.
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var lastScan: Date?

    private var scanning = false
    private var lastScanStarted: Date?

    /// Sessions currently stuck on (what is probably) a permission prompt.
    var needsInputCount: Int {
        sessions.filter { $0.activity == .needsInput }.count
    }

    /// One line for the sessions page footer: "1 needs input · 2 working".
    ///
    /// At most two parts, most urgent first. Three fit only in a mock: the
    /// footer caption stops well short of the page dots, so a third clause was
    /// always going to arrive as "1 needs input · 2 working · 1…", which spends
    /// the space and delivers nothing. Waiting counts are visible in the rows
    /// above anyway; this line exists for the states you would want to know
    /// about without reading them.
    var summaryLine: String? {
        guard !sessions.isEmpty else { return nil }
        var parts: [String] = []
        let needsInput = needsInputCount
        let working = sessions.filter { $0.activity == .working }.count
        let waiting = sessions.filter { $0.activity == .waiting }.count
        if needsInput > 0 { parts.append("\(needsInput) needs input") }
        if working > 0 { parts.append("\(working) working") }
        if parts.isEmpty && waiting > 0 { parts.append("\(waiting) waiting") }
        if parts.isEmpty { parts.append("nothing live") }
        return parts.prefix(2).joined(separator: "  \u{00B7}  ")
    }

    /// Rescans unless a scan started less than `maxAge` ago or one is running.
    /// The surfaces ask on their own cadences — fast while a panel is open,
    /// slow in the background for the menu bar dot — and this is where those
    /// requests collapse into one walk at a time.
    func scanIfStale(_ maxAge: TimeInterval, now: Date = Date()) {
        if scanning { return }
        if let started = lastScanStarted, now.timeIntervalSince(started) < maxAge { return }
        scanning = true
        lastScanStarted = now
        // A plain dispatch thread, not the cooperative pool: a scan can wait
        // on a child process (Codex's thread list), and a blocked read there
        // would hold a pool thread for the whole watchdog interval.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = SessionScanner.scan(now: now)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sessions = found
                    self.lastScan = Date()
                    self.scanning = false
                }
            }
        }
    }
}

// MARK: - Scanner

/// Reads the session state the CLIs already keep on disk.
///
/// Claude Code maintains a live registry — one small JSON per running process in
/// `~/.claude/sessions/`, with the pid, session id, working directory and the
/// session's display name — plus a JSONL transcript per session under
/// `~/.claude/projects/<slug>/`. Codex keeps `~/.codex/session_index.jsonl`
/// (thread names) and dated rollout transcripts. None of it is documented, so
/// everything is parsed defensively and anything unreadable is skipped.
enum SessionScanner {
    /// Transcript movement within this window means the session is working.
    static let activeWindow: TimeInterval = 90
    /// A pending tool call older than this is probably a permission prompt
    /// rather than a long-running tool. Heuristic, and documented as one: the
    /// transcript cannot distinguish "waiting for approval" from "a build that
    /// takes two minutes", but both deserve a glance, and the desktop app's own
    /// precise state is not written anywhere this app can read.
    static let pendingToolGrace: TimeInterval = 60
    /// A mid-turn transcript that has not moved for this long belongs to a
    /// process that died mid-generation; call it waiting rather than working
    /// forever.
    static let midTurnLimit: TimeInterval = 600
    /// Finished sessions older than this are history, not status.
    static let recentCutoff: TimeInterval = 12 * 3600
    /// The panel is a glance surface; five rows is already a busy machine.
    static let maxSessions = 5
    /// How far back through a transcript tail to look for the newest usage
    /// report before giving up. The line that carries it is normally the last
    /// or second-to-last; the bound exists so a tail full of tool results can
    /// never turn a glance into a parse of a quarter megabyte of JSON.
    static let contextScanDepth = 40
    /// The retry window when the ordinary tail yields no usage block at all.
    /// Big enough to clear a few very large tool results, small enough that the
    /// exceptional path is still bounded.
    static let deepTailBytes = 4 * 1024 * 1024

    /// `refreshCodexThreads: false` keeps the scan to local files only: the
    /// Codex thread cache is read but never refreshed (`--diag`).
    static func scan(now: Date = Date(),
                     limit: Int = maxSessions,
                     refreshCodexThreads: Bool = true) -> [AgentSession] {
        var sessions = claudeSessions(now: now)
        sessions += codexSessions(now: now,
                                  excludingIDs: Set(sessions.map(\.id)),
                                  refreshThreads: refreshCodexThreads)

        // Needs-input first, then working, then waiting, then the recently
        // finished — and newest first within each. The list is capped, so the
        // sort is also the statement of what is worth keeping.
        sessions.sort {
            $0.activity == $1.activity ? $0.lastEventAt > $1.lastEventAt
                                       : $0.activity < $1.activity
        }
        return Array(sessions.prefix(limit))
    }

    // MARK: Claude

    private static var claudeRoot: URL { FS.home.appendingPathComponent(".claude") }

    private static func claudeSessions(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        let registry = claudeRoot.appendingPathComponent("sessions")
        let entries = (try? fm.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? []

        var live: [AgentSession] = []
        var liveSessionIDs: Set<String> = []

        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let dict = JSONWalk.object(data) as? [String: Any],
                  let sessionID = dict["sessionId"] as? String,
                  let pid = JSONWalk.int(dict["pid"]) else { continue }

            let cwd = dict["cwd"] as? String ?? ""
            // Hotch's own usage read is a Claude Code process too, and it
            // registers like one. It is not a session anyone started.
            if ClaudeCodeBridge.isOwnWorkDirectory(cwd) { continue }
            // The background-agent supervisor is plumbing, not a session.
            if dict["kind"] as? String == "daemon" { continue }

            // The registry outlives its processes — a crashed CLI leaves its
            // file behind — so the pid decides whether this row is live, and
            // the recorded start time decides whether that pid is still the
            // same process rather than a stranger that inherited the number.
            guard processAlive(pid),
                  processStartMatches(pid: pid, procStart: dict["procStart"] as? String) else { continue }

            let registryName = (dict["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let nameSource = dict["nameSource"] as? String
            let startedAt = JSONWalk.double(dict["startedAt"]).flatMap(DateParse.epoch)
            let statusAt = JSONWalk.double(dict["statusUpdatedAt"]).flatMap(DateParse.epoch)
            let registryStatus = registryActivity(dict["status"] as? String)
            let waitingFor = JSONWalk.string(dict["waitingFor"]).flatMap { $0.isEmpty ? nil : $0 }

            // Duplicate registry entries for one session (a restart that reused
            // the id) collapse to the newest.
            if liveSessionIDs.contains(sessionID) { continue }
            liveSessionIDs.insert(sessionID)

            let transcript = transcriptURL(sessionID: sessionID, cwd: cwd)
            let mtime = transcript.map(FS.modificationDate)
            // One tail read answers every question the row asks of the
            // transcript: its title, how full its window is, which model, and
            // (only when the registry is silent) what state it is in.
            let tail = transcript.map { LineReader.tailLines(atPath: $0.path, maxBytes: 256 * 1024) }
            let activity = registryStatus ?? transcript.map {
                claudeActivity(transcript: $0, lines: tail ?? [], now: now)
            } ?? .working
            let context = transcript.flatMap { claudeContext(transcript: $0, lines: tail ?? []) }
            let step = activity == .waiting ? nil : claudeStep(lines: tail ?? [])

            // A name the person gave (or Claude Code chose with them) is the
            // name. A derived one ("hotch-01") is the folder, so the
            // transcript's own title outranks it.
            let name: String
            if let registryName, nameSource != "derived" {
                name = registryName
            } else {
                name = claudeTitle(lines: tail ?? []) ?? registryName ?? String(sessionID.prefix(8))
            }

            live.append(AgentSession(
                id: sessionID,
                providerID: "claude",
                name: name,
                projectName: projectName(fromCwd: cwd),
                activity: activity,
                lastEventAt: [mtime, statusAt].compactMap { $0 }.max() ?? startedAt ?? now,
                startedAt: startedAt,
                contextTokens: context?.tokens,
                contextLimit: context?.limit,
                waitingFor: activity == .needsInput ? waitingFor : nil,
                surface: surfaceName(entrypoint: dict["entrypoint"] as? String),
                model: ClaudeModelCatalog.displayName(for: context?.model),
                pid: Int32(truncatingIfNeeded: pid),
                step: step
            ))
        }

        // Recently finished sessions: transcripts that moved within the cutoff
        // but have no live process behind them. Their display name comes from
        // the transcript's own slug (the registry entry is gone by now).
        let recent = recentClaudeTranscripts(excluding: liveSessionIDs, now: now)
        return live + recent
    }

    /// Claude Code's registry status, which is the session's own word on what
    /// it is doing. Nil for a value this build does not know, which sends the
    /// row back to the transcript heuristics.
    static func registryActivity(_ status: String?) -> AgentSession.Activity? {
        switch status {
        case "busy": return .working
        case "shell": return .shell
        case "waiting": return .needsInput
        case "idle": return .waiting
        default: return nil
        }
    }

    /// The registry's `entrypoint`, as the place the person would look for
    /// the session.
    static func surfaceName(entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return "Claude desktop"
        case "claude-vscode": return "VS Code"
        case "local-agent": return "Cowork"
        case nil, "", "cli", "terminal": return "Terminal"
        case let other?:
            if other.hasPrefix("sdk") { return "Agent SDK" }
            if other.contains("jetbrains") { return "JetBrains" }
            return Fmt.humanize(key: other)
        }
    }

    /// Claude Code records each session's process start as `procStart`, in
    /// `ps -o lstart` form in UTC ("Tue Oct 20 11:48:57 2026"). A live pid
    /// whose actual start differs is a recycled pid: the session is gone.
    /// Anything that cannot be read either way is given the benefit of the
    /// doubt, since `kill(pid, 0)` has already said something is there.
    static func processStartMatches(pid: Int, procStart: String?) -> Bool {
        guard let procStart, let recorded = parseProcStart(procStart),
              let actual = processStartTime(pid: pid) else { return true }
        return abs(actual.timeIntervalSince(recorded)) <= 2
    }

    private static let procStartFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()
    private static let procStartLock = NSLock()

    static func parseProcStart(_ text: String) -> Date? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        procStartLock.lock()
        defer { procStartLock.unlock() }
        return procStartFormatter.date(from: collapsed)
    }

    static func processStartTime(pid: Int) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Claude Code names each transcript directory after the working directory
    /// with every non-alphanumeric character flattened to "-". Derived first and
    /// verified on disk; when the guess misses (the scheme is not documented) the
    /// session id is searched for across all project directories instead.
    private static func transcriptURL(sessionID: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let projects = claudeRoot.appendingPathComponent("projects")

        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let derived = projects.appendingPathComponent(slug)
            .appendingPathComponent("\(sessionID).jsonl")
        if fm.fileExists(atPath: derived.path) { return derived }

        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Status from the tail of the transcript. The last event plus the file's
    /// age say more than either alone:
    ///
    /// - an assistant turn that ended (`end_turn`) means the ball is with the
    ///   user, however fresh the file is;
    /// - a tool call with no result behind it means the session is blocked on
    ///   the tool — a permission prompt, once it has sat longer than a tool
    ///   plausibly runs;
    /// - anything else mid-turn means the model is generating, which writes
    ///   nothing to the file while it happens, so recency alone would misread
    ///   "thinking" as "stalled".
    ///
    /// Takes the tail rather than reading it, because the context gauge needs
    /// the same bytes and one file should not be read twice per scan.
    private static func claudeActivity(transcript: URL,
                                       lines: [Data],
                                       now: Date) -> AgentSession.Activity {
        let age = now.timeIntervalSince(FS.modificationDate(transcript))

        var lastType: String?
        var stopReason: String?
        // Transcript lines can be enormous; the tail read is capped and the
        // parse walks backwards to the newest line that decodes.
        //
        // **Only a turn counts as the newest event.** The transcript is not
        // purely a conversation: Claude Code also appends its own bookkeeping —
        // `ai-title`, `custom-title`, `last-prompt`, `mode`, `queue-operation`,
        // `attachment`, compaction boundaries — and it writes several of those
        // *after* an assistant turn ends. So the genuinely newest line at the
        // moment a session goes idle is a title update, not the `end_turn` that
        // preceded it, and the fall-through below read that as "the model owes
        // the next event" and reported **working** for a session sitting
        // untouched. Ten minutes of a finished session claiming to be busy,
        // which is the one thing this page exists to get right.
        //
        // An allowlist rather than a list of things to skip: the bookkeeping
        // types are undocumented and four of them turned up in a single tail, so
        // a denylist is a promise to keep discovering new ones in production.
        for line in lines.reversed() {
            guard let dict = JSONWalk.object(line) as? [String: Any],
                  let type = dict["type"] as? String else { continue }
            guard type == "assistant" || type == "user" else { continue }
            lastType = type
            if let message = dict["message"] as? [String: Any] {
                stopReason = message["stop_reason"] as? String
            }
            break
        }

        switch lastType {
        case "assistant" where stopReason == "end_turn":
            return .waiting
        case "assistant" where stopReason == "tool_use" || stopReason == nil:
            return age < pendingToolGrace ? .working : .needsInput
        case "assistant":
            return .waiting
        case nil:
            // Nothing decoded (a giant line swallowed the whole tail); age is
            // all there is.
            return age < activeWindow ? .working : .waiting
        default:
            // A user message or tool result is newest: the model owes the next
            // event, and it writes nothing while generating.
            return age < midTurnLimit ? .working : .waiting
        }
    }

    /// How many tail lines the step search walks back through before giving up.
    static let stepScanDepth = 60

    /// The tool call the session is in the middle of, from the same tail.
    ///
    /// The newest tool call no result has answered yet: the step running now,
    /// or, for a session on a permission prompt, the step it wants approved.
    /// Claude Code writes each content block as its own line, so parallel
    /// calls arrive as consecutive assistant lines and the walk continues past
    /// answered ones to an older call that is still open. It stops at the
    /// person's own prompt, since nothing before it can still be running.
    ///
    /// Nil between calls, while the model writes and there is no step to name.
    /// The row then keeps its ordinary subtitle instead of pinning the last
    /// finished call on as if it were still going, timer and all.
    static func claudeStep(lines: [Data]) -> AgentStep? {
        var answered: Set<String> = []
        var examined = 0
        for line in lines.reversed() {
            examined += 1
            if examined > stepScanDepth { break }
            guard let dict = JSONWalk.object(line) as? [String: Any],
                  let type = dict["type"] as? String,
                  type == "assistant" || type == "user",
                  dict["isSidechain"] as? Bool != true,
                  let message = dict["message"] as? [String: Any] else { continue }
            let blocks = (message["content"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }

            if type == "user" {
                // Claude Code's own injected context is not the person speaking.
                if dict["isMeta"] as? Bool == true { continue }
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                if results.isEmpty { return nil }
                for result in results {
                    if let id = result["tool_use_id"] as? String { answered.insert(id) }
                }
                continue
            }
            for call in blocks.reversed() where call["type"] as? String == "tool_use" {
                guard let id = call["id"] as? String, !answered.contains(id) else { continue }
                return step(for: call, at: DateParse.date(from: dict["timestamp"]))
            }
        }
        return nil
    }

    /// Names one `tool_use` block the way the row shows it.
    static func step(for call: [String: Any], at date: Date?) -> AgentStep? {
        guard let name = call["name"] as? String else { return nil }
        let input = call["input"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String? { JSONWalk.string(input[key]).flatMap(stepText) }
        func file(_ key: String) -> String? { text(key).map { ($0 as NSString).lastPathComponent } }
        func labelled(_ label: String?, _ symbol: String) -> AgentStep? {
            label.map { AgentStep(label: $0, startedAt: date, symbol: symbol) }
        }

        switch name {
        case "Bash":
            let command = text("command")
            guard let label = text("description") ?? command else { return nil }
            return AgentStep(label: label, command: command, startedAt: date, symbol: "terminal")
        case "Read": return labelled(file("file_path").map { "Read \($0)" }, "doc.text")
        case "Edit", "MultiEdit": return labelled(file("file_path").map { "Edit \($0)" }, "pencil")
        case "Write": return labelled(file("file_path").map { "Write \($0)" }, "pencil")
        case "NotebookEdit": return labelled(file("notebook_path").map { "Edit \($0)" }, "pencil")
        case "Grep": return labelled(text("pattern").map { "Search for \u{201C}\($0)\u{201D}" }, "magnifyingglass")
        case "Glob": return labelled(text("pattern").map { "Find \($0)" }, "magnifyingglass")
        case "WebFetch":
            return labelled(text("url").map { "Fetch \(URL(string: $0)?.host ?? $0)" }, "globe")
        case "WebSearch": return labelled(text("query").map { "Search the web for \u{201C}\($0)\u{201D}" }, "globe")
        case "Task", "Agent": return labelled(text("description") ?? "Run an agent", "person.2")
        default:
            // MCP tools arrive as mcp__<server>__<tool>.
            let parts = name.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                let tool = Fmt.humanize(key: parts[2...].joined(separator: "_"))
                return labelled("\(tool) \u{00B7} \(Fmt.humanize(key: parts[1]))", "puzzlepiece.extension")
            }
            return labelled(Fmt.humanize(key: name), "wrench.and.screwdriver")
        }
    }

    /// One line, trimmed and capped: rows truncate, but a pasted heredoc should
    /// not travel through the store as forty lines.
    private static func stepText(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "\u{2026}" : collapsed
    }

    /// The vendor's own title for the session — the name the user sees in
    /// Claude Code and cowork, and therefore the only name this row should ever
    /// carry.
    ///
    /// Claude Code writes `{"type":"ai-title","aiTitle":…}` lines into the
    /// transcript and **rewrites them as the session goes on** — between three
    /// and forty of them in a working session — so the newest wins and the walk
    /// runs backwards. Every transcript checked had one, and had one inside the
    /// same 256KB tail already being read for status and context, so the real
    /// title costs no extra file access at all.
    ///
    /// This outranks every other source. The live registry's `name` is a
    /// *derived* label ("hotch-01", "ul-engineering-b6") and the transcript's
    /// `slug` is a generated triple ("crispy-scribbling-lark"); both are names
    /// the machine made up for its own bookkeeping, and neither is what the
    /// person watching the session calls it.
    static func claudeTitle(lines: [Data]) -> String? {
        let gate = Bytes.pattern("-title")
        var examined = 0
        var aiTitle: String?

        // A title the person set (`custom-title`, from /rename) outranks the
        // generated one wherever it sits in the tail; the newest of each wins.
        for line in lines.reversed() {
            guard examined < contextScanDepth else { break }
            guard Bytes.contains(line, gate) else { continue }
            examined += 1
            guard let dict = JSONWalk.object(line) as? [String: Any],
                  let type = dict["type"] as? String else { continue }
            if type == "custom-title", let title = dict["customTitle"] as? String {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } else if type == "ai-title", aiTitle == nil, let title = dict["aiTitle"] as? String {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { aiTitle = trimmed }
            }
        }
        return aiTitle
    }

    /// What the person opened the session by asking for, as a short title.
    ///
    /// The last resort for naming a finished session used to be the first eight
    /// characters of its UUID, which produced rows reading `c231a6a4` — a
    /// string that appears in none of the user's own tools and identifies
    /// nothing they can recognise. Claude Code only writes a `slug` for some
    /// sessions, and the human-readable title the desktop app shows lives in
    /// its Electron database rather than anywhere on this side of the fence.
    ///
    /// The first thing typed is the honest local answer: it is what the session
    /// was *for*, it is the same sentence the vendor's own summary is generated
    /// from, and it is already on disk. Read from the head of the file rather
    /// than the tail, bounded, stopping at the first real user turn.
    static func openingLine(of transcript: URL) -> String? {
        var title: String?
        LineReader.forEachLineData(atPath: transcript.path, maxBytes: 256 * 1024) { data in
            guard let dict = JSONWalk.object(data) as? [String: Any],
                  dict["type"] as? String == "user",
                  dict["isSidechain"] as? Bool != true,
                  let message = dict["message"] as? [String: Any] else { return true }

            // Content is either a bare string or the block array; a turn whose
            // blocks are tool results is the transcript talking to itself.
            var text: String?
            if let string = message["content"] as? String {
                text = string
            } else if let blocks = message["content"] as? [Any] {
                for case let block as [String: Any] in blocks
                where block["type"] as? String == "text" {
                    text = block["text"] as? String
                    break
                }
            }
            guard let cleaned = cleanTitle(text) else { return true }
            title = cleaned
            return false
        }
        return title
    }

    /// Trims an opening prompt down to something that fits a 12pt row.
    ///
    /// Rejects the turns that are not a person speaking — slash commands, the
    /// harness's own injected blocks — because naming a session `<command-name>`
    /// would be a worse answer than the UUID it replaced.
    static func cleanTitle(_ text: String?) -> String? {
        guard var line = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else { return nil }
        guard !line.hasPrefix("<"), !line.hasPrefix("/"), !line.hasPrefix("[Request interrupted")
        else { return nil }

        // First sentence-ish worth of the first non-empty line.
        line = line.split(whereSeparator: \.isNewline).first.map(String.init) ?? line
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*`-> "))
        line = line.split(separator: " ").joined(separator: " ")
        guard !line.isEmpty else { return nil }

        let limit = 46
        guard line.count > limit else { return line }
        // Cut on a word boundary so the ellipsis lands after a whole word.
        let clipped = line.prefix(limit)
        let stem = clipped.lastIndex(of: " ").map { String(clipped[clipped.startIndex..<$0]) }
            ?? String(clipped)
        return stem + "\u{2026}"
    }

    /// Context occupancy, with one retry against a much larger tail.
    ///
    /// The bounded tail is normally generous — a usage block sits on the last
    /// or second-to-last line. But a single tool result can be hundreds of
    /// kilobytes on its own (a build log, a big file read), and one of those at
    /// the end of a transcript fills the whole window: `tailLines` drops the
    /// leading partial line, so what comes back can be a handful of fragments
    /// with no assistant turn among them. The row then showed a dim ring for a
    /// live session that plainly had a reading, which is how this was found.
    ///
    /// So the cheap read stays the common path and the expensive one is the
    /// exception, taken only when the cheap one found nothing.
    private static func claudeContext(transcript: URL, lines: [Data]) -> (tokens: Int, limit: Int, model: String?)? {
        if let found = claudeContext(lines: lines) { return found }
        let deeper = LineReader.tailLines(atPath: transcript.path, maxBytes: deepTailBytes)
        guard deeper.count > lines.count else { return nil }
        return claudeContext(lines: deeper)
    }

    /// Context occupancy from the newest assistant message in the tail.
    ///
    /// Claude Code writes an API usage block on every assistant line, and the
    /// four input-ish counts plus the output are exactly what the next request
    /// will carry: fresh prompt tokens, whatever was written to cache, whatever
    /// was read from cache, and the turn just generated. Cached tokens are the
    /// bulk of a long session and count in full — the cache makes them cheap,
    /// not absent, and leaving them out would report a session at 78k as being
    /// at 2k.
    ///
    /// Sub-agent lines are skipped. They land in the same transcript with their
    /// own much smaller windows, so the newest assistant line during a Task run
    /// belongs to the sub-agent and would read as the main session suddenly
    /// emptying out.
    private static func claudeContext(lines: [Data]) -> (tokens: Int, limit: Int, model: String?)? {
        // Gated on a field name, not on `"usage"`. A tool result is arbitrary
        // captured text, and on a transcript that has been reading this app's
        // own source the word "usage" appears in dozens of them — enough
        // false positives to burn the whole scan budget before reaching a real
        // assistant line, which is what made live sessions draw the dim ring.
        let usageGate = Bytes.pattern("\"output_tokens\"")
        var examined = 0

        for line in lines.reversed() {
            guard examined < contextScanDepth else { break }
            // Tool results are the giant lines; rejecting them on bytes costs a
            // scan instead of a JSON parse.
            guard Bytes.contains(line, usageGate) else { continue }
            examined += 1

            guard let dict = JSONWalk.object(line) as? [String: Any],
                  dict["type"] as? String == "assistant",
                  (dict["isSidechain"] as? Bool) != true,
                  let message = dict["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let tokens = ["input_tokens",
                          "cache_creation_input_tokens",
                          "cache_read_input_tokens",
                          "output_tokens"]
                .compactMap { JSONWalk.int(usage[$0]) }
                .reduce(0, +)
            guard tokens > 0 else { continue }
            let model = message["model"] as? String
            guard let limit = claudeContextLimit(model: model, observed: tokens) else { continue }
            return (tokens, limit, model)
        }
        return nil
    }

    /// The window sizes a Claude model is ever configured with. Used as a
    /// ladder rather than a set: an id this app has never heard of climbs it
    /// until it finds a rung the session actually fits inside.
    static let claudeContextTiers = [200_000, 500_000, 1_000_000, 2_000_000]

    /// The context window for a Claude session — the one figure in this feature
    /// that is inferred rather than read.
    ///
    /// **Codex writes `model_context_window` into its own rollout; Claude Code
    /// writes nothing equivalent.** Not in the transcript, not in
    /// `stats-cache.json` (whose `contextWindow` field is present and always
    /// zero), not in any settings file. So the ceiling has to come from the
    /// model id, and the id is a name, not a number.
    ///
    /// Two rules, in this order:
    ///
    /// 0. Claude Code's model catalog cache (`ClaudeModelCatalog`), which lists
    ///    `max_input_tokens` per model id. Used whenever the id is listed.
    /// 1. A table, because the models in use are known: the Claude 5 family and
    ///    Opus 4.6 and later meter a megatoken; everything before them meters
    ///    200k. Claude Code also marks a long-context session in the id itself
    ///    ("...[1m]"), which is honoured wherever it appears.
    /// 2. **The reading may never contradict the data.** If a session already
    ///    holds more tokens than the table allows, the table is wrong about that
    ///    model, so the limit climbs to the smallest tier the session fits in.
    ///    Without this an unrecognised future model pins every row at a
    ///    confident, permanent 100% — which is the worst possible failure for a
    ///    gauge, because it looks exactly like a real emergency. A session past
    ///    the top of the ladder returns nil and draws the dim ring instead: at
    ///    that point the app genuinely does not know, and says so.
    ///
    /// The residual risk is the opposite direction — a model whose table entry
    /// is too small reads as fuller than it is until it passes the rung. That is
    /// the safer error for a headroom gauge, and it is why the tiers are coarse.
    static func claudeContextLimit(model: String?, observed: Int) -> Int? {
        let id = (model ?? "").lowercased()

        // Claude Code's own catalog first: the server's figure for this exact
        // model. A "[1m]" id is the long-context variant of a listed model.
        if let listed = ClaudeModelCatalog.model(for: model)?.maxInputTokens, listed > 0 {
            let limit = id.contains("[1m]") ? max(listed, 1_000_000) : listed
            guard observed > limit else { return limit }
            return claudeContextTiers.first { $0 >= observed }
        }

        // Version is read from the id's own segments rather than by substring.
        // "claude-opus-4-5-20251101" contains "-5" without being a Claude 5,
        // and matching that way is how a 200k model gets a megatoken window.
        let parts = id.split(separator: "-").map(String.init)
        let numbers = parts.compactMap(Int.init)
        let major = numbers.first ?? 0
        // A dated id ends in an eight-digit stamp; only a real point release is
        // small enough to be a minor version.
        let minor = numbers.dropFirst().first(where: { $0 < 100 }) ?? 0

        let long = id.contains("[1m]") || id.hasSuffix("-1m")
            || major >= 5 || (major == 4 && minor >= 6)
        let limit = long ? 1_000_000 : 200_000

        guard observed > limit else { return limit }
        return claudeContextTiers.first { $0 >= observed }
    }

    private static func recentClaudeTranscripts(excluding liveIDs: Set<String>,
                                                now: Date) -> [AgentSession] {
        let fm = FileManager.default
        let projects = claudeRoot.appendingPathComponent("projects")
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else {
            return []
        }

        var out: [AgentSession] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let sessionID = file.deletingPathExtension().lastPathComponent
                guard !liveIDs.contains(sessionID) else { continue }
                let mtime = FS.modificationDate(file)
                guard now.timeIntervalSince(mtime) < recentCutoff else { continue }

                // Transcript lines carry the session's slug and real working
                // directory. Walked backwards to the newest line that decodes —
                // the very last line is often a tool result too large for the
                // bounded tail read, and one undecodable line must not cost the
                // row its name. The directory name is the flattened-cwd slug,
                // so its last dash-token is the best guess left when nothing
                // decodes at all.
                var name: String?
                var project = dir.lastPathComponent.split(separator: "-").last.map(String.init)
                    ?? dir.lastPathComponent
                let tail = LineReader.tailLines(atPath: file.path, maxBytes: 128 * 1024)
                var foundCwd = false
                for line in tail.reversed() {
                    guard let dict = JSONWalk.object(line) as? [String: Any] else { continue }
                    // Any line carrying the real working directory beats the
                    // flattened folder name, slug or not ("UL Engineering",
                    // not "Engineering").
                    if !foundCwd, let cwd = dict["cwd"] as? String, !cwd.isEmpty {
                        project = projectName(fromCwd: cwd)
                        foundCwd = true
                    }
                    guard let slug = dict["slug"] as? String, !slug.isEmpty else { continue }
                    name = slug
                    break
                }
                // A finished session keeps its last reading: how full the window
                // got is the interesting part of a session that has stopped.
                let context = claudeContext(transcript: file, lines: tail)

                out.append(AgentSession(
                    id: sessionID,
                    providerID: "claude",
                    name: claudeTitle(lines: tail)
                        ?? name
                        ?? openingLine(of: file)
                        ?? String(sessionID.prefix(8)),
                    projectName: project,
                    activity: .ended,
                    lastEventAt: mtime,
                    startedAt: nil,
                    contextTokens: context?.tokens,
                    contextLimit: context?.limit,
                    model: ClaudeModelCatalog.displayName(for: context?.model)
                ))
            }
        }
        // Only the freshest few can ever be shown; trimming here keeps the
        // merge in `scan` from sorting a day's worth of dead transcripts.
        return Array(out.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(maxSessions))
    }

    // MARK: Codex

    private static var codexRoot: URL { FS.home.appendingPathComponent(".codex") }

    /// Codex threads, from `thread/list` when the app-server has answered
    /// within the last 30 seconds' cache, plus the rollout files for anything
    /// it did not list.
    private static func codexSessions(now: Date,
                                      excludingIDs: Set<String>,
                                      refreshThreads: Bool) -> [AgentSession] {
        var seen = excludingIDs
        var out: [AgentSession] = []

        let cached = CodexThreadCache.shared.current(now: now, refresh: refreshThreads)
        if cached.fetchedAt != nil {
            for session in codexThreadSessions(cached.threads, now: now) where !seen.contains(session.id) {
                seen.insert(session.id)
                out.append(session)
            }
        }
        out += codexRolloutSessions(now: now, excludingIDs: seen)
        return out
    }

    /// Threads updated within this long that are not loaded anywhere still
    /// read as idle rather than ended: a Codex app thread is "notLoaded" to a
    /// fresh app-server even while its window is open.
    static let codexIdleWindow: TimeInterval = 2 * 3600

    /// `thread/list` rows as sessions. Sub-agent threads are folded into their
    /// parent; anything older than the recency cutoff and not running is history.
    static func codexThreadSessions(_ threads: [CodexThread], now: Date) -> [AgentSession] {
        threads.compactMap { thread -> AgentSession? in
            guard thread.parentThreadID == nil else { return nil }
            let age = now.timeIntervalSince(thread.updatedAt)
            let activity: AgentSession.Activity
            var waitingFor: String?
            switch thread.status {
            case .active(let flags):
                if flags.contains("waitingOnApproval") {
                    activity = .needsInput
                    waitingFor = "approval"
                } else if flags.contains("waitingOnUserInput") {
                    activity = .needsInput
                    waitingFor = "your input"
                } else {
                    activity = .working
                }
            case .idle:
                activity = .waiting
            case .notLoaded, .systemError, .unknown:
                activity = age < codexIdleWindow ? .waiting : .ended
            }
            if activity == .ended && age >= recentCutoff { return nil }

            var context: (tokens: Int, limit: Int)?
            if let path = thread.path, path.hasSuffix(".jsonl") {
                context = codexContext(rollout: URL(fileURLWithPath: path))
            }
            return AgentSession(
                id: thread.id,
                providerID: "codex",
                name: thread.name ?? cleanTitle(thread.preview) ?? "Codex thread",
                projectName: codexProjectName(cwd: thread.cwd),
                activity: activity,
                lastEventAt: thread.updatedAt,
                startedAt: thread.createdAt,
                contextTokens: context?.tokens,
                contextLimit: context?.limit,
                waitingFor: waitingFor,
                surface: thread.surface,
                model: thread.modelName
            )
        }
    }

    /// A ChatGPT project thread runs in a generated folder under
    /// `~/.codex/.chatgpt-projects/`, whose name means nothing to anyone.
    static func codexProjectName(cwd: String) -> String {
        if cwd.contains("/.codex/.chatgpt-projects/") { return "ChatGPT project" }
        return projectName(fromCwd: cwd)
    }

    /// Codex has no live registry, so without the app-server liveness is read
    /// from the rollout files themselves: one per session under
    /// `sessions/YYYY/MM/DD/`, named with the session's UUID, appended as the
    /// session runs. Current CLIs compress them (`.jsonl.zst`), which leaves
    /// the name and the mtime readable and the contents not. Only today's and
    /// yesterday's directories are walked.
    private static func codexRolloutSessions(now: Date, excludingIDs: Set<String>) -> [AgentSession] {
        let names = codexThreadNames()
        let fm = FileManager.default
        var out: [AgentSession] = []

        for dayOffset in 0...1 {
            guard let day = Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let dir = codexRoot.appendingPathComponent("sessions")
                .appendingPathComponent(String(format: "%04d", y))
                .appendingPathComponent(String(format: "%02d", m))
                .appendingPathComponent(String(format: "%02d", d))

            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let filename = file.lastPathComponent
                let compressed = filename.hasSuffix(".jsonl.zst")
                guard compressed || filename.hasSuffix(".jsonl") else { continue }
                let base = String(filename.dropLast(compressed ? 10 : 6))
                // "rollout-2026-08-08T05-32-51-<uuid>": the id is the fixed-width
                // tail, which survives whatever happens to the prefix format.
                guard base.count > 36 else { continue }
                let id = String(base.suffix(36))
                guard !excludingIDs.contains(id) else { continue }

                let mtime = FS.modificationDate(file)
                guard now.timeIntervalSince(mtime) < recentCutoff else { continue }

                let context = compressed ? nil : codexContext(rollout: file)

                out.append(AgentSession(
                    id: id,
                    providerID: "codex",
                    name: names[id] ?? "Codex session",
                    projectName: compressed ? "" : codexProjectName(rollout: file),
                    activity: now.timeIntervalSince(mtime) < activeWindow ? .working : .ended,
                    lastEventAt: mtime,
                    startedAt: nil,
                    contextTokens: context?.tokens,
                    contextLimit: context?.limit
                ))
            }
        }
        return out
    }

    /// id → thread name, from the tail of the session index. The index is
    /// append-only, so the tail holds the newest entries and a bounded read is
    /// enough for anything recent.
    private static func codexThreadNames() -> [String: String] {
        let index = codexRoot.appendingPathComponent("session_index.jsonl")
        var names: [String: String] = [:]
        for line in LineReader.tailLines(atPath: index.path, maxBytes: 128 * 1024) {
            guard let dict = JSONWalk.object(line) as? [String: Any],
                  let id = dict["id"] as? String,
                  let name = dict["thread_name"] as? String, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }

    /// Context occupancy from the newest `token_count` event in the rollout.
    ///
    /// Codex is the easier of the two: it writes both halves of the reading
    /// itself — the running turn's token usage and `model_context_window` — so
    /// nothing has to be mapped from a model id. Reasoning tokens are
    /// subtracted because they are billed and then dropped; they never come
    /// back as input, and counting them would show a reasoning-heavy session as
    /// fuller than it is.
    ///
    /// The event carries rate limits too, which Hotch reads from the Codex
    /// provider instead — this is the one field that page cannot supply.
    private static func codexContext(rollout: URL) -> (tokens: Int, limit: Int)? {
        let gate = Bytes.pattern("token_count")
        var examined = 0

        for line in LineReader.tailLines(atPath: rollout.path, maxBytes: 256 * 1024).reversed() {
            guard examined < contextScanDepth else { break }
            guard Bytes.contains(line, gate) else { continue }
            examined += 1

            // Shape unverified against any spec, so the two figures are located
            // by search rather than by a path expression, same as `cwd` below.
            guard let root = JSONWalk.object(line),
                  let info = JSONWalk.findDictionary(containing: "model_context_window", in: root),
                  let limit = JSONWalk.int(info["model_context_window"]), limit > 0,
                  let last = info["last_token_usage"] as? [String: Any],
                  let total = JSONWalk.int(last["total_tokens"]) else { continue }

            let reasoning = JSONWalk.int(last["reasoning_output_tokens"]) ?? 0
            let tokens = max(0, total - reasoning)
            guard tokens > 0 else { continue }
            return (tokens, limit)
        }
        return nil
    }

    /// The rollout's first line is session metadata carrying the working
    /// directory. Shape unverified against any spec, hence the recursive search
    /// rather than a path expression.
    private static func codexProjectName(rollout: URL) -> String {
        var first: Data?
        LineReader.forEachLineData(atPath: rollout.path, maxBytes: 64 * 1024) { data in
            first = data
            return false
        }
        guard let first,
              let root = JSONWalk.object(first),
              let dict = JSONWalk.findDictionary(containing: "cwd", in: root),
              let cwd = dict["cwd"] as? String else { return "" }
        return projectName(fromCwd: cwd)
    }

    // MARK: Shared

    private static func processAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// The project a session is working on, which is not always the directory
    /// it is running in.
    ///
    /// Cowork runs a session inside a throwaway git worktree under the project
    /// itself — `…/UL FIFA 2026/.claude/worktrees/upbeat-lichterman-cb3204` —
    /// and the last component of that path is a name the machine generated,
    /// which appears nowhere in the user's own UI and means nothing to the
    /// person who started the session. The project above it is the thing they
    /// recognise, so the worktree segment is stripped and the real folder wins.
    static func projectName(fromCwd cwd: String) -> String {
        var path = cwd
        if let worktrees = path.range(of: "/.claude/worktrees/") {
            path = String(path[path.startIndex..<worktrees.lowerBound])
        }
        // A string operation, not `URL(fileURLWithPath:)`, which stats the
        // folder to learn whether it is one.
        let name = (path as NSString).lastPathComponent
        return name == "/" ? "" : name
    }
}
