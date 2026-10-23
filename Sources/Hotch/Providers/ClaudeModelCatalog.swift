import Foundation

/// Claude Code's own model catalog cache, `~/.claude/cache/model-catalog/*.json`.
///
/// Each file is `{catalog: {config: {models: [{id, name, short_name, runtime:
/// {max_input_tokens}}]}}}`: the context window and the display name for every
/// model the CLI knows, as the server sent them. That replaces the hard-coded
/// window table for any model listed here, and gives the sessions page a name a
/// person would recognise ("Opus 5.5") instead of an id.
///
/// Read-only, and only these catalog files: the folder is a cache of public
/// model metadata, nothing in it is a credential.
enum ClaudeModelCatalog {
    struct Model: Sendable, Hashable {
        var id: String
        var name: String?
        var maxInputTokens: Int?
    }

    static var directory: URL {
        FS.home.appendingPathComponent(".claude/cache/model-catalog", isDirectory: true)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (models: [String: Model], newest: Date, checked: Date)?

    /// Every model in the newest catalog files, keyed by id. Re-read only when
    /// a file in the folder has changed, and checked at most once a minute.
    static func models(now: Date = Date()) -> [String: Model] {
        lock.lock()
        if let cache, now.timeIntervalSince(cache.checked) < 60 {
            lock.unlock()
            return cache.models
        }
        lock.unlock()

        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        let sorted = FS.sortedByRecency(files)
        let newest = sorted.first.map(FS.modificationDate) ?? .distantPast

        lock.lock()
        if let cache, cache.newest == newest {
            self.cache = (cache.models, newest, now)
            lock.unlock()
            return cache.models
        }
        lock.unlock()

        var models: [String: Model] = [:]
        // Oldest first, so the newest file's entry for an id wins.
        for file in sorted.prefix(8).reversed() {
            guard let data = try? Data(contentsOf: file),
                  let root = JSONWalk.object(data) as? [String: Any],
                  let catalog = root["catalog"] as? [String: Any],
                  let config = catalog["config"] as? [String: Any],
                  let list = config["models"] as? [[String: Any]] else { continue }
            for entry in list {
                guard let id = JSONWalk.string(entry["id"]) else { continue }
                let runtime = entry["runtime"] as? [String: Any]
                models[id] = Model(id: id,
                                   name: JSONWalk.string(entry["name"]),
                                   maxInputTokens: JSONWalk.int(runtime?["max_input_tokens"]))
            }
        }

        lock.lock()
        cache = (models, newest, now)
        lock.unlock()
        return models
    }

    /// The catalog entry for a transcript's model id, which may carry a
    /// context suffix ("claude-fable-5-1[1m]") or a date stamp the catalog
    /// lists without.
    static func model(for rawID: String?) -> Model? {
        guard var id = rawID?.lowercased(), !id.isEmpty else { return nil }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        let all = models()
        if let exact = all[id] { return exact }
        // "claude-opus-4-5-20251101" against a catalog listing "claude-opus-4-5".
        let parts = id.split(separator: "-")
        if let last = parts.last, last.count == 8, Int(last) != nil {
            return all[parts.dropLast().joined(separator: "-")]
        }
        return nil
    }

    /// "Opus 5.5" for "claude-opus-5-5": the catalog's own name when listed,
    /// otherwise derived from the id's family and version segments.
    static func displayName(for rawID: String?) -> String? {
        if let name = model(for: rawID)?.name, !name.isEmpty { return name }
        guard var id = rawID?.lowercased(), id.hasPrefix("claude-") else { return nil }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        let parts = id.split(separator: "-").dropFirst().map(String.init)
        guard let family = parts.first, Int(family) == nil else { return nil }
        let numbers = parts.dropFirst().filter { Int($0) != nil && $0.count < 4 }
        let version = numbers.joined(separator: ".")
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }
}
