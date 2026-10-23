import Foundation

/// Codex usage. No sign-in of its own: the Codex CLI holds the credential and
/// Hotch asks the CLI rather than impersonating it.
///
/// 1. `codex app-server`, the CLI's own JSON-RPC protocol, preferring the
///    build bundled inside ChatGPT.app (`CodexAppServer`). The only live source
///    that works: it reports the same figures as the Codex desktop app, plus
///    the plan and any rate-limit reset credits, and spends nothing.
///
/// 2. Rate limit snapshots from the session logs the CLI writes under
///    `~/.codex/sessions`. Only as fresh as the last `codex` run, blind to usage
///    spent through the ChatGPT apps, and age-gated accordingly. Current CLIs
///    compress these logs (`rollout-*.jsonl.zst`) and macOS has no zstd
///    decoder, so only the older plain `.jsonl` files can be read; compressed
///    ones are counted and skipped.
///
/// The direct `chatgpt.com/backend-api/codex/usage` call is gone. It answered
/// every plain HTTP client with a Cloudflare challenge, so all it ever did was
/// cost a round trip and a log line before the real answer.
struct CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex"

    static let maxFiles = 5
    static let stalenessThreshold: TimeInterval = 10 * 60

    /// Beyond this a session log reading is not shown as a percentage.
    ///
    /// The old code had no ceiling at all, so a snapshot from the last CLI run
    /// four days earlier was rendered as a confident "100% left" while the
    /// account was actually at 85%. Matches `UsageSnapshotCache.maxAge`.
    static let maxUsefulSnapshotAge: TimeInterval = UsageSnapshotCache.maxAge

    /// The app-server is cheap, but a child process per hover is not; the
    /// panel's refresh cadence governs the UI, not how often Codex is asked.
    static let throttle = EndpointThrottle(minimumInterval: 60)

    /// When false the provider never starts the app-server. Used by `--diag`
    /// so the diagnostic run stays offline.
    var allowRemote: Bool = true

    init(allowRemote: Bool = true) {
        self.allowRemote = allowRemote
    }

    // MARK: - Readiness

    /// Whether this Mac can produce a Codex number at all, and if not, which
    /// half is missing.
    ///
    /// Reported explicitly because a bare "no recent data" is indistinguishable
    /// from a live source having a bad minute: two different problems with two
    /// different fixes deserve two different sentences. It is also what decides
    /// whether Codex is switched on at all — see `ProviderReadiness`, which asks
    /// this same question on first launch.
    enum Readiness: Equatable {
        case ready
        case cliMissing
        case notSignedIn
    }

    /// Cheap enough for the settings window to call on every redraw: two
    /// filesystem checks, no token parsing and no subprocess.
    static func readiness() -> Readiness {
        guard CodexAppServer.isAvailable else { return .cliMissing }
        guard FileManager.default.fileExists(atPath: authURL.path) else { return .notSignedIn }
        return .ready
    }

    static var authURL: URL { FS.home.appendingPathComponent(".codex/auth.json") }

    /// An empty row that states the reason. `needsSetup` is set because both of
    /// these are things the user can actually fix, which is what earns the row
    /// its call-to-action styling.
    private func setupNeeded(_ readiness: Readiness) -> ProviderUsage {
        let detail: String
        switch readiness {
        case .cliMissing:
            detail = "Codex CLI not installed \u{00B7} brew install --cask codex"
        case .notSignedIn:
            detail = "Codex CLI installed \u{00B7} run codex and sign in"
        case .ready:
            detail = "waiting for Codex"
        }
        return ProviderUsage(providerID: id,
                             displayName: displayName,
                             windows: [],
                             asOf: Date(),
                             detail: detail,
                             needsSetup: true)
    }

    /// Signed in, asked, answered: this account simply has no Codex plan
    /// windows. A ChatGPT subscription without Codex included, or an API-key
    /// account, lands here. Not `needsSetup` — there is nothing to set up, and
    /// pretending otherwise would send the user hunting for a step that does not
    /// exist.
    private func noPlanUsage(plan: String?, extras: [String]) -> ProviderUsage {
        var detail = "no Codex usage limits on this account"
        if let plan, !plan.isEmpty { detail = "\(plan) \u{00B7} no Codex usage limits" }
        return ProviderUsage(providerID: id,
                             displayName: displayName,
                             windows: [],
                             asOf: Date(),
                             detail: detail,
                             plan: plan,
                             extras: extras)
    }

    func fetch() async -> ProviderUsage? {
        // Offline mode reads the session logs below, which need no credentials,
        // but a persisted live reading beats them when one exists.
        if !allowRemote, let cached = UsageSnapshotCache.shared.snapshot(for: id) {
            return cached
        }

        // Nothing installed or nobody signed in: say which, and stop. No point
        // spawning a subprocess or scanning logs that cannot exist.
        let readiness = CodexProvider.readiness()
        if readiness != .ready { return setupNeeded(readiness) }

        if allowRemote {
            if CodexProvider.throttle.claim() {
                switch await CodexProvider.fetchViaAppServer() {
                case .limits(let live):
                    CodexProvider.throttle.noteSuccess()
                    UsageSnapshotCache.shared.store(live)
                    return live
                case .noLimits(let plan, let extras):
                    // A definite answer, so it counts as a success for pacing —
                    // and it must not be overridden by a stale session log,
                    // which is why it returns here.
                    CodexProvider.throttle.noteSuccess()
                    return noPlanUsage(plan: plan, extras: extras)
                case .unavailable:
                    CodexProvider.throttle.noteFailure()
                    if let cached = UsageSnapshotCache.shared.snapshot(for: id) { return cached }
                }
            } else if let cached = UsageSnapshotCache.shared.snapshot(for: id) {
                return cached
            }
        }
        return logFallback()
    }

    /// The session-log reading, or the sentence that explains its absence.
    func logFallback(now: Date = Date()) -> ProviderUsage {
        guard let snapshot = CodexProvider.latestSnapshot(now: now) else {
            // Signed in, but no live answer and no readable log. Current CLIs
            // only write compressed logs, so say which it is.
            let compressed = CodexProvider.sessionLogCounts().compressed > 0
            return ProviderUsage(providerID: id,
                                 displayName: displayName,
                                 windows: [],
                                 asOf: now,
                                 detail: compressed
                                     ? "signed in \u{00B7} waiting for Codex to answer"
                                     : "signed in \u{00B7} no usage reported yet")
        }

        let age = now.timeIntervalSince(snapshot.asOf)

        // Too old to stand behind. Report the reason instead of a stale number:
        // a wrong percentage shown confidently is the one failure this panel
        // cannot afford.
        if age > CodexProvider.maxUsefulSnapshotAge {
            return ProviderUsage(providerID: id,
                                 displayName: displayName,
                                 windows: [],
                                 asOf: now,
                                 detail: "last Codex run was \(Fmt.duration(age)) ago"
                                         + " \u{00B7} no live source")
        }

        var detail: String?
        if age > CodexProvider.stalenessThreshold {
            detail = "as of Codex run \(Fmt.duration(age)) ago"
        }

        return ProviderUsage(providerID: id,
                             displayName: displayName,
                             windows: WindowRank.sorted(snapshot.windows),
                             asOf: snapshot.asOf,
                             detail: detail)
    }

    // MARK: - Live source

    /// What the live source established, preserving the difference between "no
    /// answer" and "answered, and there is nothing to meter".
    enum LiveOutcome {
        case limits(ProviderUsage)
        case noLimits(plan: String?, extras: [String])
        case unavailable
    }

    /// Bridges the blocking subprocess exchange onto the async refresh path.
    static func fetchViaAppServer() async -> LiveOutcome {
        guard CodexAppServer.isAvailable else { return .unavailable }
        let outcome = await ChildProcess.offPool {
            CodexAppServer.fetchRateLimits()
        }
        return live(from: outcome)
    }

    /// Shared with `--diag-full`, which makes the read itself.
    static func live(from outcome: CodexAppServer.Outcome, now: Date = Date()) -> LiveOutcome {
        switch outcome {
        case .limits(let windows, let plan, let extras):
            return .limits(ProviderUsage(providerID: "codex",
                                         displayName: "Codex",
                                         windows: windows,
                                         asOf: now,
                                         // Today's views print `detail` beside
                                         // the rings; the plan belongs there.
                                         detail: plan.map { "\($0) plan" },
                                         plan: plan,
                                         extras: extras))
        case .noLimits(let plan, let extras):
            return .noLimits(plan: plan, extras: extras)
        case .unavailable:
            return .unavailable
        }
    }

    /// The row the provider would draw from a live outcome, for diagnostics.
    func usage(from live: LiveOutcome) -> ProviderUsage {
        switch live {
        case .limits(let usage): return usage
        case .noLimits(let plan, let extras): return noPlanUsage(plan: plan, extras: extras)
        case .unavailable: return logFallback()
        }
    }

    // MARK: - Session logs

    static var sessionsRoot: URL { FS.home.appendingPathComponent(".codex/sessions", isDirectory: true) }

    /// Plain logs Hotch can read, and zstd-compressed ones it cannot.
    static func sessionLogCounts() -> (plain: Int, compressed: Int) {
        (FS.files(under: sessionsRoot, pathExtension: "jsonl").count,
         FS.files(under: sessionsRoot, pathExtension: "zst").count)
    }

    struct Snapshot {
        var windows: [UsageWindow]
        var asOf: Date
        var sourceFile: String
    }

    /// Scans the five most recently modified session files and returns the
    /// newest rate limit snapshot found across them.
    static func latestSnapshot(now: Date = Date()) -> Snapshot? {
        let root = FS.home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = FS.sortedByRecency(FS.files(under: root, pathExtension: "jsonl"), limit: maxFiles)
        guard !files.isEmpty else { return nil }

        var best: Snapshot?
        for url in files {
            guard let candidate = snapshot(inFileAt: url, now: now) else { continue }
            if let current = best {
                if candidate.asOf > current.asOf { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }

    static let needle = Bytes.pattern("rate_limits")

    /// Reads the tail of a session file and walks backwards to the newest line
    /// carrying rate limits. Codex writes a snapshot on every token_count event,
    /// so the freshest one is always near the end of the log.
    static func snapshot(inFileAt url: URL, now: Date = Date()) -> Snapshot? {
        for lineData in LineReader.tailLines(atPath: url.path).reversed() {
            guard Bytes.contains(lineData, needle) else { continue }
            guard let (timestamp, limits) = rateLimits(in: lineData, url: url, requireUsedPercent: true) else { continue }
            let windows = parse(rateLimits: limits, timestamp: timestamp)
            guard !windows.isEmpty else { continue }
            return Snapshot(windows: windows, asOf: timestamp, sourceFile: url.lastPathComponent)
        }
        return nil
    }

    /// Extracts the rate limit dictionary and its owning timestamp from one line.
    static func rateLimits(in lineData: Data,
                           url: URL,
                           requireUsedPercent: Bool) -> (Date, [String: Any])? {
        guard let root = JSONWalk.object(lineData) else { return nil }
        guard let limits = JSONWalk.findDictionary(named: "rate_limits", in: root, matching: { dict in
            guard requireUsedPercent else { return true }
            return dict.values.contains { ($0 as? [String: Any])?["used_percent"] != nil }
        }) else { return nil }

        let timestamp = DateParse.date(from: (root as? [String: Any])?["timestamp"])
            ?? DateParse.date(from: JSONWalk.findDictionary(containing: "timestamp", in: root)?["timestamp"])
            ?? FS.modificationDate(url)
        return (timestamp, limits)
    }

    /// Diagnostics only. Rate limit buckets carry percentages and window sizes,
    /// never credentials, so this is safe to print.
    static func rawSnapshotDescription() -> String? {
        let root = FS.home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = FS.sortedByRecency(FS.files(under: root, pathExtension: "jsonl"), limit: maxFiles)
        var newest: (Date, [String: Any])?

        for url in files {
            for lineData in LineReader.tailLines(atPath: url.path).reversed() {
                guard Bytes.contains(lineData, needle) else { continue }
                guard let match = rateLimits(in: lineData, url: url, requireUsedPercent: false) else { continue }
                if newest == nil || match.0 > newest!.0 { newest = match }
                break
            }
        }

        guard let newest else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: newest.1, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    static func parse(rateLimits: [String: Any], timestamp: Date) -> [UsageWindow] {
        var windows: [UsageWindow] = []

        // Keep the well known keys in a stable order, then anything else.
        let ordered = ["primary", "secondary"] + rateLimits.keys.filter {
            $0 != "primary" && $0 != "secondary"
        }.sorted()

        for key in ordered {
            guard let bucket = rateLimits[key] as? [String: Any] else { continue }
            guard let usedPercent = JSONWalk.double(bucket["used_percent"]) else { continue }

            let windowMinutes = JSONWalk.int(bucket["window_minutes"])
            var resetsAt: Date?
            if let resetsIn = JSONWalk.double(bucket["resets_in_seconds"]) {
                resetsAt = timestamp.addingTimeInterval(resetsIn)
            } else if let explicit = DateParse.date(from: bucket["resets_at"]) {
                resetsAt = explicit
            }

            windows.append(UsageWindow(
                label: label(forKey: key, windowMinutes: windowMinutes),
                usedPercent: min(100, max(0, usedPercent)),
                usedTokens: JSONWalk.int(bucket["used_tokens"]),
                resetsAt: resetsAt,
                windowMinutes: windowMinutes
            ))
        }

        return windows
    }

    /// Window length is a better signal than the bucket name when present.
    static func label(forKey key: String, windowMinutes: Int?) -> String {
        if let minutes = windowMinutes, minutes > 0 {
            if minutes <= 600 { return "Session" }
            if minutes >= 7000 { return "Week" }
            return Fmt.windowLabel(minutes: minutes)
        }
        switch key {
        case "primary": return "Session"
        case "secondary": return "Week"
        default: return Fmt.humanize(key: key)
        }
    }
}
