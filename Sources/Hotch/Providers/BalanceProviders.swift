import Foundation

/// Shared plumbing for providers that meter prepaid credit through a simple
/// authenticated GET. Both DeepSeek and Moonshot (Kimi) publish documented
/// balance endpoints; neither has windowed subscription limits to show, so
/// these rows render a remaining balance instead of ring gauges.
enum BalanceFetch {
    struct Response {
        var statusCode: Int
        var root: Any?
    }

    static func get(_ url: URL, bearer key: String) async -> Response? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return Response(statusCode: http.statusCode, root: JSONWalk.object(data))
    }

    /// A row that tells the user to finish setup in settings.
    static func needsKey(id: String, name: String) -> ProviderUsage {
        ProviderUsage(providerID: id, displayName: name, windows: [], needsSetup: true)
    }

    /// A row that tells the user the stored key was rejected.
    static func badKey(id: String, name: String) -> ProviderUsage {
        ProviderUsage(providerID: id, displayName: name, windows: [],
                      detail: "API key rejected, check settings", needsSetup: true)
    }
}

/// DeepSeek platform credit. Documented endpoint:
/// GET https://api.deepseek.com/user/balance with a Bearer API key, answering
/// balance_infos[] of {currency, total_balance, granted_balance, topped_up_balance}.
struct DeepSeekProvider: UsageProvider {
    let id = "deepseek"
    let displayName = "DeepSeek"

    func fetch() async -> ProviderUsage? {
        guard let key = ProviderKeyStore.key(for: id) else {
            return BalanceFetch.needsKey(id: id, name: displayName)
        }
        guard let url = URL(string: "https://api.deepseek.com/user/balance"),
              let response = await BalanceFetch.get(url, bearer: key) else { return nil }
        if response.statusCode == 401 || response.statusCode == 403 {
            return BalanceFetch.badKey(id: id, name: displayName)
        }
        guard response.statusCode == 200,
              let root = response.root as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]],
              let info = infos.first,
              let total = JSONWalk.double(info["total_balance"]) else { return nil }

        let currency = JSONWalk.string(info["currency"]) ?? "USD"
        var detail: String?
        if let granted = JSONWalk.double(info["granted_balance"]), granted > 0 {
            detail = "\(Fmt.money(granted, currency: currency)) of it granted credit"
        }

        return ProviderUsage(providerID: id,
                             displayName: displayName,
                             windows: [],
                             detail: detail,
                             balance: ProviderBalance(amount: total, currency: currency))
    }
}

