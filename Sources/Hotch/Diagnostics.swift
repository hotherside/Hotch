import AppKit
import Foundation

/// Headless check of the screens, the parsers and the resume-after-quit state.
/// `--diag` reads only local files (Claude Code's session registry, the model
/// catalog, Codex's session logs, Hotch's own cache) and starts nothing.
/// `--diag-full` additionally asks Claude Code (`get_usage`) and the Codex
/// app-server (`account/rateLimits/read`, `thread/list`), which is account
/// metering and spends nothing. Neither mode reads a vendor credential, so
/// neither can raise a password prompt, and no token is ever printed.
enum Diagnostics {
    static func run(full: Bool) async {
        var out: [String] = []
        out.append("Hotch diagnostics")
        out.append("mode: \(full ? "--diag-full (asks Claude Code and the Codex app-server)" : "--diag (local files only)")")
        out.append("time: \(ISO8601DateFormatter().string(from: Date()))")
        out.append("")

        out.append(contentsOf: screenReport())
        out.append("")

        out.append(contentsOf: claudeUsageReport(full: full))
        out.append("")
        out.append(contentsOf: claudeParserCheck())
        out.append("")
        out.append(contentsOf: claudeSessionsReport())
        out.append("")
        out.append(contentsOf: await codexReport(full: full))
        out.append("")

        // Claude transcript scan. Parser check only: this data never reaches the
        // panel, which reports plan usage or nothing.
        let claudeStart = Date()
        out.append("[claude] transcript scan, ~/.claude/projects (diagnostics only, not shown in the panel)")
        let scan = ClaudeProvider.scanTranscripts()
        out.append("  jsonl files found: \(scan.filesConsidered)")
        out.append("  files scanned (modified < 6h, cap \(ClaudeProvider.maxFallbackFiles)): \(scan.filesScanned)")
        out.append("  usage entries within 5h window: \(scan.entries)")
        out.append("  tokens (input + output + cache_creation): \(scan.tokens)")
        if let newest = scan.newest {
            out.append("  newest entry: \(Fmt.ago(newest) ?? "unknown")")
        }
        out.append(String(format: "  elapsed: %.2fs", Date().timeIntervalSince(claudeStart)))

        out.append("")
        out.append("done")
        print(out.joined(separator: "\n"))
    }

    // MARK: - Claude usage

    private static func claudeUsageReport(full: Bool) -> [String] {
        var out = ["[claude] usage via Claude Code (Hotch holds no Claude credential)"]
        let installs = ClaudeCodeBridge.installs()
        if installs.isEmpty {
            out.append("  Claude Code: not found on any probed path")
        } else {
            out.append("  installs, newest first:")
            for install in installs {
                let link = install.url.path == install.resolved.path ? "" : " -> \(tilde(install.resolved.path))"
                out.append("    \(install.version ?? "?")  \(install.source)  \(tilde(install.url.path))\(link)")
            }
            if let using = installs.first {
                out.append("  using: Claude Code \(using.version ?? "?") (\(using.source))")
            }
        }
        out.append("  Hotch's retired sign-in file (claude-oauth.json): "
                   + (ClaudeCodeBridge.legacyCredentialPresent
                      ? "present, the app deletes it on its first refresh"
                      : "absent"))
        out.append("  Claude Code's credential: never read by Hotch (Claude Code reads its own)")
        out.append("  get_usage floor: \(Int(ClaudeProvider.throttle.minimumInterval))s")

        // Proves the resume-after-quit path: read from disk, in a process that
        // has fetched nothing.
        if let resumed = UsageSnapshotCache.shared.snapshot(for: "claude") {
            out.append("  resumed from disk: \(resumed.windows.count) window(s), \(Fmt.ago(resumed.asOf) ?? "just now")")
        } else {
            out.append("  resumed from disk: nothing usable (no reading, or older than"
                       + " \(Int(UsageSnapshotCache.maxAge / 60))m)")
        }

        guard full else {
            out.append("  get_usage: skipped (pass --diag-full)")
            return out
        }
        guard let install = installs.first else { return out }

        let outcome = ClaudeCodeBridge.fetchUsage(install: install)
        switch outcome {
        case .notInstalled:
            out.append("  get_usage: Claude Code not found")
        case .failed(let reason):
            out.append("  get_usage: failed, \(reason)")
        case .reply(let reply):
            out.append(String(format: "  get_usage: answered in %.2fs by Claude Code %@",
                              reply.elapsed, reply.cliVersion ?? "?"))
            out.append("    account: tokenSource \(reply.tokenSource ?? "-"), apiProvider \(reply.apiProvider ?? "-")"
                       + ", apiKeySource \(reply.apiKeySource == nil ? "-" : "set")")
            out.append("    subscription_type: \(reply.subscriptionType ?? "null")"
                       + ", rate_limits_available: \(reply.rateLimitsAvailable)"
                       + ", rate_limits: \(reply.hasRateLimits ? "object" : "null")")
            if reply.hasRateLimits {
                out.append("    rate_limits keys: \(reply.rateLimitKeys.joined(separator: ", "))")
                out.append("    limits[] rows: \(reply.limitRows.map(String.init) ?? "absent (fell back to five_hour/seven_day)")")
            }
            out.append("    sign-in: \(describe(reply.signIn))")
        }
        let usage = ClaudeProvider.interpret(outcome,
                                             cached: UsageSnapshotCache.shared.snapshot(for: "claude"),
                                             recordResult: false)
        out.append(contentsOf: describe(usage).map { "  " + $0 })
        return out
    }

    /// The `rate_limits` mapping, run against fixtures shaped like Claude Code
    /// 2.1.299's own schema. Needed because a Mac whose Claude Code is not
    /// signed in only ever sees `rate_limits: null`, which exercises nothing.
    private static func claudeParserCheck() -> [String] {
        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600 + 600))
        let week = ISO8601DateFormatter().string(from: Date().addingTimeInterval(4 * 86400))
        let withRows = """
        {"five_hour":{"utilization":41,"resets_at":"\(soon)"},
         "seven_day":{"utilization":22,"resets_at":"\(week)"},
         "seven_day_opus":null,
         "model_scoped":[{"display_name":"Fable","utilization":58,"resets_at":"\(week)"}],
         "limits":[
          {"kind":"session","group":"session","percent":41,"resets_at":"\(soon)","severity":"normal","is_active":false},
          {"kind":"weekly_all","group":"weekly","percent":22,"resets_at":"\(week)","severity":"normal","is_active":false},
          {"kind":"weekly_scoped","group":"weekly","percent":58,"resets_at":"\(week)","severity":"warning",
           "is_active":true,"scope":{"model":{"display_name":"Fable"}}},
          {"kind":"nimbus_quill","group":"credits","percent":100,"resets_at":null,"severity":"normal","is_active":false}],
         "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"utilization":24.8,"currency":"USD"}}
        """
        let withoutRows = """
        {"five_hour":{"utilization":12,"resets_at":"\(soon)"},
         "seven_day":{"utilization":30,"resets_at":"\(week)"},
         "seven_day_sonnet":{"utilization":4,"resets_at":"\(week)"},
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":0,"utilization":null}}
        """
        var out = ["[claude] rate_limits parser check (fixtures shaped like Claude Code 2.1.299's schema)"]
        for (name, json) in [("limits[] present", withRows), ("limits[] absent", withoutRows)] {
            guard let root = JSONWalk.object(json) as? [String: Any] else {
                out.append("  \(name): fixture did not decode")
                continue
            }
            let parsed = ClaudeCodeBridge.parse(rateLimits: root)
            let usage = ProviderUsage(providerID: "claude", displayName: "Claude (\(name))",
                                      windows: parsed.windows, plan: "Max", extras: parsed.extras)
            out.append(contentsOf: describe(usage).map { "  " + $0 })
        }
        return out
    }

    private static func describe(_ signIn: ClaudeCodeBridge.SignIn) -> String {
        switch signIn {
        case .unknown: return "unknown"
        case .signedOut: return "not signed in"
        case .signedIn(let plan): return "signed in" + (plan.map { ", \($0) plan" } ?? "")
        case .noPlan(let reason): return "\(reason), no plan limits"
        }
    }

    // MARK: - Claude sessions

    private static func claudeSessionsReport() -> [String] {
        var out = ["[claude] sessions, registry ~/.claude/sessions"]
        let registry = FS.home.appendingPathComponent(".claude/sessions")
        let entries = ((try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        out.append("  registry entries: \(entries.count) (the .key files beside them are never read)")
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: entry),
                  let dict = JSONWalk.object(data) as? [String: Any],
                  let pid = JSONWalk.int(dict["pid"]) else { continue }
            let cwd = dict["cwd"] as? String ?? ""
            let alive = kill(pid_t(pid), 0) == 0 || errno == EPERM
            let sameProcess = SessionScanner.processStartMatches(pid: pid, procStart: dict["procStart"] as? String)
            let liveness = !alive ? "dead" : (sameProcess ? "live" : "pid reused")
            let status = dict["status"] as? String ?? "(none)"
            let mapped = SessionScanner.registryActivity(dict["status"] as? String).map(activityName) ?? "heuristics"
            var line = "    pid \(pid) \(liveness)  status \(status) -> \(mapped)"
            line += "  name \"\(dict["name"] as? String ?? "")\" (\(dict["nameSource"] as? String ?? "-"))"
            line += "  \(SessionScanner.surfaceName(entrypoint: dict["entrypoint"] as? String))"
            if ClaudeCodeBridge.isOwnWorkDirectory(cwd) { line += "  [Hotch's own usage read, hidden]" }
            if let waiting = dict["waitingFor"] as? String { line += "  waitingFor \"\(waiting)\"" }
            out.append(line)
        }

        let catalog = ClaudeModelCatalog.models()
        out.append("  model catalog: \(catalog.count) model(s) from ~/.claude/cache/model-catalog")

        let sessions = SessionScanner.scan(limit: 20, refreshCodexThreads: false)
        out.append("  sessions page would show (\(sessions.count), capped at \(SessionScanner.maxSessions) in the app):")
        for session in sessions {
            out.append("    " + describe(session))
        }
        return out
    }

    private static func activityName(_ activity: AgentSession.Activity) -> String {
        switch activity {
        case .needsInput: return "needsInput"
        case .working: return "working"
        case .shell: return "shell"
        case .waiting: return "waiting"
        case .ended: return "ended"
        }
    }

    private static func describe(_ session: AgentSession) -> String {
        var parts = ["\(session.providerID) \(activityName(session.activity))", "\"\(session.name)\""]
        if !session.projectName.isEmpty { parts.append(session.projectName) }
        if let surface = session.surface { parts.append(surface) }
        if let model = session.model { parts.append(model) }
        if let tokens = session.contextTokens, let limit = session.contextLimit {
            parts.append("ctx \(Fmt.tokens(tokens))/\(Fmt.tokens(limit))")
        }
        if let waiting = session.waitingFor { parts.append("waiting for \(waiting)") }
        parts.append(Fmt.ago(session.lastEventAt) ?? "")
        return parts.filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  ")
    }

    // MARK: - Codex

    private static func codexReport(full: Bool) async -> [String] {
        let start = Date()
        var out = ["[codex] usage and threads via the Codex CLI"]
        let installs = CodexAppServer.installs()
        if installs.isEmpty {
            out.append("  codex CLI: not found (ChatGPT.app bundle, Homebrew, npm, ~/.local/bin)")
        } else {
            for (index, install) in installs.enumerated() {
                out.append("  \(index == 0 ? "using" : "also ")  \(install.source)  \(tilde(install.url.path))")
            }
        }
        out.append("  signed in: \(FileManager.default.fileExists(atPath: CodexProvider.authURL.path) ? "yes (auth.json present, not read)" : "no, run codex once")")

        let logs = CodexProvider.sessionLogCounts()
        out.append("  session logs: \(logs.plain) readable .jsonl, \(logs.compressed) compressed .jsonl.zst"
                   + (logs.compressed > 0 ? " (zstd; macOS has no decoder, skipped)" : ""))
        if let raw = CodexProvider.rawSnapshotDescription() {
            out.append("  newest raw rate_limits in a .jsonl log: \(raw)")
        }

        let provider = CodexProvider(allowRemote: false)
        if full, !installs.isEmpty {
            let result = await Task.detached(priority: .utility) {
                CodexAppServer.fetchAll(threadLimit: CodexThreadCache.limit)
            }.value
            switch result.limits {
            case .limits(let windows, let plan, let extras):
                out.append("  app-server account/rateLimits/read: \(windows.count) window(s)"
                           + (plan.map { ", \($0)" } ?? "")
                           + (extras.isEmpty ? "" : ", " + extras.joined(separator: ", ")))
            case .noLimits(let plan, let extras):
                out.append("  app-server account/rateLimits/read: answered with no windows"
                           + (plan.map { " (\($0))" } ?? "")
                           + (extras.isEmpty ? "" : ", " + extras.joined(separator: ", ")))
            case .unavailable:
                out.append("  app-server account/rateLimits/read: no answer")
            }
            if !result.rawLimitIDs.isEmpty {
                out.append("    rateLimitsByLimitId: \(result.rawLimitIDs.joined(separator: ", ")) (not shown; rateLimits is the plan view)")
            }

            // The parsed row comes from this same live answer. It used to be
            // printed from an offline provider, which skipped the app-server
            // and fell through to the (now compressed) session logs, so the
            // diagnostic said 0 windows right under a 1-window answer.
            let live = CodexProvider.live(from: result.limits)
            let usage = provider.usage(from: live)
            if case .limits(let reading) = live { UsageSnapshotCache.shared.store(reading) }
            out.append(contentsOf: describe(usage).map { "  " + $0 })

            if let threads = result.threads {
                CodexThreadCache.shared.store(threads)
                out.append("  app-server thread/list (limit \(CodexThreadCache.limit), updated_at): \(threads.count) thread(s)")
                for thread in threads {
                    out.append("    \(thread.id.prefix(8))  \(thread.status.description)"
                               + "  \"\(thread.name ?? SessionScanner.cleanTitle(thread.preview) ?? "")\""
                               + "  \(thread.surface ?? thread.source ?? "-")"
                               + "  \(thread.modelName ?? "-")"
                               + "  updated \(Fmt.ago(thread.updatedAt) ?? "?")")
                }
                let sessions = SessionScanner.codexThreadSessions(threads, now: Date())
                out.append("  sessions page would show from these: \(sessions.count) (recent or running)")
                for session in sessions { out.append("    " + describe(session)) }
            } else {
                out.append("  app-server thread/list: no answer")
            }
        } else {
            out.append("  app-server: skipped (pass --diag-full)")
            if let usage = await provider.fetch() {
                out.append("  offline reading (cache, else session logs):")
                out.append(contentsOf: describe(usage).map { "  " + $0 })
            }
        }
        out.append(String(format: "  elapsed: %.2fs", Date().timeIntervalSince(start)))
        return out
    }

    private static func tilde(_ path: String) -> String {
        let home = FS.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Every screen and the hover target it contributes. The point of listing
    /// them is that a screen with no physical notch must still get a zone —
    /// that is the whole fix for external displays and pre-notch Macs.
    private static func screenReport() -> [String] {
        var lines = ["[screens] hover targets, one per display"]
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return lines + ["  no screens reported"] }

        for (index, screen) in screens.enumerated() {
            let geometry = NotchGeometryResolver.geometry(
                for: screen, contentHeight: NotchGeometryResolver.standardContentHeight)
            let zone = geometry.notchRect
            lines.append("  screen \(index): \(screen.localizedName)"
                         + " \(Int(screen.frame.width))x\(Int(screen.frame.height))"
                         + " at (\(Int(screen.frame.minX)), \(Int(screen.frame.minY)))")
            lines.append("    notch: \(geometry.isRealNotch ? "real hardware" : "virtual zone")"
                         + ", hover rect \(Int(zone.width))x\(Int(zone.height))"
                         + " at (\(Int(zone.minX)), \(Int(zone.minY)))")
            let clearance = geometry.contentClearance
            let heights = PanelPage.allCases.map {
                "\($0.title) \(Int(clearance + PanelMetrics.tabRowHeight + $0.panelContentHeight + PanelMetrics.footerHeight))"
            }
            lines.append("    panel: \(Int(geometry.panelRect.width)) wide, clearance \(Int(clearance))pt; "
                         + "height by section: " + heights.joined(separator: ", "))
        }
        return lines
    }

    private static func describe(_ usage: ProviderUsage) -> [String] {
        var lines: [String] = []
        lines.append("parsed \(usage.displayName): \(usage.windows.count) window(s), asOf \(Fmt.ago(usage.asOf) ?? "now")"
                     + (usage.needsSetup ? "  [needs setup]" : ""))
        for window in usage.windows {
            var parts: [String] = ["\(window.label):"]
            if let consumed = window.consumedPercent {
                parts.append(Fmt.percent(consumed) + " used")
            }
            parts.append("kind \(window.kind.rawValue)" + (window.scope.map { " (\($0))" } ?? ""))
            if let tokens = window.usedTokens { parts.append(Fmt.tokens(tokens) + " tokens") }
            if let minutes = window.windowMinutes { parts.append("window \(minutes)m") }
            if let reset = window.resetsAt { parts.append(Fmt.countdown(to: reset) ?? "") }
            lines.append("  " + parts.filter { !$0.isEmpty }.joined(separator: "  "))
        }
        if let plan = usage.plan { lines.append("  plan: \(plan)") }
        if !usage.extras.isEmpty { lines.append("  extras: \(usage.extras.joined(separator: " | "))") }
        if let detail = usage.detail { lines.append("  detail: \(detail)") }
        return lines
    }

    /// Runs the async diagnostics from top level synchronous code and exits.
    static func runBlockingAndExit(full: Bool) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await run(full: full)
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
