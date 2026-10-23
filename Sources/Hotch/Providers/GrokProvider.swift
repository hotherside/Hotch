import Foundation

/// xAI prepaid credit through the documented Management API:
/// GET https://management-api.x.ai/v1/billing/teams/{team_id}/prepaid/balance
/// authorized with a *management* key (Console -> Settings -> Management Keys,
/// billing read scope). The regular inference API exposes no usage numbers,
/// and SuperGrok consumer quota is not queryable at all, so this is the one
/// honest data source xAI offers.
///
/// The response shape is not publicly documented, so amounts are extracted
/// defensively and the raw payload is logged at debug level for verification.
struct GrokProvider: UsageProvider {
    let id = "grok"
    let displayName = "Grok"

    /// Team ID lives in UserDefaults (it is not a secret); the management key
    /// lives in Hotch's own 0600 key file (see ProviderKeyStore).
    static let teamIDDefaultsKey = "grokTeamID"

    static var teamID: String? {
        let value = UserDefaults.standard.string(forKey: teamIDDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    func fetch() async -> ProviderUsage? {
        guard let key = ProviderKeyStore.key(for: id), let team = GrokProvider.teamID else {
            return ProviderUsage(providerID: id, displayName: displayName, windows: [],
                                 detail: "add a management key + team ID in Settings",
                                 needsSetup: true)
        }
        guard let url = URL(string: "https://management-api.x.ai/v1/billing/teams/\(team)/prepaid/balance"),
              let response = await BalanceFetch.get(url, bearer: key) else { return nil }
        if response.statusCode == 401 || response.statusCode == 403 {
            return BalanceFetch.badKey(id: id, name: displayName)
        }
        guard response.statusCode == 200, let root = response.root else { return nil }

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            hotchLog.debug("grok prepaid balance payload: \(text)")
        }

        guard let amount = GrokProvider.extractDollars(from: root) else {
            return ProviderUsage(providerID: id, displayName: displayName, windows: [],
                                 detail: "balance response not understood")
        }

        return ProviderUsage(providerID: id,
                             displayName: displayName,
                             windows: [],
                             balance: ProviderBalance(amount: amount, currency: "USD"))
    }

    /// Walks the payload for the first plausible balance field. Keys that
    /// mention cents are divided down; everything else is taken as dollars.
    static func extractDollars(from root: Any?) -> Double? {
        let candidates = ["prepaid_balance_cents", "balance_cents", "cents",
                          "prepaid_balance", "available_balance", "balance", "amount"]
        for key in candidates {
            guard let owner = JSONWalk.findDictionary(containing: key, in: root),
                  let value = JSONWalk.double(owner[key]) else { continue }
            return key.contains("cent") ? value / 100 : value
        }
        return nil
    }
}
