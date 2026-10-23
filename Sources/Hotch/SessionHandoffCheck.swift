import Foundation

/// `--check-session-handoff`: no UI, process activation or session file reads.
enum SessionHandoffCheck {
    static func runBlockingAndExit() -> Never {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print("  \(passed ? "ok  " : "FAIL")  \(name)")
            if !passed { failures += 1 }
        }
        let terminal = SessionHost(processID: 10, bundleID: "com.apple.Terminal", name: "Terminal")
        let ghostty = SessionHost(processID: 11, bundleID: "com.mitchellh.ghostty", name: "Ghostty")
        let unrelated = SessionHost(processID: 12, bundleID: "com.apple.finder", name: "Finder")
        let code = SessionHost(processID: 13, bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")
        let insiders = SessionHost(processID: 14, bundleID: "com.microsoft.VSCodeInsiders", name: "Code Insiders")
        let codex = SessionHost(processID: 15, bundleID: "com.openai.codex", name: "Codex")

        func resolved(_ result: Result<SessionHost, SessionHandoffFailure>) -> SessionHost? {
            try? result.get()
        }
        func failed(_ result: Result<SessionHost, SessionHandoffFailure>, with expected: SessionHandoffFailure) -> Bool {
            if case .failure(let actual) = result { return actual == expected }
            return false
        }
        check("nearest known ancestor wins", resolved(SessionHandoffPolicy.resolve(
            surface: "Terminal", ancestry: [unrelated, ghostty, terminal], running: [terminal, ghostty])) == ghostty)
        check("an unrelated app cannot own an unknown session", failed(SessionHandoffPolicy.resolve(
            surface: nil, ancestry: [unrelated], running: [unrelated]), with: .hostUnidentified(nil)))
        check("a detached session does not guess between terminals", failed(SessionHandoffPolicy.resolve(
            surface: "Terminal", ancestry: [], running: [terminal, ghostty]), with: .hostUnidentified("Terminal")))
        check("even a single terminal needs ownership evidence", failed(SessionHandoffPolicy.resolve(
            surface: "Terminal", ancestry: [], running: [terminal]), with: .hostUnidentified("Terminal")))
        check("an explicit desktop surface resolves", resolved(SessionHandoffPolicy.resolve(
            surface: "Codex app", ancestry: [], running: [codex, unrelated])) == codex)
        check("a closed desktop app gives recovery guidance", failed(SessionHandoffPolicy.resolve(
            surface: "Codex app", ancestry: [], running: []), with: .hostNotRunning("Codex app")))
        check("multiple editor variants require ownership evidence", failed(SessionHandoffPolicy.resolve(
            surface: "VS Code", ancestry: [], running: [code, insiders]), with: .ambiguousHost("VS Code")))
        check("editor ancestry disambiguates the variant", resolved(SessionHandoffPolicy.resolve(
            surface: "VS Code", ancestry: [insiders], running: [code, insiders])) == insiders)
        check("success requires an opened application", !SessionHandoffPolicy.launchWasAccepted(
            hasApplication: false, hasError: false, isTerminated: false))
        check("a Launch Services error stays a failure", !SessionHandoffPolicy.launchWasAccepted(
            hasApplication: true, hasError: true, isTerminated: false))
        check("a terminated application stays a failure", !SessionHandoffPolicy.launchWasAccepted(
            hasApplication: true, hasError: false, isTerminated: true))
        check("accepted live application succeeds", SessionHandoffPolicy.launchWasAccepted(
            hasApplication: true, hasError: false, isTerminated: false))
        print(failures == 0 ? "Session handoff checks passed." : "\(failures) session handoff checks failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
