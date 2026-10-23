import Foundation
import os

let hotchLog = Logger(subsystem: "com.hojaejung.hotch", category: "hotch")

// MARK: - Line by line file reading

/// Byte level substring search, used to reject uninteresting JSONL lines before
/// paying for UTF-8 decoding. Transcript lines can be hundreds of kilobytes.
enum Bytes {
    static func pattern(_ string: String) -> [UInt8] { Array(string.utf8) }

    static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        let count = data.count
        let length = needle.count
        guard length > 0, count >= length else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            let first = needle[0]
            var i = 0
            while i <= count - length {
                if base[i] == first {
                    var j = 1
                    while j < length, base[i + j] == needle[j] { j += 1 }
                    if j == length { return true }
                }
                i += 1
            }
            return false
        }
    }
}

/// Streams a text file one line at a time so that very large JSONL logs never
/// have to be resident in memory all at once.
enum LineReader {
    /// Calls `body` for every non empty line, as raw bytes. Return `false` from
    /// `body` to stop early.
    static func forEachLineData(atPath path: String,
                                maxBytes: Int = 96 * 1024 * 1024,
                                _ body: (Data) -> Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        var consumed = 0
        let chunkSize = 1 << 16

        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            consumed += chunk.count
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if !lineData.isEmpty, !body(lineData) { return }
            }
            if consumed >= maxBytes { break }
        }

        if !buffer.isEmpty {
            _ = body(buffer)
        }
    }

    /// Convenience wrapper that decodes every line. Prefer `forEachLineData`
    /// plus a `Bytes.contains` gate when most lines are uninteresting.
    static func forEachLine(atPath path: String,
                            maxBytes: Int = 96 * 1024 * 1024,
                            _ body: (String) -> Bool) {
        forEachLineData(atPath: path, maxBytes: maxBytes) { data in
            guard let line = String(data: data, encoding: .utf8) else { return true }
            return body(line)
        }
    }

    /// Returns the complete lines contained in the final `maxBytes` of a file,
    /// oldest first. The leading partial line is dropped.
    static func tailLines(atPath path: String, maxBytes: Int = 8 * 1024 * 1024) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }

        let readSize = UInt64(min(Int(size), maxBytes))
        let offset = size - readSize
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}

// MARK: - Filesystem helpers

enum FS {
    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Recursively collects files with the given extension under `root`.
    /// `limit` caps the number of directory entries visited so a pathological
    /// tree can never stall the UI.
    static func files(under root: URL,
                      pathExtension: String,
                      limit: Int = 20_000) -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let e = fm.enumerator(at: root,
                                    includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var out: [URL] = []
        var visited = 0
        for case let url as URL in e {
            visited += 1
            if visited > limit { break }
            guard url.pathExtension == pathExtension else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            out.append(url)
        }
        return out
    }

    static func modificationDate(_ url: URL) -> Date {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return v?.contentModificationDate ?? .distantPast
    }

    /// Newest first, optionally trimmed to `limit` entries.
    static func sortedByRecency(_ urls: [URL], limit: Int? = nil) -> [URL] {
        let sorted = urls.sorted { modificationDate($0) > modificationDate($1) }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }
}

// MARK: - Defensive JSON helpers

enum JSONWalk {
    static func object(_ line: String) -> Any? {
        guard let data = line.data(using: .utf8) else { return nil }
        return object(data)
    }

    static func object(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func double(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    static func string(_ any: Any?) -> String? {
        any as? String
    }

    /// Depth limited recursive search for the first dictionary stored under `key`
    /// that also satisfies `matching`.
    static func findDictionary(named key: String,
                               in any: Any?,
                               depth: Int = 0,
                               matching: ([String: Any]) -> Bool) -> [String: Any]? {
        guard depth < 12 else { return nil }
        if let dict = any as? [String: Any] {
            if let candidate = dict[key] as? [String: Any], matching(candidate) {
                return candidate
            }
            for (_, value) in dict {
                if let found = findDictionary(named: key, in: value, depth: depth + 1, matching: matching) {
                    return found
                }
            }
        } else if let array = any as? [Any] {
            for value in array {
                if let found = findDictionary(named: key, in: value, depth: depth + 1, matching: matching) {
                    return found
                }
            }
        }
        return nil
    }

    /// Depth limited recursive search for the first dictionary that contains `key`.
    static func findDictionary(containing key: String, in any: Any?, depth: Int = 0) -> [String: Any]? {
        guard depth < 12 else { return nil }
        if let dict = any as? [String: Any] {
            if dict[key] != nil { return dict }
            for (_, value) in dict {
                if let found = findDictionary(containing: key, in: value, depth: depth + 1) { return found }
            }
        } else if let array = any as? [Any] {
            for value in array {
                if let found = findDictionary(containing: key, in: value, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}

// MARK: - Where a small JSON file lives

/// One of Hotch's own hand-encoded JSON files, and where it is kept.
///
/// Three cases rather than a `persists` flag, because the third one is what
/// makes a file format testable at all: `--check-focus` needs to write a log,
/// throw the store away, rebuild it from the same file and prove that a run
/// whose line never closed comes back as a finished entry — all without going
/// anywhere near the user's support folder. The lesson from
/// `FocusStore(persists:)` is that a verification mode must not have side
/// effects on the thing it verifies, and a file is a side effect.
enum JSONFile: Sendable {
    case memory
    /// Beside `last-usage.json` in Hotch's own 0600 folder. Not a secret —
    /// task names and times, the same custody as the focus log itself.
    case credentialStore(name: String)
    /// A path chosen by the caller. Only the check modes pass this.
    case scratch(URL)

    func read() -> [String: Any]? {
        switch self {
        case .memory:
            return nil
        case .credentialStore(let name):
            return CredentialStore.readJSON(name)
        case .scratch(let url):
            guard let data = try? Data(contentsOf: url) else { return nil }
            return JSONWalk.object(data) as? [String: Any]
        }
    }

    func write(_ object: [String: Any]) {
        switch self {
        case .memory:
            break
        case .credentialStore(let name):
            CredentialStore.writeJSON(object, name: name)
        case .scratch(let url):
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    func delete() {
        switch self {
        case .memory:
            break
        case .credentialStore(let name):
            CredentialStore.delete(name)
        case .scratch(let url):
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - JWT

enum JWT {
    /// Decodes the payload claims of a JWT without verifying the signature.
    /// Read-only introspection of a token the user already holds locally.
    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return JSONWalk.object(data) as? [String: Any]
    }
}

// MARK: - Dates

enum DateParse {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Accepts ISO8601 strings (with or without fractional seconds) plus epoch
    /// seconds or epoch milliseconds expressed as a number or numeric string.
    static func date(from any: Any?) -> Date? {
        if let s = any as? String {
            if let d = isoFractional.date(from: s) { return d }
            if let d = iso.date(from: s) { return d }
            if let v = Double(s) { return epoch(v) }
            return nil
        }
        if let n = any as? NSNumber { return epoch(n.doubleValue) }
        return nil
    }

    static func epoch(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        // Anything past the year ~5138 in seconds is almost certainly milliseconds.
        return value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000)
                                       : Date(timeIntervalSince1970: value)
    }
}

// MARK: - Formatting

enum Fmt {
    static func percent(_ value: Double) -> String {
        let clamped = min(100, max(0, value))
        return "\(Int(clamped.rounded()))%"
    }

    /// "$12.34" / "¥46.58" style compact money, for balance rows.
    static func money(_ amount: Double, currency: String) -> String {
        let symbols = ["USD": "$", "CNY": "¥", "EUR": "€", "GBP": "£"]
        let value = (amount * 100).rounded() / 100
        let digits = value == value.rounded() ? 0 : 2
        let number = String(format: "%.\(digits)f", value)
        if let symbol = symbols[currency.uppercased()] {
            return "\(symbol)\(number)"
        }
        return "\(number) \(currency)"
    }

    /// "resets 2h 14m" style compact countdown.
    static func countdown(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resets now" }
        return "resets " + duration(seconds)
    }

    /// Bare "2h 14m" countdown for tight captions.
    static func remaining(to date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        return duration(seconds)
    }

    /// "32s ago" style compact age.
    static func ago(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        return duration(seconds) + " ago"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours < 24 {
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        let days = hours / 24
        let hoursRemainder = hours % 24
        return hoursRemainder == 0 ? "\(days)d" : "\(days)d \(hoursRemainder)h"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "5:42 PM" (or "17:42", following the system), for forecast arrival times.
    /// A wall-clock moment, not a countdown: "hits the cap at 5:42" is the
    /// number someone plans an evening around.
    static func clockTime(_ date: Date) -> String {
        clock.string(from: date)
    }

    /// "842", "94.1k", "312k", "1.20M". The decimal is dropped once it would
    /// read as ".0" — a context caption saying "312.0k used" spends a character
    /// on a digit that is never anything but zero.
    static func tokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 {
            // Rounded to the digit that will actually be printed, so 312_040
            // is caught as "312k" rather than slipping through as "312.0k".
            let thousands = (Double(count) / 100).rounded() / 10
            return thousands == thousands.rounded() ? "\(Int(thousands))k"
                                                    : String(format: "%.1fk", thousands)
        }
        return String(format: "%.2fM", Double(count) / 1_000_000)
    }

    /// "five_hour" -> "Five Hour"
    static func humanize(key: String) -> String {
        let parts = key.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard !parts.isEmpty else { return key }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func windowLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}
