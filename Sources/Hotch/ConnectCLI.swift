import AppKit
import Foundation

/// Terminal driver for signing Claude Code in, so the connection can be set up
/// and debugged without the GUI. Hotch has no Claude sign-in of its own any
/// more: this runs Claude Code's `claude auth login --claudeai` with the
/// terminal attached, then asks Claude Code for usage to prove it worked.
///
///   --connect-claude            run `claude auth login --claudeai`
///   --connect-claude --dry-run  print which Claude Code and command would run
enum ConnectCLI {
    static func runBlockingAndExit(dryRun: Bool) -> Never {
        let installs = ClaudeCodeBridge.installs()
        guard let install = installs.first else {
            print("Claude Code not found on any probed path.")
            print("Install it, then run this again:")
            print("  \(ClaudeCodeBridge.installCommand)")
            exit(1)
        }

        if dryRun {
            print("Hotch Claude connect, dry run")
            print("claude code:  \(install.version ?? "unknown version") (\(install.source))")
            print("binary:       \(install.url.path)")
            print("command:      claude \(ClaudeCodeLogin.arguments.joined(separator: " "))")
            print("timeout:      \(Int(ClaudeCodeLogin.timeout / 60)) min")
            print("")
            print("nothing run")
            exit(0)
        }

        step("starting Claude Code's own sign-in (claude \(ClaudeCodeLogin.arguments.joined(separator: " ")))")
        step("Claude Code \(install.version ?? "") at \(install.url.path)")
        switch ClaudeCodeLogin.runInTerminal(install: install) {
        case .success:
            step("Claude Code reports the sign-in finished")
        case .failure(let failure):
            step("sign-in did not finish: \(failure.message)")
            exit(1)
        }

        // Prove it from Hotch's side: the same read the panel makes.
        ClaudeCodeBridge.invalidateSignIn()
        switch ClaudeCodeBridge.fetchUsage(install: install) {
        case .reply(let reply):
            switch reply.signIn {
            case .signedIn(let plan):
                step("usage readable: \(reply.windows.count) window(s)"
                     + (plan.map { ", \($0) plan" } ?? ""))
                step("done, Hotch can now read your Claude plan usage through Claude Code")
                exit(0)
            case .noPlan(let reason):
                step("\(reason): signed in, but there are no plan limits to read")
                exit(0)
            case .signedOut, .unknown:
                step("Claude Code still reports no sign-in")
                exit(1)
            }
        case .notInstalled:
            step("Claude Code disappeared")
            exit(1)
        case .failed(let reason):
            step("signed in, but the usage read failed: \(reason)")
            exit(1)
        }
    }

    private static func step(_ message: String) {
        print("  \(message)")
        fflush(stdout)
    }
}
