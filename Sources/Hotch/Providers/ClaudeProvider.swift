import Foundation

/// Claude plan usage, as Claude Code reports it.
///
/// Hotch holds no Claude credential. It used to run its own Claude.ai sign-in
/// and keep the tokens in its support folder; Anthropic's terms do not allow a
/// third-party app to do either, so that path is gone, file and all. What is
/// left is asking Claude Code — which is signed in already, or can be with one
/// `claude auth login` — through `ClaudeCodeBridge`.
///
/// One source of truth, as before: plan windows or an honest empty row. The
/// rows this can draw, each with its own sentence:
///
/// | State | Row says | needsSetup |
/// |---|---|---|
/// | No Claude Code on any probed path | "Claude Code not found" | yes |
/// | Claude Code not signed in | "Sign in to Claude Code once" | yes |
/// | API key, Bedrock, a token without profile scope | "Claude Code uses … · no plan limits" | no |
/// | Signed in, read failed or throttled | last good reading, aged, else "usage check unavailable, retrying" | no |
/// | Signed in, answered | the windows, `plan`, `extras` | no |
struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"

    /// When false the provider never starts Claude Code. Used by `--diag` and
    /// the snapshot renderers so they stay offline and side-effect free.
    var allowRemote: Bool = true

    init(allowRemote: Bool = true) {
        self.allowRemote = allowRemote
    }

    /// Floor between two `get_usage` reads. Claude Code itself caches a usage
    /// reply for a minute and the endpoint behind it rate limits, and the
    /// windows are five hours and a week long, so two minutes loses nothing.
    static let throttle = EndpointThrottle(minimumInterval: 120)

    func fetch() async -> ProviderUsage? {
        guard allowRemote else {
            if let cached = UsageSnapshotCache.shared.snapshot(for: id) { return cached }
            guard ClaudeCodeBridge.isInstalled else { return notInstalled() }
            if ClaudeCodeBridge.cachedSignIn == .signedOut { return notSignedIn() }
            return ClaudeProvider.lastVerdict.value ?? unavailable()
        }

        // The new version's first refresh deletes Hotch's own retired sign-in
        // file. Once per launch, a no-op when it is already gone.
        ClaudeCodeBridge.retireLegacyCredential()

        guard let install = ClaudeCodeBridge.locate() else {
            return ClaudeProvider.lastVerdict.set(notInstalled())
        }

        let cached = UsageSnapshotCache.shared.snapshot(for: id)
        // Not due yet. The panel forces a refresh on every expand, so without
        // this Claude Code would be started on every hover.
        guard ClaudeProvider.throttle.claim() else {
            return cached ?? ClaudeProvider.lastVerdict.value ?? unavailable()
        }

        // Detached, so a reply that lands after the store's own timeout still
        // reaches the cache for the next refresh instead of being thrown away.
        let outcome = await ChildProcess.offPool {
            ClaudeCodeBridge.fetchUsage(install: install)
        }
        return ClaudeProvider.interpret(outcome, cached: cached)
    }

    // MARK: - Turning a reply into a row

    /// Shared with `--diag-full`, so the diagnostic prints exactly the row the
    /// panel would have drawn from the same reply.
    static func interpret(_ outcome: ClaudeCodeBridge.FetchOutcome,
                          cached: ProviderUsage?,
                          recordResult: Bool = true) -> ProviderUsage {
        let provider = ClaudeProvider()
        switch outcome {
        case .notInstalled:
            return lastVerdict.set(provider.notInstalled())

        case .failed(let reason):
            hotchLog.log("claude: \(reason)")
            throttle.noteFailure()
            return cached ?? lastVerdict.value ?? provider.unavailable()

        case .reply(let reply):
            ClaudeCodeBridge.note(reply.signIn)
            switch reply.signIn {
            case .signedOut, .unknown:
                throttle.noteSuccess()
                // Signed out means the numbers on disk belong to an account
                // Claude Code no longer holds; showing them would be a lie.
                if recordResult { UsageSnapshotCache.shared.clear("claude") }
                return lastVerdict.set(provider.notSignedIn())

            case .noPlan(let reason):
                throttle.noteSuccess()
                if recordResult { UsageSnapshotCache.shared.clear("claude") }
                return lastVerdict.set(ProviderUsage(providerID: provider.id,
                                                     displayName: provider.displayName,
                                                     windows: [],
                                                     detail: "\(reason) \u{00B7} no plan limits"))

            case .signedIn(let plan):
                lastVerdict.clear()
                guard reply.hasRateLimits else {
                    // Signed in, but Claude Code could not reach the usage
                    // endpoint this time (rate limited, offline). Keep the
                    // last good reading rather than announcing anything.
                    throttle.noteFailure()
                    return cached ?? provider.unavailable(plan: plan)
                }
                throttle.noteSuccess()
                let usage = ProviderUsage(providerID: provider.id,
                                          displayName: provider.displayName,
                                          windows: WindowRank.sorted(reply.windows),
                                          asOf: Date(),
                                          // Today's views print `detail` beside the
                                          // rings; the plan is what belongs there.
                                          detail: reply.windows.isEmpty
                                              ? [plan, "no plan limits reported"].compactMap { $0 }
                                                  .joined(separator: " \u{00B7} ")
                                              : plan.map { "\($0) plan" },
                                          plan: plan,
                                          extras: reply.extras)
                if recordResult && !usage.windows.isEmpty { UsageSnapshotCache.shared.store(usage) }
                return usage
            }
        }
    }

    /// No Claude Code anywhere Hotch looks.
    func notInstalled() -> ProviderUsage {
        ProviderUsage(providerID: id,
                      displayName: displayName,
                      windows: [],
                      detail: "Claude Code not found",
                      needsSetup: true)
    }

    /// Claude Code is there but has no sign-in. The one fix is Claude Code's
    /// own sign-in, which Settings starts.
    func notSignedIn() -> ProviderUsage {
        ProviderUsage(providerID: id,
                      displayName: displayName,
                      windows: [],
                      detail: "Sign in to Claude Code once",
                      needsSetup: true)
    }

    /// Signed in, but nothing to show yet. Not `needsSetup`: a wait that ends
    /// must not look like something the user has to fix.
    func unavailable(plan: String? = nil) -> ProviderUsage {
        ProviderUsage(providerID: id,
                      displayName: displayName,
                      windows: [],
                      detail: "usage check unavailable, retrying",
                      plan: plan)
    }

    /// The last row that was a verdict rather than numbers ("not signed in"),
    /// so a refresh the throttle declines repeats it instead of going blank.
    static let lastVerdict = VerdictBox()

    final class VerdictBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ProviderUsage?

        var value: ProviderUsage? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        @discardableResult
        func set(_ usage: ProviderUsage) -> ProviderUsage {
            lock.lock()
            stored = usage
            lock.unlock()
            return usage
        }

        func clear() {
            lock.lock()
            stored = nil
            lock.unlock()
        }
    }

    // MARK: - Local transcript scan (diagnostics only)

    /// Token accounting over `~/.claude/projects`, kept for `--diag` so the
    /// parsers stay testable. Deliberately not wired into the panel: a token
    /// count is not a subscription percentage, and showing one where the other
    /// belongs is what made the readout look like it was changing units.

    static let sessionWindowHours: Double = 5
    static let fileScanWindowHours: Double = 6
    static let maxFallbackFiles = 50
    /// The 5 hour window is charted as 20 buckets of 15 minutes each.
    static let bucketCount = 20
    static var bucketSeconds: Double { sessionWindowHours * 3600 / Double(bucketCount) }

    struct TranscriptScan {
        var tokens: Int = 0
        var entries: Int = 0
        var filesScanned: Int = 0
        var filesConsidered: Int = 0
        var newest: Date?
        /// Tokens per 15 minute bucket across the 5 hour window, oldest first.
        var buckets: [Double] = Array(repeating: 0, count: ClaudeProvider.bucketCount)
    }

    static func scanTranscripts(now: Date = Date()) -> TranscriptScan {
        var scan = TranscriptScan()
        let root = FS.home.appendingPathComponent(".claude/projects", isDirectory: true)
        let all = FS.files(under: root, pathExtension: "jsonl")
        scan.filesConsidered = all.count

        let fileCutoff = now.addingTimeInterval(-fileScanWindowHours * 3600)
        let recent = FS.sortedByRecency(all.filter { FS.modificationDate($0) >= fileCutoff },
                                        limit: maxFallbackFiles)
        scan.filesScanned = recent.count

        let entryCutoff = now.addingTimeInterval(-sessionWindowHours * 3600)

        let upperBound = now.addingTimeInterval(60)
        let needle = Bytes.pattern("\"input_tokens\"")

        for url in recent {
            LineReader.forEachLineData(atPath: url.path) { lineData in
                // Transcript lines can be hundreds of kilobytes, so reject on raw
                // bytes before paying for UTF-8 decoding or any JSON work.
                guard Bytes.contains(lineData, needle) else { return true }
                guard let line = String(data: lineData, encoding: .utf8) else { return true }
                guard let timestamp = extractTimestamp(from: line),
                      timestamp >= entryCutoff, timestamp <= upperBound else { return true }
                guard let usage = extractUsage(from: line) else { return true }

                let input = JSONWalk.int(usage["input_tokens"]) ?? 0
                let output = JSONWalk.int(usage["output_tokens"]) ?? 0
                let cacheCreate = JSONWalk.int(usage["cache_creation_input_tokens"]) ?? 0
                // cache_read_input_tokens is deliberately excluded.
                let total = input + output + cacheCreate
                guard total > 0 else { return true }

                scan.tokens += total
                scan.entries += 1

                let offset = timestamp.timeIntervalSince(entryCutoff)
                let bucket = min(bucketCount - 1, max(0, Int(offset / bucketSeconds)))
                scan.buckets[bucket] += Double(total)

                if let newest = scan.newest {
                    if timestamp > newest { scan.newest = timestamp }
                } else {
                    scan.newest = timestamp
                }
                return true
            }
        }

        return scan
    }

    /// Pulls the ISO8601 timestamp out of a transcript line without parsing the
    /// whole record.
    static func extractTimestamp(from line: String) -> Date? {
        for marker in ["\"timestamp\":\"", "\"timestamp\": \""] {
            guard let range = line.range(of: marker) else { continue }
            let start = range.upperBound
            let limit = line.index(start, offsetBy: 40, limitedBy: line.endIndex) ?? line.endIndex
            guard let end = line[start..<limit].firstIndex(of: "\"") else { continue }
            if let date = DateParse.date(from: String(line[start..<end])) { return date }
        }
        return nil
    }

    /// Brace matches the small `"usage": { ... }` object rather than decoding the
    /// entire line. Falls back to a full parse if the fragment does not decode.
    static func extractUsage(from line: String) -> [String: Any]? {
        if let range = line.range(of: "\"usage\":") {
            let start = range.upperBound
            let limit = line.index(start, offsetBy: 800, limitedBy: line.endIndex) ?? line.endIndex
            let slice = line[start..<limit]
            var depth = 0
            var objectStart: String.Index?
            var index = slice.startIndex
            while index < slice.endIndex {
                let character = slice[index]
                if character == "{" {
                    if depth == 0 { objectStart = index }
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0, let objectStart {
                        let fragment = String(slice[objectStart...index])
                        if let dict = JSONWalk.object(fragment) as? [String: Any],
                           dict["input_tokens"] != nil {
                            return dict
                        }
                        break
                    }
                }
                index = slice.index(after: index)
            }
        }

        guard let root = JSONWalk.object(line) else { return nil }
        return JSONWalk.findDictionary(containing: "input_tokens", in: root)
    }
}
