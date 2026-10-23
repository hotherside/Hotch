import Foundation

// MARK: - Model

/// One reading of one window, kept so the panel can answer the question the
/// live numbers only hint at: not "how much is used" but "at this pace, do I
/// hit the cap before it resets".
struct UsageSample: Sendable, Hashable {
    var time: Date
    /// Always consumption, whatever the display mode says. History has to be
    /// one quantity or slopes computed across a mode change would be garbage;
    /// the views convert for display the same way they do everywhere else.
    var consumedPercent: Double
}

/// The projection drawn from recent samples.
struct BurnForecast: Sendable {
    /// Consumption per hour over the fitted stretch. Can be ~0 (idle).
    var ratePerHour: Double
    /// When the window hits 100% at this pace. Nil when the pace is flat.
    var capETA: Date?
    /// How much history the fit stands on, for honesty in the caption.
    var basis: TimeInterval
}

// MARK: - Store

/// Rolling history of window consumption, fed by every successful refresh and
/// persisted beside `last-usage.json`. Plan percentages and timestamps only —
/// nothing secret — and hand-encoded for the same reason the snapshot cache is:
/// a decode failure must never stop the app from starting, so anything
/// unreadable is dropped and history simply begins again.
final class UsageHistoryStore: @unchecked Sendable {
    static let shared = UsageHistoryStore()

    /// New samples closer together than this are noise: the vendor numbers move
    /// in whole percent steps and the refresh floor is 60s anyway.
    static let minimumGap: TimeInterval = 110
    /// Nothing older than this can appear on any sparkline (the longest window
    /// shown is seven days), so it is also where history ends.
    static let retention: TimeInterval = 7 * 86400
    /// Beyond the recent past, one sample per this interval is plenty for a
    /// 120pt sparkline; thinning is what keeps seven days bounded.
    static let thinnedGap: TimeInterval = 30 * 60
    /// Samples younger than this are never thinned, so short-window sparklines
    /// and the forecast fit keep full resolution.
    static let fullResolutionSpan: TimeInterval = 6 * 3600

    /// The fit window for the burn rate. Long enough to smooth out one refresh
    /// tick, short enough that "an hour ago" does not outvote "now".
    static let fitSpan: TimeInterval = 90 * 60
    /// A fit needs at least this much real time under it before a slope is
    /// worth reporting; three minutes of samples extrapolated to a 5h window is
    /// a guess wearing a number.
    static let minimumBasis: TimeInterval = 15 * 60
    /// A step down this large mid-series is a window reset; the fit never
    /// crosses one, because the slope across it would be negative nonsense.
    static let resetDrop: Double = 4

    private static let fileName = "usage-history"

    private let lock = NSLock()
    private var series: [String: [UsageSample]] = [:]

    private let loadLock = NSLock()
    private var loaded = false
    private let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
    }

    private static func key(_ providerID: String, _ windowLabel: String) -> String {
        "\(providerID)|\(windowLabel)"
    }

    // MARK: Recording

    /// Called after every refresh with whatever the store now shows. Only
    /// fresh readings are recorded: a provider answering from its snapshot
    /// cache re-reports an old number, and appending that at the current time
    /// would draw a plateau that never happened.
    func record(_ usages: [ProviderUsage], now: Date = Date()) {
        loadIfNeeded()
        var changed = false
        lock.lock()
        for usage in usages {
            guard now.timeIntervalSince(usage.asOf) < 120 else { continue }
            for window in usage.windows {
                guard let percent = window.consumedPercent else { continue }
                let key = UsageHistoryStore.key(usage.providerID, window.shortWindowLabel)
                var samples = series[key] ?? []
                if let last = samples.last {
                    let gap = now.timeIntervalSince(last.time)
                    // Skip a reading that adds nothing: too soon, and the value
                    // has not moved enough to redraw a pixel.
                    if gap < UsageHistoryStore.minimumGap,
                       abs(percent - last.consumedPercent) < 0.5 { continue }
                    if gap < 5 { continue }
                }
                samples.append(UsageSample(time: now, consumedPercent: percent))
                series[key] = thin(samples, now: now)
                changed = true
            }
        }
        let all = series
        lock.unlock()
        if changed, persists { persist(all) }
    }

    /// Fixture injection for snapshots and demos, replacing whatever is loaded.
    func seed(providerID: String, windowLabel: String, samples: [UsageSample]) {
        loadLock.lock()
        loaded = true
        loadLock.unlock()
        lock.lock()
        series[UsageHistoryStore.key(providerID, windowLabel)] = samples.sorted { $0.time < $1.time }
        lock.unlock()
    }

    // MARK: Reading

    func samples(providerID: String, windowLabel: String, since: Date) -> [UsageSample] {
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return (series[UsageHistoryStore.key(providerID, windowLabel)] ?? [])
            .filter { $0.time >= since }
    }

    /// Least-squares slope over the recent past, never across a reset.
    func forecast(providerID: String, windowLabel: String, now: Date = Date()) -> BurnForecast? {
        loadIfNeeded()
        lock.lock()
        let all = series[UsageHistoryStore.key(providerID, windowLabel)] ?? []
        lock.unlock()

        var fit: [UsageSample] = []
        for sample in all.reversed() {
            guard now.timeIntervalSince(sample.time) <= UsageHistoryStore.fitSpan else { break }
            if let newest = fit.last,
               sample.consumedPercent > newest.consumedPercent + UsageHistoryStore.resetDrop {
                // Walking backwards, a jump *up* means the window reset between
                // this sample and the one after it.
                break
            }
            fit.append(sample)
        }
        fit.reverse()

        guard let first = fit.first, let last = fit.last, fit.count >= 3 else { return nil }
        let basis = last.time.timeIntervalSince(first.time)
        guard basis >= UsageHistoryStore.minimumBasis else { return nil }

        // Plain least squares on (seconds since first, percent).
        let n = Double(fit.count)
        var sumT = 0.0, sumP = 0.0, sumTT = 0.0, sumTP = 0.0
        for sample in fit {
            let t = sample.time.timeIntervalSince(first.time)
            sumT += t
            sumP += sample.consumedPercent
            sumTT += t * t
            sumTP += t * sample.consumedPercent
        }
        let denominator = n * sumTT - sumT * sumT
        guard denominator > 0 else { return nil }
        let slopePerSecond = (n * sumTP - sumT * sumP) / denominator
        let perHour = slopePerSecond * 3600

        // Below this the fit is measuring jitter, not a pace.
        guard perHour > 0.2 else {
            return BurnForecast(ratePerHour: max(0, perHour), capETA: nil, basis: basis)
        }

        let secondsToCap = (100 - last.consumedPercent) / slopePerSecond
        return BurnForecast(ratePerHour: perHour,
                            capETA: last.time.addingTimeInterval(secondsToCap),
                            basis: basis)
    }

    // MARK: Retention

    /// Recent samples stay at full resolution; older ones are kept only when
    /// they are far enough apart to still contribute a pixel. Applied on every
    /// append so the series can never grow without bound.
    private func thin(_ samples: [UsageSample], now: Date) -> [UsageSample] {
        var out: [UsageSample] = []
        out.reserveCapacity(samples.count)
        var lastKept: Date?
        for sample in samples {
            let age = now.timeIntervalSince(sample.time)
            if age > UsageHistoryStore.retention { continue }
            if age > UsageHistoryStore.fullResolutionSpan, let kept = lastKept,
               sample.time.timeIntervalSince(kept) < UsageHistoryStore.thinnedGap {
                continue
            }
            out.append(sample)
            lastKept = sample.time
        }
        return out
    }

    // MARK: Persistence

    private func persist(_ series: [String: [UsageSample]]) {
        var payload: [String: Any] = [:]
        for (key, samples) in series {
            // Flat [t, p, t, p, ...] pairs: compact, and nothing here deserves
            // the ceremony of named fields.
            var flat: [Double] = []
            flat.reserveCapacity(samples.count * 2)
            for sample in samples {
                flat.append(sample.time.timeIntervalSince1970)
                flat.append((sample.consumedPercent * 10).rounded() / 10)
            }
            payload[key] = flat
        }
        CredentialStore.writeJSON(["series": payload], name: UsageHistoryStore.fileName)
    }

    private func loadIfNeeded() {
        guard persists else { return }
        loadLock.lock()
        defer { loadLock.unlock() }
        guard !loaded else { return }
        loaded = true

        guard let root = CredentialStore.readJSON(UsageHistoryStore.fileName),
              let stored = root["series"] as? [String: Any] else { return }

        var restored: [String: [UsageSample]] = [:]
        for (key, value) in stored {
            guard let flat = value as? [Any] else { continue }
            var samples: [UsageSample] = []
            samples.reserveCapacity(flat.count / 2)
            var index = 0
            while index + 1 < flat.count {
                if let t = JSONWalk.double(flat[index]), let p = JSONWalk.double(flat[index + 1]) {
                    samples.append(UsageSample(time: Date(timeIntervalSince1970: t),
                                               consumedPercent: min(100, max(0, p))))
                }
                index += 2
            }
            if !samples.isEmpty { restored[key] = samples }
        }

        lock.lock()
        // Anything recorded while the load was in flight is newer than the file.
        restored.merge(series) { disk, live in disk + live }
        series = restored
        lock.unlock()
    }
}
