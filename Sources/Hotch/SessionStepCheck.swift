import Foundation

/// `--check-session-steps`: the current-step reading against hand-built
/// transcript tails. No session files are read.
enum SessionStepCheck {
    static func runBlockingAndExit() -> Never {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("  \(passed ? "ok  " : "FAIL")  \(name)")
            if !passed { failures += 1 }
        }
        func line(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        func call(_ id: String, _ name: String, _ input: [String: Any],
                  at time: String = "2026-10-31T01:00:00.000Z", sidechain: Bool = false) -> Data {
            line(["type": "assistant", "timestamp": time, "isSidechain": sidechain,
                  "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
        }
        func result(_ id: String) -> Data {
            line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id]]]])
        }
        func thinking() -> Data {
            line(["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "…"]]]])
        }
        func prompt(_ text: String) -> Data {
            line(["type": "user", "message": ["content": text]])
        }
        func meta() -> Data {
            line(["type": "user", "isMeta": true, "message": ["content": [["type": "text", "text": "reminder"]]]])
        }
        let bash = call("a", "Bash", ["command": "swift build -c release", "description": "Build the app"])

        let running = SessionScanner.claudeStep(lines: [prompt("go"), bash])
        check("an open Bash call names itself by its description", running?.label == "Build the app")
        check("an open Bash call keeps its command", running?.command == "swift build -c release")
        check("the step's timer starts at the call", running?.startedAt != nil)

        let undescribed = SessionScanner.claudeStep(lines: [call("a", "Bash", ["command": "ls\n  -la"])])
        check("a Bash call without a description falls back to its command",
              undescribed?.label == "ls -la" && undescribed?.command == "ls -la")

        check("an answered call is not the current step",
              SessionScanner.claudeStep(lines: [bash, result("a")]) == nil)
        check("the model thinking between calls has no step",
              SessionScanner.claudeStep(lines: [bash, result("a"), thinking()]) == nil)

        let parallel = SessionScanner.claudeStep(lines: [
            call("a", "Bash", ["command": "make check"]),
            call("b", "Read", ["file_path": "/tmp/x/Package.swift"]),
            result("b")
        ])
        check("an older open call survives a newer answered one", parallel?.command == "make check")

        check("a call before the person's last prompt is not current",
              SessionScanner.claudeStep(lines: [bash, prompt("stop")]) == nil)
        check("injected context does not end the turn",
              SessionScanner.claudeStep(lines: [bash, meta()])?.label == "Build the app")
        check("a subagent's calls do not count",
              SessionScanner.claudeStep(lines: [call("s", "Bash", ["command": "rm -rf build"], sidechain: true)]) == nil)

        check("Read names the file", SessionScanner.claudeStep(lines: [
            call("r", "Read", ["file_path": "/Users/x/Sources/Hotch/Anchors.swift"])])?.label == "Read Anchors.swift")
        check("an MCP tool names tool and server", SessionScanner.claudeStep(lines: [
            call("m", "mcp__notion__search", ["query": "x"])])?.label.contains("\u{00B7}") == true)
        check("a long command is capped", (SessionScanner.claudeStep(lines: [
            call("l", "Bash", ["command": String(repeating: "x", count: 500)])])?.command?.count ?? 0) <= 201)

        print(failures == 0 ? "Session step checks passed." : "\(failures) session step checks failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
