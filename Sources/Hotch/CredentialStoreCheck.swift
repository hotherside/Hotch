import Foundation

/// Exercises actual filesystem permissions using synthetic data in a temporary
/// directory. Never opens a user's credentials or Keychain.
enum CredentialStoreCheck {
    static func runBlockingAndExit() -> Never {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("hotch-credential-check-\(UUID().uuidString)")
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            print("  \(condition ? "ok  " : "FAIL")  \(label)")
            if !condition { failures += 1 }
        }
        func mode(_ url: URL) -> Int? {
            (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let store = scratch.appendingPathComponent("existing")
            try fm.createDirectory(at: store, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o755])
            let sample = Data("synthetic-test-value".utf8)
            check("writes to an existing folder", CredentialStore.write(sample, name: "test-api-key", in: store))
            let target = store.appendingPathComponent("test-api-key.json")
            check("tightens an existing folder to 0700", mode(store) == 0o700)
            check("stores the file with mode 0600", mode(target) == 0o600)
            check("preserves the expected bytes", (try? Data(contentsOf: target)) == sample)
            check("rejects traversal names", !CredentialStore.write(sample, name: "../escaped", in: store))
            check("traversal creates no file outside the store", !fm.fileExists(atPath: scratch.appendingPathComponent("escaped.json").path))
            let link = scratch.appendingPathComponent("linked")
            try fm.createSymbolicLink(at: link, withDestinationURL: store)
            check("rejects a symbolic-link store directory", !CredentialStore.write(sample, name: "linked-key", in: link))
            let fresh = scratch.appendingPathComponent("fresh")
            check("creates a new store", CredentialStore.write(sample, name: "new-key", in: fresh))
            check("creates the directory with mode 0700", mode(fresh) == 0o700)
        } catch {
            failures += 1
            print("  FAIL  filesystem check: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: scratch)
        print("credential storage: \(failures == 0 ? "passed" : "failed")")
        exit(failures == 0 ? 0 : 1)
    }
}
