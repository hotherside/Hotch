import Foundation
import Security

/// Storage for the secrets Hotch owns: the provider API keys. (It used to hold
/// a Claude OAuth credential too; that is gone, and `ClaudeCodeBridge` deletes
/// the old file.)
///
/// Development builds adopted file storage because ad-hoc signatures change
/// with each rebuild. A Keychain ACL is bound to the code signature of the app
/// that created the item; those rebuilds produced a new cdhash and the recorded
/// ACL stopped matching. macOS then asked "Allow / Always Allow" again for an
/// item Hotch itself had created. File storage avoided those recurring prompts.
///
/// A 0600 file inside a 0700 directory avoids that rebuild-specific prompt and
/// protects against other unprivileged local users. This is plaintext storage:
/// software running as the signed-in user can read the keys. It does not provide
/// the per-application access controls of the Keychain. Release builds support
/// Developer ID signing, so a future storage migration can revisit Keychain
/// access with a stable signing identity.
enum CredentialStore {
    /// `~/Library/Application Support/Hotch`, created 0700 on first write.
    static var directory: URL {
        FS.home.appendingPathComponent("Library/Application Support/Hotch", isDirectory: true)
    }

    /// Folders this app used under its previous names, **newest first**.
    ///
    /// It has been renamed twice: NotchPeek → HojNotch → Hotch. Each rename
    /// changed the bundle identifier, which is what macOS keys the support folder
    /// off, so each one orphans the folder before it. Order matters: someone who
    /// used both earlier versions has both folders, and the HojNotch one holds the
    /// newer credential.
    static var legacyDirectories: [URL] {
        ["HojNotch", "NotchPeek"].map {
            FS.home.appendingPathComponent("Library/Application Support/\($0)", isDirectory: true)
        }
    }

    private static func url(for name: String) -> URL {
        directory.appendingPathComponent("\(name).json", isDirectory: false)
    }

    // MARK: - Rename migration

    private static let renameLock = NSLock()
    private static var renameChecked = false

    /// Moves the whole support folder over from the newest former name that has
    /// one.
    ///
    /// Without this, a rename tells an existing user to reconnect their Claude
    /// account while a perfectly good credential sits one directory away. A rename
    /// must not cost anyone their sign-in — and since this app has now been renamed
    /// twice, it must not cost it two versions later either.
    ///
    /// Runs before the first read, once per launch, and is a no-op on a clean
    /// install. Moved rather than copied so no second copy of a credential is left
    /// behind.
    static func migrateFromLegacyDirectoryIfNeeded() {
        renameLock.lock()
        defer { renameLock.unlock() }
        guard !renameChecked else { return }
        renameChecked = true

        let fm = FileManager.default
        // A current folder already existing means this Mac is migrated, or the
        // user connected fresh; either way nothing older is authoritative.
        guard !fm.fileExists(atPath: directory.path) else { return }
        guard let source = legacyDirectories.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return
        }

        do {
            try fm.createDirectory(at: directory.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: directory)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            hotchLog.log("migrated the support folder from \(source.lastPathComponent) to Hotch")
        } catch {
            hotchLog.error("support folder migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Reading and writing

    static func read(_ name: String) -> Data? {
        migrateFromLegacyDirectoryIfNeeded()
        guard let data = try? Data(contentsOf: url(for: name)), !data.isEmpty else { return nil }
        return data
    }

    @discardableResult
    static func write(_ data: Data, name: String) -> Bool {
        write(data, name: name, in: directory)
    }

    /// Explicit directory for the filesystem security check; production callers
    /// use the overload above. Never accepts a path supplied by a provider.
    @discardableResult
    static func write(_ data: Data, name: String, in directory: URL) -> Bool {
        let fm = FileManager.default
        guard !name.isEmpty, name.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return false }
        do {
            // 0700 first, so the atomic write below is never briefly readable
            // by another user even before the file mode is tightened.
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
            // Other stores or an older install may have created this folder
            // with broader permissions. Tighten it before the atomic write.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let target = directory.appendingPathComponent("\(name).json", isDirectory: false)
            try data.write(to: target, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch {
            hotchLog.error("credential store write failed for \(name): \(error.localizedDescription)")
            return false
        }
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    // MARK: - JSON convenience

    static func readJSON(_ name: String) -> [String: Any]? {
        guard let data = read(name) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @discardableResult
    static func writeJSON(_ object: [String: Any], name: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return write(data, name: name)
    }

    static func readString(_ name: String) -> String? {
        guard let data = read(name), let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    static func writeString(_ value: String, name: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return write(data, name: name)
    }

    // MARK: - Migration off the Keychain

    private static let migrationLock = NSLock()
    private static var migrationAttempted: Set<String> = []

    /// Lifts a secret Hotch previously stored in the Keychain into the file
    /// store, then deletes the Keychain item so nothing is left to prompt about.
    ///
    /// Attempted at most once per launch: the read itself can raise the very
    /// prompt this store exists to eliminate, and a user who dismisses it must
    /// not be asked again on the next refresh tick.
    static func migrateFromKeychain(name: String, service: String, account: String) -> Data? {
        migrationLock.lock()
        let alreadyTried = migrationAttempted.contains(name)
        migrationAttempted.insert(name)
        migrationLock.unlock()
        guard !alreadyTried else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, !data.isEmpty else {
            if status != errSecItemNotFound {
                hotchLog.debug("keychain migration for \(name) did not complete, status \(status)")
            }
            return nil
        }

        guard write(data, name: name) else { return data }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
        hotchLog.log("migrated \(name) out of the Keychain into the Hotch credential store")
        return data
    }
}
