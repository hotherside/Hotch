import Foundation

// MARK: - Models

/// What a metered window measures, decided by the vendor's own classification
/// (Claude's `limits[].kind`, Codex's `windowDurationMins`) rather than by a
/// label. Labels are for people; this is what code sorts and groups on.
enum WindowKind: String, Sendable, Hashable, CaseIterable {
    /// The short rolling window, five hours on both Claude and Codex.
    case session
    /// The plan-wide weekly window.
    case week
    /// A weekly window that applies to one model or surface only ("Fable
    /// week"). `UsageWindow.scope` names what it is scoped to.
    case weekScoped
    /// A daily window (Kimi, older plans).
    case day
    /// Anything else a vendor reports.
    case other

    /// Best guess for a window built without an explicit kind. The window
    /// length decides when it is known; the label only when it is not.
    static func infer(windowMinutes: Int?, label: String) -> WindowKind {
        if let minutes = windowMinutes, minutes > 0 {
            if minutes <= 12 * 60 { return .session }
            if minutes <= 36 * 60 { return .day }
            if minutes >= 6 * 1440 && minutes <= 8 * 1440 {
                return WindowKind.labelLooksScoped(label) ? .weekScoped : .week
            }
            return .other
        }
        let lower = label.lowercased()
        if lower.hasPrefix("session") || lower == "5h" { return .session }
        if lower.hasPrefix("daily") || lower == "1d" || lower == "day" { return .day }
        if lower.contains("week") || lower == "7d" {
            return WindowKind.labelLooksScoped(label) ? .weekScoped : .week
        }
        return .other
    }

    /// "Weekly (Opus)", "Fable week": a weekly label carrying more than the
    /// word itself is scoped to something.
    private static func labelLooksScoped(_ label: String) -> Bool {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        let bare: Set<String> = ["week", "weekly", "7d", "7 day", "7-day", "seven day"]
        if lower.isEmpty || bare.contains(lower) { return false }
        return lower.contains("(") || !lower.hasPrefix("week")
    }
}

/// One metered window of a subscription, always expressed as a share of the
/// plan. Token counts ride along for detail but are never the headline: the
/// panel reports how much of the window is left, in one unit, everywhere.
struct UsageWindow: Sendable, Hashable {
    var label: String
    var usedPercent: Double?
    var usedTokens: Int?
    var resetsAt: Date?
    var windowMinutes: Int?
    /// What the window measures. Inferred from `windowMinutes` and `label`
    /// when a provider does not say.
    var kind: WindowKind
    /// For `.weekScoped`, what the window is scoped to, in the vendor's own
    /// words ("Fable", "Opus"). Nil for plan-wide windows.
    var scope: String?

    init(label: String,
         usedPercent: Double? = nil,
         usedTokens: Int? = nil,
         resetsAt: Date? = nil,
         windowMinutes: Int? = nil,
         kind: WindowKind? = nil,
         scope: String? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.usedTokens = usedTokens
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.kind = kind ?? WindowKind.infer(windowMinutes: windowMinutes, label: label)
        self.scope = scope
    }
}

extension UsageWindow: Identifiable {
    var id: String { label }
}

extension UsageWindow {
    /// The number the UI shows: how much of the subscription window has been
    /// consumed.
    ///
    /// Clamped here rather than trusted from the providers, so one place
    /// guarantees the 0...100 range whatever a vendor reports.
    ///
    /// The panel used to report the complement of this ("59% left"). Used is what
    /// every vendor's own dashboard shows, and it is the direction that matches a
    /// meter filling up, so a ring that grows is unambiguously bad news instead of
    /// needing a caption to say which way round it reads.
    var consumedPercent: Double? {
        guard let usedPercent else { return nil }
        return min(100, max(0, usedPercent))
    }

    /// Compact axis style label for the ring caption, "5h" or "7d".
    ///
    /// Also the key the usage history files a window under, so it has to be
    /// unique per provider: a scoped weekly window carries its scope ("7d
    /// Fable"), otherwise it would share a series with the plan-wide week.
    var shortWindowLabel: String {
        let base: String
        if let minutes = windowMinutes, minutes > 0 {
            base = Fmt.windowLabel(minutes: minutes)
        } else {
            switch kind {
            case .session: base = "5h"
            case .week, .weekScoped: base = "7d"
            case .day: base = "1d"
            case .other: base = label
            }
        }
        if kind == .weekScoped {
            let qualifier = scope ?? label
            return qualifier.isEmpty ? base : "\(base) \(qualifier)"
        }
        return base
    }
}

/// Remaining prepaid credit, for providers that meter money instead of
/// windowed percentages (DeepSeek, Kimi).
struct ProviderBalance: Sendable, Hashable {
    var amount: Double
    /// ISO currency code, e.g. "USD" or "CNY".
    var currency: String
}

struct ProviderUsage: Sendable, Hashable {
    var providerID: String
    var displayName: String
    var windows: [UsageWindow]
    var asOf: Date
    var detail: String?
    /// Credit-metered providers report a balance instead of windows.
    var balance: ProviderBalance?
    /// True when the provider cannot fetch anything until the user finishes
    /// setup in settings (e.g. no API key stored yet).
    var needsSetup: Bool
    /// The subscription the numbers belong to, already in display form
    /// ("Max", "Pro lite"). Nil when the vendor did not say.
    var plan: String?
    /// Short secondary facts about the account that are not windows: "Extra
    /// usage $12.40 of $50", "2 reset credits". Display order.
    var extras: [String]

    init(providerID: String,
         displayName: String,
         windows: [UsageWindow],
         asOf: Date = Date(),
         detail: String? = nil,
         balance: ProviderBalance? = nil,
         needsSetup: Bool = false,
         plan: String? = nil,
         extras: [String] = []) {
        self.providerID = providerID
        self.displayName = displayName
        self.windows = windows
        self.asOf = asOf
        self.detail = detail
        self.balance = balance
        self.needsSetup = needsSetup
        self.plan = plan
        self.extras = extras
    }
}

extension ProviderUsage: Identifiable {
    var id: String { providerID }
}

protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func fetch() async -> ProviderUsage?
}

// MARK: - Sorting

enum WindowRank {
    /// Session first, the plan-wide week second, scoped weeks after it, then
    /// everything else, so that the two main meters always land in the same
    /// visual slots. Ranked on `kind`, never on a label.
    static func rank(_ window: UsageWindow) -> Int {
        switch window.kind {
        case .session: return 0
        case .week: return 1
        case .weekScoped: return 2
        case .day: return 3
        case .other: return 4
        }
    }

    static func sorted(_ windows: [UsageWindow]) -> [UsageWindow] {
        windows.enumerated()
            .sorted { lhs, rhs in
                let a = rank(lhs.element), b = rank(rhs.element)
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map(\.element)
    }
}

// MARK: - Plan names

/// Turns a vendor's plan identifier into the words a person would use.
///
/// Both vendors send machine strings — Claude Code says `max`, Codex says
/// `prolite` — and the panel used to print them with only the first letter
/// raised ("Prolite plan"). Known ids get their real name; anything new is
/// split on underscores and capitalised, which is always readable even when it
/// is not quite the marketing name.
enum PlanName {
    static let known: [String: String] = [
        // Claude Code subscription_type
        "pro": "Pro", "max": "Max", "team": "Team", "enterprise": "Enterprise",
        "free": "Free",
        // Codex PlanType
        "plus": "Plus", "prolite": "Pro lite", "promax": "Pro max", "go": "Go",
        "business": "Business", "edu": "Edu", "edu_plus": "Edu Plus",
        "edu_pro": "Edu Pro",
        "self_serve_business_prolite": "Business Pro lite",
        "self_serve_business_usage_based": "Business",
        "enterprise_cbp_automation": "Enterprise", "enterprise_cbp_usage_based": "Enterprise",
        "ent26": "Enterprise",
    ]

    static func display(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              raw.lowercased() != "unknown" else { return nil }
        if let name = known[raw.lowercased()] { return name }
        let words = raw.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        guard let first = words.first else { return nil }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return ([head] + words.dropFirst().map(String.init)).joined(separator: " ")
    }
}

// MARK: - Store

@MainActor
final class UsageStore: ObservableObject {
    @Published var usages: [ProviderUsage] = []
    @Published var lastRefresh: Date?
    @Published var isRefreshing: Bool = false

    private let providers: [any UsageProvider]
    private let settings: AppSettings?
    private var autoRefreshTimer: Timer?
    private var inFlight: Task<Void, Never>?

    init(providers: [any UsageProvider], settings: AppSettings? = nil) {
        self.providers = providers
        self.settings = settings
        self.usages = providers
            .filter { settings?.isEnabled($0.id) ?? true }
            .map { ProviderUsage(providerID: $0.id, displayName: $0.displayName, windows: []) }
    }

    /// Providers the user has not switched off in settings.
    private var activeProviders: [any UsageProvider] {
        providers.filter { settings?.isEnabled($0.id) ?? true }
    }

    /// Reshapes `usages` to a new enabled set immediately, keeping whatever
    /// data is already loaded, then refreshes. The set is passed in because
    /// callers react to the settings publisher, which fires before the
    /// property itself is written.
    func applyProviderFilter(enabledIDs: Set<String>) {
        let active = providers.filter { enabledIDs.contains($0.id) }
        usages = active.map { provider in
            usages.first { $0.providerID == provider.id }
                ?? ProviderUsage(providerID: provider.id, displayName: provider.displayName, windows: [])
        }
        requestRefresh()
    }

    deinit {
        autoRefreshTimer?.invalidate()
    }

    func startAutoRefresh(interval: TimeInterval = 60) {
        autoRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.requestRefresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoRefreshTimer = timer
    }

    /// Fire and forget refresh, coalescing overlapping requests.
    func requestRefresh() {
        if isRefreshing { return }
        inFlight?.cancel()
        inFlight = Task { [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        isRefreshing = true
        let providers = self.activeProviders
        let fetched: [String: ProviderUsage] = await withTaskGroup(of: ProviderUsage?.self) { group in
            for provider in providers {
                group.addTask {
                    await UsageStore.fetch(provider, timeout: 5)
                }
            }
            var map: [String: ProviderUsage] = [:]
            for await result in group {
                if let result { map[result.providerID] = result }
            }
            return map
        }

        let previous = Dictionary(uniqueKeysWithValues: usages.map { ($0.providerID, $0) })
        usages = providers.map { provider in
            if var usage = fetched[provider.id] {
                usage.windows = WindowRank.sorted(usage.windows)
                return usage
            }
            // A fetch that timed out or errored keeps whatever the row was
            // already showing. Blanking it makes the panel flicker between real
            // numbers and "no recent data" on any transient failure, and the
            // row's own staleness caption already tells the truth about age.
            if let last = previous[provider.id], !last.windows.isEmpty || last.balance != nil {
                return last
            }
            return ProviderUsage(providerID: provider.id, displayName: provider.displayName, windows: [])
        }
        lastRefresh = Date()
        isRefreshing = false

        // Every fresh reading also lands in the history that feeds the forecast
        // page. Off the main actor: it is a file write, and the panel may be
        // mid-animation.
        let recorded = usages
        Task.detached(priority: .utility) {
            UsageHistoryStore.shared.record(recorded)
        }
    }

    /// Races a provider fetch against a timeout so one slow source cannot hold
    /// up the whole panel.
    private static func fetch(_ provider: any UsageProvider, timeout: TimeInterval) async -> ProviderUsage? {
        await withTaskGroup(of: ProviderUsage?.self) { group in
            group.addTask { await provider.fetch() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Highest consumed percentage across every provider window: the fullest
    /// window, which is what actually constrains the user. The menu bar shows this
    /// one, or its complement, depending on the display mode — either way it is
    /// this window that is reported, so the two modes never point at different
    /// subscriptions.
    var highestConsumedPercent: Double? {
        usages.flatMap { $0.windows.compactMap(\.consumedPercent) }.max()
    }
}
