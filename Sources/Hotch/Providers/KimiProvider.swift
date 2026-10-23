import Foundation

/// Kimi (Moonshot AI) usage, two shapes depending on what the user has:
///
/// 1. Kimi for Coding subscription: GET https://api.kimi.com/coding/v1/usages,
///    the same endpoint the official kimi-cli /usage screen reads. Works with
///    an sk-kimi-... coding key, or with the access token kimi-cli keeps in
///    ~/.kimi-code/credentials/kimi-code.json (older builds: ~/.kimi/credentials/;
///    read only, never refreshed from
///    here so the CLI's sign-in is never disturbed). Answers windowed limits,
///    which render as ring gauges like Claude and Codex.
/// 2. Platform API credit: GET /v1/users/me/balance on api.moonshot.ai (USD)
///    or api.moonshot.cn (CNY), documented, for plain platform keys. Renders
///    as a remaining balance.
struct KimiProvider: UsageProvider {
    let id = "kimi"
    let displayName = "Kimi"

    static let codingUsageEndpoint = "https://api.kimi.com/coding/v1/usages"
    static let balanceHosts: [(base: String, currency: String)] = [
        ("https://api.moonshot.ai", "USD"),
        ("https://api.moonshot.cn", "CNY"),
    ]

    /// Where kimi-cli keeps its sign-in, newest layout first. The CLI moved it
    /// from `~/.kimi/` to `~/.kimi-code/`; both are checked so either build's
    /// sign-in is found.
    static let cliCredsCandidates: [String] = [
        ".kimi-code/credentials/kimi-code.json",
        ".kimi/credentials/kimi-code.json",
    ]

    /// The first sign-in file that exists, or the current location when none
    /// does (so a message can name where it is expected).
    static var cliCredsURL: URL {
        let fm = FileManager.default
        for relative in cliCredsCandidates {
            let url = FS.home.appendingPathComponent(relative)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return FS.home.appendingPathComponent(cliCredsCandidates[0])
    }

    static var hasCLISignIn: Bool {
        FileManager.default.fileExists(atPath: cliCredsURL.path)
    }

    func fetch() async -> ProviderUsage? {
        if let key = ProviderKeyStore.key(for: id) {
            // Coding keys are windowed; anything else is a platform key.
            if key.hasPrefix("sk-kimi-") {
                if let usage = await fetchCodingUsage(bearer: key) { return usage }
                return BalanceFetch.badKey(id: id, name: displayName)
            }
            return await fetchBalance(key: key)
        }

        // No key stored: ride an existing kimi-cli sign-in when there is one.
        if let token = KimiProvider.cliAccessToken() {
            if let usage = await fetchCodingUsage(bearer: token) { return usage }
            return ProviderUsage(providerID: id, displayName: displayName, windows: [],
                                 detail: "Kimi CLI sign-in expired, run kimi again",
                                 needsSetup: true)
        }

        return BalanceFetch.needsKey(id: id, name: displayName)
    }

    /// kimi-cli's stored access token, read only.
    static func cliAccessToken() -> String? {
        guard let data = try? Data(contentsOf: cliCredsURL),
              let root = JSONWalk.object(data) as? [String: Any] else { return nil }
        return JSONWalk.string(root["access_token"])
            ?? JSONWalk.string(JSONWalk.findDictionary(containing: "access_token", in: root)?["access_token"])
    }

    // MARK: - Coding subscription windows

    private func fetchCodingUsage(bearer: String) async -> ProviderUsage? {
        guard let url = URL(string: KimiProvider.codingUsageEndpoint),
              let response = await BalanceFetch.get(url, bearer: bearer),
              response.statusCode == 200,
              let root = response.root as? [String: Any] else { return nil }

        let windows = KimiProvider.parseCodingLimits(root)
        guard !windows.isEmpty else { return nil }

        var detail: String?
        if let membership = JSONWalk.findDictionary(containing: "level", in: root["user"]),
           let level = JSONWalk.string(membership["level"]) {
            detail = "\(level.capitalized) plan"
        }

        return ProviderUsage(providerID: id,
                             displayName: displayName,
                             windows: windows,
                             detail: detail)
    }

    /// limits[] entries carry detail{limit, used, remaining, name, title} and
    /// window{duration, timeUnit}; the reset field spelling varies between
    /// deployments, so every known variant is tried.
    static func parseCodingLimits(_ root: [String: Any], now: Date = Date()) -> [UsageWindow] {
        guard let limits = root["limits"] as? [[String: Any]] else { return [] }

        var windows: [UsageWindow] = []
        for entry in limits {
            let detail = entry["detail"] as? [String: Any] ?? entry
            guard let limit = JSONWalk.double(detail["limit"]), limit > 0 else { continue }
            let used = JSONWalk.double(detail["used"])
                ?? JSONWalk.double(detail["remaining"]).map { limit - $0 }
            guard let used else { continue }

            let minutes = windowMinutes(entry["window"] as? [String: Any])
            let label = JSONWalk.string(detail["title"])
                ?? JSONWalk.string(detail["name"])
                ?? minutes.map { Fmt.windowLabel(minutes: $0) }
                ?? "Limit"

            windows.append(UsageWindow(
                label: label,
                usedPercent: min(100, max(0, used / limit * 100)),
                resetsAt: resetDate(in: entry, now: now) ?? resetDate(in: detail, now: now),
                windowMinutes: minutes
            ))
        }

        // Shorter window first, mirroring the session/weekly slots elsewhere.
        return windows.sorted { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
    }

    private static func windowMinutes(_ window: [String: Any]?) -> Int? {
        guard let window, let duration = JSONWalk.double(window["duration"]) else { return nil }
        let unit = (JSONWalk.string(window["timeUnit"]) ?? JSONWalk.string(window["time_unit"]) ?? "")
            .lowercased()
        let perUnit: Double
        if unit.contains("sec") { perUnit = 1.0 / 60 }
        else if unit.contains("min") { perUnit = 1 }
        else if unit.contains("hour") { perUnit = 60 }
        else if unit.contains("day") { perUnit = 1440 }
        else if unit.contains("week") { perUnit = 10080 }
        else if unit.contains("month") { perUnit = 43200 }
        else { return nil }
        return Int((duration * perUnit).rounded())
    }

    private static func resetDate(in dict: [String: Any], now: Date) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let date = DateParse.date(from: dict[key]) { return date }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = JSONWalk.double(dict[key]), seconds > 0 {
                return now.addingTimeInterval(seconds)
            }
        }
        return nil
    }

    // MARK: - Platform balance

    private func fetchBalance(key: String) async -> ProviderUsage? {
        var sawAuthFailure = false
        for host in KimiProvider.balanceHosts {
            guard let url = URL(string: "\(host.base)/v1/users/me/balance"),
                  let response = await BalanceFetch.get(url, bearer: key) else { continue }
            if response.statusCode == 401 || response.statusCode == 403 {
                sawAuthFailure = true
                continue
            }
            guard response.statusCode == 200,
                  let root = response.root as? [String: Any],
                  let data = root["data"] as? [String: Any],
                  let available = JSONWalk.double(data["available_balance"]) else { continue }

            var detail: String?
            if let voucher = JSONWalk.double(data["voucher_balance"]), voucher > 0 {
                detail = "\(Fmt.money(voucher, currency: host.currency)) of it vouchers"
            }

            return ProviderUsage(providerID: id,
                                 displayName: displayName,
                                 windows: [],
                                 detail: detail,
                                 balance: ProviderBalance(amount: available, currency: host.currency))
        }

        if sawAuthFailure {
            return BalanceFetch.badKey(id: id, name: displayName)
        }
        return nil
    }
}
