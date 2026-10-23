import Foundation
import Security

/// Hotch's own storage for provider API keys, one file per provider in
/// `CredentialStore`. Same discipline as every credential path: Hotch only ever touches
/// secrets it created itself, and it keeps them somewhere an ad-hoc signed
/// rebuild cannot lock it out of. See CredentialStore for why not the Keychain.
enum ProviderKeyStore {
    private static func name(for providerID: String) -> String {
        "\(providerID)-api-key"
    }

    /// Legacy Keychain location, read once per launch and then removed.
    ///
    /// Deliberately still spelled "NotchPeek": this is the name the item was
    /// created under before the app was renamed, so changing it here would orphan
    /// a real key sitting in someone's keychain.
    private static func keychainService(for providerID: String) -> String {
        "NotchPeek-\(providerID)-APIKey"
    }

    private static let account = "api-key"

    static func key(for providerID: String) -> String? {
        if let key = CredentialStore.readString(name(for: providerID)) { return key }

        guard let migrated = CredentialStore.migrateFromKeychain(
            name: name(for: providerID),
            service: keychainService(for: providerID),
            account: account
        ) else { return nil }

        let key = String(data: migrated, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty == false) ? key : nil
    }

    @discardableResult
    static func store(_ key: String, for providerID: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard CredentialStore.writeString(trimmed, name: name(for: providerID)) else {
            hotchLog.error("Hotch API key store failed for \(providerID)")
            return false
        }
        return true
    }

    static func clear(for providerID: String) {
        CredentialStore.delete(name(for: providerID))
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService(for: providerID),
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    static func hasKey(for providerID: String) -> Bool {
        key(for: providerID) != nil
    }

    /// "sk-...c4f2" style hint for the settings status line. Never the key.
    static func redactedKey(for providerID: String) -> String? {
        guard let key = key(for: providerID) else { return nil }
        guard key.count > 8 else { return "••••" }
        return "\(key.prefix(3))…\(key.suffix(4))"
    }
}
