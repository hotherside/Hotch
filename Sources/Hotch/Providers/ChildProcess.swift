import Foundation

/// Plumbing shared by the two vendor CLIs Hotch talks to over stdio: Claude
/// Code (`claude -p` in stream-json mode) and Codex (`codex app-server`).
///
/// Both are newline-delimited JSON on a pipe, both have to be found on absolute
/// paths because an `LSUIElement` app inherits almost no PATH, and both must be
/// killable by a watchdog so a hung child can never wedge a refresh.
enum ChildProcess {
    /// The environment a vendor CLI is started with.
    ///
    /// Starts from Hotch's own environment and then removes the variables that
    /// would make the child believe it is running *inside* another session.
    /// Running `--diag` from a Claude Code terminal is the case that matters:
    /// without this the child inherits `CLAUDECODE=1` and that session's
    /// entrypoint and IDE port, and registers itself as part of it.
    ///
    /// PATH gets the binary's own directory and the usual install prefixes, so
    /// an npm-installed CLI whose first line is `#!/usr/bin/env node` can find
    /// the node that installed it.
    ///
    /// PWD is set to `directory`, the folder the child really starts in: pass
    /// the process's `currentDirectoryURL` once it is set. `Process` moves the
    /// working directory without touching PWD, and a Hotch opened with `open`
    /// from a shell (`make run` does exactly that) carries the folder that
    /// shell was in. Claude Code's `-p` mode opens the folder PWD names, so a
    /// project under ~/Desktop or ~/Documents raised macOS's folder access
    /// prompt in Hotch's name within two seconds of a first launch.
    static func environment(binary: URL, directory: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                    "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_SESSION_ID"] {
            env[key] = nil
        }
        env["PWD"] = directory?.path
        env["OLDPWD"] = nil
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"

        var path: [String] = [binary.deletingLastPathComponent().path,
                              binary.resolvingSymlinksInPath().deletingLastPathComponent().path,
                              "/opt/homebrew/bin", "/usr/local/bin"]
        path += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        path += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        env["PATH"] = path.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// Ends a child for certain: SIGTERM, then SIGKILL if it is still there a
    /// moment later. A Bun-built CLI can catch SIGTERM and then block flushing
    /// a pipe, and a reader waiting on its stdout only gives up once it exits.
    static func stop(_ process: Process, grace: TimeInterval = 1) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Runs blocking child-process work on an ordinary dispatch thread, never
    /// on Swift's cooperative pool, which a blocked `read` would otherwise
    /// hold hostage for the whole watchdog interval.
    static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Writes one JSON object as a line. False when the child has gone.
    @discardableResult
    static func send(_ object: [String: Any], to pipe: Pipe) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            hotchLog.debug("child process write failed: \(error.localizedDescription)")
            return false
        }
    }
}

/// Collects a child's stderr in the background, capped, so a chatty child can
/// never block on a full pipe and the tail is still there to explain a failure.
final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let cap: Int

    init(pipe: Pipe, cap: Int = 16 * 1024) {
        self.cap = cap
        // The end-of-file check comes before anything that can bail out. At
        // EOF `availableData` returns empty on every call and the handler keeps
        // firing until it is cleared, so a handler that returned early without
        // clearing itself (the collector already released, as when a caller
        // discards it with `_ =`) spun forever on Foundation's one shared
        // file-handle queue. That starved every other pipe's handler, so the
        // next child's stderr filled, the child blocked writing to it, and it
        // never answered. Drain regardless of `self`, so a child is never left
        // blocked on a full pipe either.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.lock()
            if self.buffer.count < self.cap {
                self.buffer.append(chunk.prefix(self.cap - self.buffer.count))
            }
            self.lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Reads newline-delimited JSON from a pipe, keeping any partial trailing line
/// buffered between calls. Returns nil once the pipe closes, which is how a
/// watchdog's `terminate()` gets the waiting reader to give up.
final class JSONLineStream {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.isEmpty { continue }
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer = Data()
                return line
            }
            buffer.append(chunk)
        }
    }

    /// The next line that decodes to a JSON object, skipping anything else.
    func nextObject() -> [String: Any]? {
        while let line = nextLine() {
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    /// JSON-RPC: skips the notifications the server interleaves with replies
    /// and returns the object carrying the requested id. Nil on an error reply
    /// or a closed pipe.
    func waitForResponse(id: Int) -> [String: Any]? {
        while let object = nextObject() {
            guard JSONWalk.int(object["id"]) == id, object["method"] == nil else { continue }
            if let error = object["error"] as? [String: Any] {
                hotchLog.debug("app-server error for id \(id): \(String(describing: error["message"]))")
                return nil
            }
            return object
        }
        return nil
    }
}

/// Dotted version strings compared numerically, so 2.1.299 beats 2.1.77.
/// Pre-release suffixes ("0.162.0-alpha.17") compare on their numeric head.
enum SemVer {
    static func components(_ version: String) -> [Int] {
        let head = version.split(separator: "-").first.map(String.init) ?? version
        return head.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = components(lhs), b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// First dotted run of digits in a string, e.g. a version inside a path.
    static func find(in text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?"#,
                                     options: .regularExpression) else { return nil }
        return String(text[range])
    }
}
