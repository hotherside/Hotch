import Foundation

/// Rate discipline for one remote endpoint.
///
/// This exists because `api.anthropic.com/api/oauth/usage` answers HTTP 429
/// `rate_limit_error` when it is polled at the app's UI cadence. The refresh
/// interval the user picks governs how often the *panel* updates; how often a
/// vendor endpoint is actually called is a separate question, and the answer is
/// per endpoint. None of these limits are documented, so the floor is a
/// conservative guess and the backoff is what actually finds a rate the server
/// tolerates.
final class EndpointThrottle: @unchecked Sendable {
    /// Never call more often than this, no matter what the UI asks for.
    let minimumInterval: TimeInterval
    /// Ceiling for the backoff after repeated throttling.
    let maximumBackoff: TimeInterval

    private let lock = NSLock()
    private var lastAttempt: Date?
    /// Extra wait imposed by the server pushing back, on top of the floor.
    private var penalty: TimeInterval = 0
    private var consecutiveThrottles = 0

    init(minimumInterval: TimeInterval, maximumBackoff: TimeInterval = 1800) {
        self.minimumInterval = minimumInterval
        self.maximumBackoff = maximumBackoff
    }

    /// Books the next call if one is due. Returns false when the caller should
    /// use whatever it showed last instead of hitting the network.
    func claim(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastAttempt {
            let wait = max(minimumInterval, penalty)
            guard now.timeIntervalSince(last) >= wait else { return false }
        }
        lastAttempt = now
        return true
    }

    /// How fast a learned interval is given back after a success. Deliberately
    /// gentle: converging on the tolerated rate from above beats snapping back to
    /// the floor and getting throttled again on the very next tick.
    private static let decay = 0.75

    func noteSuccess() {
        lock.lock()
        let before = penalty
        // Decay rather than reset. Resetting to the floor is what makes a
        // backoff oscillate — throttled, back off, succeed, snap to the floor,
        // throttled again — so the effective rate never settles anywhere and
        // most calls are wasted on 429s. Easing back down lets the interval
        // converge on whatever the server actually tolerates, which matters
        // because none of these limits are published.
        penalty *= EndpointThrottle.decay
        if penalty < minimumInterval { penalty = 0 }
        consecutiveThrottles = 0
        let after = penalty
        lock.unlock()

        if before > 0 {
            let next = Int(max(minimumInterval, after))
            hotchLog.log("endpoint recovered, easing interval to \(next)s")
        }
    }

    /// The server said it is being polled too hard.
    ///
    /// `retryAfter` can only ever lengthen the wait, never shorten it. Anthropic
    /// does send `Retry-After` on a 429 from the usage endpoint, but the observed
    /// value is `0` — obeying it literally would mean retrying immediately into
    /// the same limit, so it is treated as a floor to respect rather than an
    /// instruction to trust.
    func noteThrottled(retryAfter: TimeInterval?) {
        lock.lock()
        consecutiveThrottles += 1
        // Doubles from wherever the learned interval already sits, so a decayed
        // penalty is not thrown away and the search resumes near the last known
        // good rate instead of starting over at the floor.
        let doubled = max(minimumInterval * 2, penalty * 2)
        penalty = min(maximumBackoff, max(retryAfter ?? 0, doubled))
        let backoff = penalty
        let count = consecutiveThrottles
        lock.unlock()
        hotchLog.log("endpoint throttled (\(count)x), backing off \(Int(backoff))s")
    }

    /// A transport error or an unexpected status. Not the server's rate limiter,
    /// so no escalating penalty: the floor already keeps retries civil.
    func noteFailure() {
        lock.lock()
        penalty = 0
        lock.unlock()
    }

    /// Drops the floor and the learned interval for the next call only.
    ///
    /// Reserved for the case where what changed is the *credential*, not the
    /// endpoint: everything this object learned was learned against an account
    /// that no longer exists. Without it a user who has just finished signing in
    /// watches an empty row until the floor elapses and reads that as the
    /// sign-in having failed — which is exactly what they did. Never call it for
    /// a failure: the backoff is the only thing keeping the poll rate somewhere
    /// the server tolerates.
    func reset() {
        lock.lock()
        lastAttempt = nil
        penalty = 0
        consecutiveThrottles = 0
        lock.unlock()
    }

    /// Seconds until the next call is allowed, for diagnostics.
    func secondsUntilNextCall(now: Date = Date()) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastAttempt else { return 0 }
        return max(0, max(minimumInterval, penalty) - now.timeIntervalSince(last))
    }
}

/// Last good reading per provider, surviving a relaunch.
///
/// Without this, any hiccup — a 429, a dropped connection, a refresh that
/// overlaps a token rotation — blanks the row or, worse, lets a provider answer
/// from a completely different data source, so the panel appears to flip between
/// two kinds of number. A cached reading carries its original `asOf`, so the row
/// labels itself as stale rather than pretending to be current.
///
/// It persists to disk because these endpoints are rate limited hard enough that
/// a cold start can easily be throttled on its first call. Quitting and
/// reopening should resume where it left off, showing the last known numbers
/// with their real age, rather than an empty panel that looks broken.
final class UsageSnapshotCache: @unchecked Sendable {
    static let shared = UsageSnapshotCache()

    /// Beyond this a reading is not worth showing: the 5 hour window it
    /// describes has moved too far for the number to mean anything.
    static let maxAge: TimeInterval = 2 * 3600

    /// Not a secret — plan percentages and reset times — so it lives beside the
    /// credential rather than inside it.
    private static let fileName = "last-usage"

    private let lock = NSLock()
    private var snapshots: [String: ProviderUsage] = [:]

    /// Guards the one-time load. Separate from `lock` so the file read does not
    /// happen while readers of `snapshots` are blocked, and held for the whole
    /// load so a second caller waits for the data instead of racing past it.
    private let loadLock = NSLock()
    private var loaded = false

    func store(_ usage: ProviderUsage) {
        lock.lock()
        snapshots[usage.providerID] = usage
        let all = snapshots
        lock.unlock()
        persist(all)
    }

    func snapshot(for providerID: String,
                  maxAge: TimeInterval = UsageSnapshotCache.maxAge,
                  now: Date = Date()) -> ProviderUsage? {
        loadIfNeeded()
        lock.lock()
        let cached = snapshots[providerID]
        lock.unlock()
        guard let cached, now.timeIntervalSince(cached.asOf) <= maxAge else { return nil }
        return cached
    }

    func clear(_ providerID: String) {
        lock.lock()
        snapshots[providerID] = nil
        let all = snapshots
        lock.unlock()
        persist(all)
    }

    // MARK: - Persistence

    /// Hand-rolled rather than Codable: ProviderUsage is a UI-facing model that
    /// changes shape as providers are added, and a decode failure must never be
    /// able to stop the app from starting. Anything unreadable is simply dropped
    /// and refetched.
    private func persist(_ snapshots: [String: ProviderUsage]) {
        let payload: [[String: Any]] = snapshots.values.map { usage in
            var item: [String: Any] = [
                "providerID": usage.providerID,
                "displayName": usage.displayName,
                "asOf": usage.asOf.timeIntervalSince1970,
                "windows": usage.windows.map { window -> [String: Any] in
                    var encoded: [String: Any] = ["label": window.label]
                    if let percent = window.usedPercent { encoded["usedPercent"] = percent }
                    if let tokens = window.usedTokens { encoded["usedTokens"] = tokens }
                    if let resets = window.resetsAt { encoded["resetsAt"] = resets.timeIntervalSince1970 }
                    if let minutes = window.windowMinutes { encoded["windowMinutes"] = minutes }
                    encoded["kind"] = window.kind.rawValue
                    if let scope = window.scope { encoded["scope"] = scope }
                    return encoded
                }
            ]
            if let detail = usage.detail { item["detail"] = detail }
            if let plan = usage.plan { item["plan"] = plan }
            if !usage.extras.isEmpty { item["extras"] = usage.extras }
            if let balance = usage.balance {
                item["balance"] = ["amount": balance.amount, "currency": balance.currency]
            }
            return item
        }
        CredentialStore.writeJSON(["providers": payload], name: UsageSnapshotCache.fileName)
    }

    /// Reads the file at most once per process.
    ///
    /// Providers are fetched concurrently in a task group, so this is genuinely
    /// contended. An earlier version set `loaded` before reading the file and
    /// released the lock, which let the second provider sail past the gate and
    /// query an empty dictionary — one row resumed and the other showed nothing,
    /// nondeterministically. Holding `loadLock` across the whole load makes the
    /// loser wait for the data rather than miss it.
    private func loadIfNeeded() {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !loaded else { return }
        loaded = true

        guard let root = CredentialStore.readJSON(UsageSnapshotCache.fileName),
              let items = root["providers"] as? [[String: Any]] else { return }

        var restored: [String: ProviderUsage] = [:]
        for item in items {
            guard let id = item["providerID"] as? String,
                  let name = item["displayName"] as? String,
                  let asOf = JSONWalk.double(item["asOf"]) else { continue }

            let windows: [UsageWindow] = (item["windows"] as? [[String: Any]] ?? []).compactMap {
                guard let label = $0["label"] as? String else { return nil }
                return UsageWindow(
                    label: label,
                    usedPercent: JSONWalk.double($0["usedPercent"]),
                    usedTokens: JSONWalk.int($0["usedTokens"]),
                    resetsAt: JSONWalk.double($0["resetsAt"]).map(Date.init(timeIntervalSince1970:)),
                    windowMinutes: JSONWalk.int($0["windowMinutes"]),
                    // Absent in files written before kinds existed; the
                    // initialiser infers one from the length and label then.
                    kind: ($0["kind"] as? String).flatMap(WindowKind.init(rawValue:)),
                    scope: $0["scope"] as? String
                )
            }

            var balance: ProviderBalance?
            if let encoded = item["balance"] as? [String: Any],
               let amount = JSONWalk.double(encoded["amount"]),
               let currency = encoded["currency"] as? String {
                balance = ProviderBalance(amount: amount, currency: currency)
            }

            restored[id] = ProviderUsage(providerID: id,
                                         displayName: name,
                                         windows: WindowRank.sorted(windows),
                                         asOf: Date(timeIntervalSince1970: asOf),
                                         detail: item["detail"] as? String,
                                         balance: balance,
                                         plan: item["plan"] as? String,
                                         extras: item["extras"] as? [String] ?? [])
        }

        lock.lock()
        // Anything fetched while the load was in flight is newer than the file.
        restored.merge(snapshots) { _, live in live }
        snapshots = restored
        lock.unlock()
    }
}
