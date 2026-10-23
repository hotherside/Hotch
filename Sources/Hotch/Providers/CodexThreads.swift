import Foundation

/// The Codex thread list for the sessions page, fetched from `codex
/// app-server` at most every 30 seconds and only when someone asks.
///
/// The sessions page rescans every few seconds while it is visible. A scan is
/// directory listings and file stats; starting a Codex child process that often
/// would not be. So a scan reads this cache, and a stale cache schedules one
/// background refresh whose answer the *next* scan picks up. Nothing here runs
/// on a timer of its own: if no surface asks for sessions, no child is started.
final class CodexThreadCache: @unchecked Sendable {
    static let shared = CodexThreadCache()

    /// Floor between two `thread/list` reads, success or failure alike, so a
    /// broken CLI cannot turn the scan cadence into a spawn loop.
    static let refreshInterval: TimeInterval = 30
    static let limit = 10

    private let lock = NSLock()
    private var threads: [CodexThread] = []
    private var fetchedAt: Date?
    private var lastAttempt: Date?
    private var inFlight = false

    /// The cached list, and whether it is real (at least one read has
    /// succeeded). Schedules a background refresh when the last attempt is
    /// older than the floor.
    /// `refresh: false` reads the cache without ever starting anything, for
    /// offline callers such as `--diag`.
    func current(now: Date = Date(), refresh: Bool = true) -> (threads: [CodexThread], fetchedAt: Date?) {
        lock.lock()
        let snapshot = (threads, fetchedAt)
        let due = refresh && !inFlight
            && (lastAttempt.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true)
        if due {
            inFlight = true
            lastAttempt = now
        }
        lock.unlock()

        if due {
            DispatchQueue.global(qos: .utility).async { [self] in
                _ = refreshNow()
            }
        }
        return snapshot
    }

    /// One blocking read, for the background refresh and for `--diag-full`.
    @discardableResult
    func refreshNow() -> [CodexThread]? {
        // Same readiness the usage row uses: no binary or no sign-in means
        // nothing to list, and no reason to start anything.
        let fetched = CodexProvider.readiness() == .ready
            ? CodexAppServer.fetchThreads(limit: Self.limit)
            : nil
        lock.lock()
        if let fetched {
            threads = fetched
            fetchedAt = Date()
        }
        inFlight = false
        lastAttempt = Date()
        lock.unlock()
        return fetched
    }

    /// Seeds the cache from a read made elsewhere (the diagnostics run both
    /// reads in one child).
    func store(_ fetched: [CodexThread]) {
        lock.lock()
        threads = fetched
        fetchedAt = Date()
        lastAttempt = Date()
        lock.unlock()
    }
}
