import AppKit
import SwiftUI

// MARK: - Provider catalog

/// Everything the settings window needs to describe a provider. Adding a new
/// provider to settings is one entry here plus its UsageProvider.
///
/// Vendors expose usage three different ways, so connection comes in three
/// uniform kinds rather than one:
///  - claudeCode: Claude Code holds the sign-in and Hotch asks it for usage;
///                signing in runs Claude Code's own `claude auth login`.
///  - apiKey:     the user pastes a key from the vendor console (Grok, Kimi,
///                DeepSeek). Stored in Hotch's own support folder.
///  - cli:        the vendor's own CLI already holds a credential; Hotch asks
///                it, read-only (Codex).
struct ProviderConfig: Identifiable {
    /// A CLI-backed provider's current state, in the words the user needs.
    ///
    /// One string and a flag rather than the old signed-in/signed-out pair,
    /// because "not working" has more than one cause and lumping them together
    /// is what left a Codex row saying nothing useful. `ready` drives the badge;
    /// `text` says what to actually do about it.
    struct CLIStatus {
        var text: String
        var ready: Bool
        /// The command to run, when there is one. Split out of `text` because
        /// inside the sentence it wrapped across three lines and could not be
        /// selected, so the one actionable part of the row was the part you had to
        /// retype from a screenshot.
        var command: String?

        init(text: String, ready: Bool, command: String? = nil) {
            self.text = text
            self.ready = ready
            self.command = command
        }
    }

    enum Auth {
        case claudeCode
        case apiKey(placeholder: String, consoleName: String, consoleURL: String)
        case cli(status: () -> CLIStatus)
    }

    let id: String
    let name: String
    let auth: Auth
}

enum ProviderCatalog {
    static let all: [ProviderConfig] = [
        ProviderConfig(id: "claude", name: "Claude", auth: .claudeCode),
        ProviderConfig(id: "codex", name: "Codex", auth: .cli(status: {
            // Both halves are required: the credential proves who you are, the
            // binary is what OpenAI will actually talk to. Which one is missing
            // decides what the user has to go and do.
            switch CodexProvider.readiness() {
            case .ready:
                return .init(text: "Reading your Codex CLI sign-in.", ready: true)
            case .cliMissing:
                return .init(text: "Codex CLI not installed. Install it, then sign in:",
                             ready: false,
                             command: "brew install --cask codex")
            case .notSignedIn:
                return .init(text: "Codex CLI installed, but not signed in. Run this once:",
                             ready: false,
                             command: "codex")
            }
        })),
        ProviderConfig(id: "grok", name: "Grok", auth: .apiKey(
            placeholder: "xAI management key (billing read)",
            consoleName: "console.x.ai",
            consoleURL: "https://console.x.ai")),
        ProviderConfig(id: "kimi", name: "Kimi", auth: .apiKey(
            placeholder: "sk-kimi-… coding key, or platform key",
            consoleName: "platform.kimi.ai",
            consoleURL: "https://platform.kimi.ai")),
        ProviderConfig(id: "deepseek", name: "DeepSeek", auth: .apiKey(
            placeholder: "DeepSeek API key",
            consoleName: "platform.deepseek.com",
            consoleURL: "https://platform.deepseek.com/api_keys")),
    ]
}

// MARK: - Command chip

/// A shell command the user has to run, as one click to the clipboard.
///
/// Worth a control of its own because the alternative is what shipped: the
/// command sat mid-sentence in the status line, wrapped across three lines, and
/// could not be selected — so the only actionable thing in the row was the thing
/// you had to retype by hand.
private struct CommandChip: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        } label: {
            HStack(spacing: 5) {
                Text(command)
                    .font(.system(size: 10.5, design: .monospaced))
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy to clipboard")
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Height of the scrolling viewport, or `nil` to lay the whole column out at
    /// its natural height.
    ///
    /// `nil` is what the snapshot renderer wants: a clipped viewport can only
    /// ever show one screenful, so it could never catch a layout regression that
    /// happens below the fold. The real window always passes a height; only the
    /// renderer sees the whole column at once.
    var viewportHeight: CGFloat? = nil
    var onShowWelcome: () -> Void = {}
    var onPreviewAlert: () -> Void = {}
    var onAccountChanged: () -> Void = {}

    /// Mirrors `SMAppService`, which publishes nothing to observe. Seeded when
    /// the window appears so it reflects a change made from the menu while the
    /// window was closed.
    @State private var launchAtLogin = LoginItem.isEnabled

    enum ClaudePhase: Equatable {
        case idle
        /// `claude auth login` is running and waiting on the browser.
        case connecting
        case failed(String)
    }

    /// The command that installs Claude Code, shown when none is found.
    static let claudeInstallCommand = ClaudeCodeBridge.installCommand

    @State private var claudePhase: ClaudePhase = .idle
    /// Held so the wait can be cancelled from the row.
    @State private var claudeConnectTask: Task<Void, Never>?

    /// Which providers are ready, re-read on a tick.
    ///
    /// **The readiness checks were always live; nothing ever asked them again.**
    /// `ProviderReadiness.isConfigured` is a handful of file existence checks
    /// with no caching, so it would have reported a newly installed Codex CLI
    /// correctly the moment it was called — but it is called from `body`, and
    /// SwiftUI only re-runs `body` when something it observes changes. Installing
    /// a CLI happens in a terminal, in another process, and publishes nothing.
    /// So a fresh install showed "not set up", the user fixed it exactly as the
    /// row instructed, and the row went on saying "not set up" until something
    /// unrelated forced a redraw. Setup instructions that do not respond to
    /// being followed are worse than no instructions.
    ///
    /// A snapshot in `@State`, refreshed on a timer while the window is open and
    /// whenever the app comes forward — which is the moment someone returns from
    /// the terminal they were told to use. The set only changes when an answer
    /// changes, so a steady state costs one comparison per tick and no redraw.
    @State private var readyIDs: Set<String> = []
    /// Claude Code as last seen: which install, and what it is signed in
    /// with. Both cached and cheap; refreshed with the readiness tick.
    @State private var claudeInstall = ClaudeCodeBridge.locate()
    @State private var claudeSignIn = ClaudeCodeBridge.signIn()
    /// The fallback link `claude auth login` prints when the browser did not
    /// open, so the row can offer it.
    @State private var claudeLoginLink: URL?
    @State private var keyHints: [String: String] = SettingsView.loadKeyHints()
    @State private var editingID: String?
    @State private var draftKey = ""
    @State private var draftTeamID = ""

    static func loadKeyHints() -> [String: String] {
        var hints: [String: String] = [:]
        for config in ProviderCatalog.all {
            if case .apiKey = config.auth, let hint = ProviderKeyStore.redactedKey(for: config.id) {
                hints[config.id] = hint
            }
        }
        return hints
    }

    /// The settings column is fixed at this width, and nothing in it is allowed
    /// to argue.
    ///
    /// The rule this column enforces, learned expensively: **no control here may
    /// size itself from a string this app did not write.** A `.fixedSize()`
    /// picker holding a 54-character name from a remote account asked for 379pt
    /// in a row that had 348 — and an overflowing child is *centred* on its
    /// parent, so the entire window shifted sideways and clipped its labels off
    /// both edges at once. The symptom looked nothing like "a control is too
    /// wide". Anything showing an account name, a project, a model or a redacted
    /// key gets a `maxWidth` and truncates.
    static let columnWidth: CGFloat = 500

    /// How tall the window is, regardless of how much is in it.
    ///
    /// The column had grown past 1000pt. A 14-inch MacBook is 982pt tall with 904
    /// of that usable, so the window no longer fit — and a window taller than the
    /// display is not merely awkward, it is unreachable: macOS pins the title bar
    /// under the menu bar, so the overflow hangs off the bottom of the desktop
    /// with nothing to drag and no scroller to pull. The last section could not
    /// be seen at all.
    ///
    /// 440 plus a 32pt title bar is 472 — a little under half of that 982, which
    /// leaves the window comfortably on screen on the smallest Mac laptop and
    /// puts everything below the fold one scroll away instead of nowhere.
    ///
    /// **560, because 440 ended on a section boundary.** The providers card
    /// finished almost exactly at the fold, so the window looked complete: no
    /// clipped row, no half-visible heading, and with overlay scrollers there is
    /// no scroll bar sitting there to say otherwise. Everything past it —
    /// Startup, Display, Updates, the version footer — was invisible and
    /// unsuggested. A viewport should end *mid-content*, because a cut-off line
    /// is the only affordance a scroll view has when its scroller is hidden.
    /// 560 puts the fold inside the section that follows the card, and 560 + 32
    /// is still only 592 against 904 usable on the smallest Mac laptop.
    static let viewportHeight: CGFloat = 560

    var body: some View {
        if let viewportHeight {
            ScrollView(.vertical) {
                // `maxWidth`, not `width`, only here: if the user has scroll
                // bars set to always show, the clip view is ~15pt narrower than
                // the window, and a rigid 500 would overflow it and be *centred*
                // on it — the same clipped-labels failure `columnWidth` documents.
                // Flexible up to 500 reflows instead, and is still exactly 500
                // with overlay scrollers, which is everybody's default.
                column.frame(maxWidth: SettingsView.columnWidth, alignment: .leading)
            }
            .frame(width: SettingsView.columnWidth, height: viewportHeight)
            // Installing a CLI happens in a terminal and publishes nothing, so
            // the window has to ask again rather than wait to be told. Two
            // seconds is well under the time it takes to switch back from a
            // terminal, and the work is a few file existence checks.
            //
            // `.task` rather than a `Timer` publisher: a publisher built inside
            // `body` is rebuilt every time `body` runs, and `body` runs whenever
            // this loop changes `readyIDs` — a timer that respawns itself on its
            // own effect. `.task` starts once when the view appears and is
            // cancelled when it goes away, which is exactly the lifetime wanted.
            .task {
                while !Task.isCancelled {
                    refreshReadiness()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            // The moment someone returns from the terminal they were sent to.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshReadiness()
            }
        } else {
            // A definite width, because with no proposal at all the wrapping
            // paragraphs would report their ideal width — one very long line.
            column.frame(width: SettingsView.columnWidth)
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                HotchBadge(size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hotch")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("A quiet companion for your Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(HotchAbout.version)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 22)

            sectionHeader("Providers")

            VStack(spacing: 0) {
                ForEach(Array(ProviderCatalog.all.enumerated()), id: \.element.id) { index, config in
                    if index > 0 { Divider().padding(.leading, 44) }
                    providerRow(config)
                    if editingID == config.id {
                        keyEditor(config)
                    }
                }
            }
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            // Answers two questions that were previously left to be inferred from a
            // blank row: why a CLI is involved at all, and why a provider is on or
            // off without the user having touched the switch.
            Text("Claude and Codex use your existing CLI sign-ins to read usage. No prompts are sent. Turn off a provider to hide its row.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            sectionHeader("Startup").padding(.top, 18)

            Toggle("Open Hotch at login", isOn: Binding(
                get: { launchAtLogin },
                // The system is the source of truth, not the checkbox: a
                // registration can be refused (a translocated copy cannot hold
                // a login item), and `setEnabled` answers with what actually
                // happened so the box snaps back instead of claiming a state
                // macOS never agreed to.
                set: { launchAtLogin = LoginItem.setEnabled($0) }
            ))
            .font(.system(size: 12))
            .toggleStyle(.checkbox)
            .padding(.top, 2)

            Text("Start quietly in your chosen position when you log in.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            sectionHeader("Display").padding(.top, 18)

            HStack(spacing: 8) {
                Text("Meters show")
                    .font(.system(size: 12))
                Picker("", selection: $settings.displayMode) {
                    ForEach(UsageDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.top, 2)

            Text("Choose consumption or remaining capacity. Warning colors always reflect how close you are to the limit.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Toggle("Remember recent clipboard text", isOn: $settings.clipboardHistoryEnabled)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
                .padding(.top, 10)
            Text("The Clipboard page shows the last \(ClipboardStore.maxItems) copied texts. History lives in memory only — quitting forgets it — and items marked concealed are skipped. Turning this off stops watching and clears the history. Clipboard text is never sent to a provider.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HotchMoreSettings(onPreviewAlert: onPreviewAlert)

            sectionHeader("Refresh").padding(.top, 18)

            HStack(spacing: 8) {
                Text("Refresh every")
                    .font(.system(size: 12))
                Picker("", selection: $settings.refreshInterval) {
                    ForEach(AppSettings.refreshChoices, id: \.seconds) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.top, 2)

            Text("Provider requests also respect their minimum polling intervals. API keys stay in Hotch’s support folder and are sent only to their provider. Claude and Codex keep their own sign-in credentials.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            UpdateSettings().padding(.top, 18)

            sectionHeader("Welcome & privacy").padding(.top, 18)
            Text("Sessions, focus history and Mac readings stay on this Mac. Hotch has no account or analytics service. Only enabled providers request usage or balance from their own services, and the update check only asks whether a newer Hotch exists.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Welcome…", action: onShowWelcome)
                .controlSize(.small)
                .padding(.top, 8)

            credit
        }
        .padding(20)
    }

    /// Attribution, carried in the app rather than only in the repo, so it
    /// travels with a copy someone was handed.
    private var credit: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 8) {
                HotchBadge(size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Hotch \(HotchAbout.version)")
                        .font(.system(size: 11, weight: .semibold))
                    Text(HotchAbout.credit)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                if let url = URL(string: "mailto:\(HotchAbout.email)") {
                    Link("Contact", destination: url)
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 6)
    }

    // MARK: Rows

    private func providerRow(_ config: ProviderConfig) -> some View {
        let identity = ProviderIdentity.identity(for: config.id)
        // Monochrome brands are tinted near-white for the dark panel; in this
        // system-themed window they follow the label colour instead.
        let monochrome = config.id == "grok" || config.id == "kimi"
        return HStack(spacing: 12) {
            BrandMark(kind: identity.mark, size: 20,
                      tint: monochrome ? Color.primary : identity.accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusLine(config))
                    .font(.system(size: 11))
                    .foregroundStyle(statusIsError(config) ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let command = cliCommand(config) {
                    CommandChip(command: command)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: 8)

            // An enabled provider that cannot produce a number says so here, at
            // the switch, rather than leaving the user to infer it from a blank
            // row in the panel. On is not the same as working.
            if settings.isEnabled(config.id) && !isReady(config) {
                Text("not set up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help("\(config.name) is switched on but has nothing to read yet")
            }

            controls(config)

            Toggle("", isOn: Binding(
                get: { settings.isEnabled(config.id) },
                set: { settings.setEnabled($0, providerID: config.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Show \(config.name) in the companion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Whether this provider could return a real number right now.
    ///
    /// Deferred to `ProviderReadiness` rather than worked out here: the same
    /// question decides which rows a fresh install starts with, and two
    /// independent answers to it is what produced enabled providers wearing a
    /// "not set up" badge.
    private func isReady(_ config: ProviderConfig) -> Bool {
        readyIDs.contains(config.id)
    }

    /// Re-reads every provider's readiness and publishes it only if it moved.
    private func refreshReadiness() {
        let ids = ProviderCatalog.all.map(\.id)
        let fresh = ProviderReadiness.configuredIDs(among: ids)
        if fresh != readyIDs { readyIDs = fresh }
        // The Claude row reads Claude Code's state rather than the set, and a
        // sign-in performed elsewhere (a terminal, `--connect-claude`) is
        // exactly the kind of change nothing here would otherwise notice.
        let install = ClaudeCodeBridge.locate()
        if install != claudeInstall { claudeInstall = install }
        let signIn = ClaudeCodeBridge.signIn()
        if signIn != claudeSignIn { claudeSignIn = signIn }
    }

    private func statusLine(_ config: ProviderConfig) -> String {
        switch config.auth {
        case .claudeCode:
            switch claudePhase {
            case .connecting:
                return "Waiting for you to sign in to Claude Code in your browser\u{2026}"
            case .failed(let message):
                return message
            case .idle:
                guard let install = claudeInstall else {
                    return "Claude Code not found. Install it, then sign in once:"
                }
                let version = install.version.map { "Claude Code \($0)" } ?? "Claude Code"
                switch claudeSignIn {
                case .signedIn(let plan):
                    return "Reading usage from \(version)" + (plan.map { " \u{00B7} \($0) plan" } ?? "")
                case .signedOut:
                    return "\(version) is not signed in. Sign in once and usage stays live."
                case .noPlan(let reason):
                    return "\(reason) \u{00B7} no plan limits to show"
                case .unknown:
                    return "Checking \(version)\u{2026}"
                }
            }

        case .cli(let status):
            return status().text

        case .apiKey(_, let consoleName, _):
            if let hint = keyHints[config.id] {
                if config.id == "grok" && GrokProvider.teamID == nil {
                    return "Key set \u{00B7} \(hint) \u{00B7} still needs your team ID"
                }
                return "Key set \u{00B7} \(hint)"
            }
            if config.id == "kimi",
               FileManager.default.fileExists(atPath: KimiProvider.cliCredsURL.path) {
                return "Using your Kimi CLI sign-in, read-only."
            }
            return "Needs an API key from \(consoleName)"
        }
    }

    private func statusIsError(_ config: ProviderConfig) -> Bool {
        if case .claudeCode = config.auth, case .failed = claudePhase { return true }
        return false
    }

    /// The command a CLI-backed provider still needs run, if any.
    private func cliCommand(_ config: ProviderConfig) -> String? {
        if case .claudeCode = config.auth {
            return claudeInstall == nil && claudePhase == .idle ? SettingsView.claudeInstallCommand : nil
        }
        guard case .cli(let status) = config.auth else { return nil }
        return status().command
    }

    @ViewBuilder
    private func controls(_ config: ProviderConfig) -> some View {
        switch config.auth {
        case .claudeCode:
            switch claudePhase {
            case .connecting:
                // A wait the user cannot end is a hang, whatever the code is
                // actually doing, so the spinner always comes with Cancel.
                HStack(spacing: 6) {
                    if let link = claudeLoginLink {
                        Link("Open sign-in page", destination: link)
                            .font(.system(size: 11))
                    }
                    ProgressView().controlSize(.small)
                    Button("Cancel") { cancelClaudeConnect() }
                        .controlSize(.small)
                }
            default:
                // Signed in needs no button: switching the row off is how to
                // stop showing Claude, and Hotch never signs Claude Code out.
                if claudeInstall != nil, !isClaudeSignedIn {
                    Button("Sign in with Claude Code") { connectClaude() }
                        .controlSize(.small)
                }
            }

        case .cli:
            EmptyView()

        case .apiKey:
            if editingID == config.id {
                EmptyView()
            } else if keyHints[config.id] != nil {
                HStack(spacing: 6) {
                    Button("Change\u{2026}") { beginEditing(config) }
                        .controlSize(.small)
                    Button("Remove") { removeKey(config) }
                        .controlSize(.small)
                }
            } else {
                Button("Add Key\u{2026}") { beginEditing(config) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: Key editor

    @ViewBuilder
    private func keyEditor(_ config: ProviderConfig) -> some View {
        if case .apiKey(let placeholder, let consoleName, let consoleURL) = config.auth {
            VStack(alignment: .leading, spacing: 8) {
                SecureField(placeholder, text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                if config.id == "grok" {
                    TextField("Team ID (Console \u{2192} Settings)", text: $draftTeamID)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button("Save") { saveKey(config) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave(config))
                    Button("Cancel") { cancelEditing() }
                        .controlSize(.small)
                    Spacer()
                    if let url = URL(string: consoleURL) {
                        Link("Get a key at \(consoleName) \u{2197}", destination: url)
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private func beginEditing(_ config: ProviderConfig) {
        editingID = config.id
        draftKey = ""
        draftTeamID = config.id == "grok" ? settings.grokTeamID : ""
    }

    private func cancelEditing() {
        editingID = nil
        draftKey = ""
        draftTeamID = ""
    }

    private func canSave(_ config: ProviderConfig) -> Bool {
        let hasKey = !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || keyHints[config.id] != nil
        if config.id == "grok" {
            return hasKey && !draftTeamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasKey && !draftKey.isEmpty
    }

    private func saveKey(_ config: ProviderConfig) {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard ProviderKeyStore.store(trimmed, for: config.id) else { return }
            keyHints[config.id] = ProviderKeyStore.redactedKey(for: config.id)
        }
        if config.id == "grok" {
            settings.grokTeamID = draftTeamID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A configured provider is one the user wants to see.
        settings.setEnabled(true, providerID: config.id)
        cancelEditing()
        onAccountChanged()
    }

    private func removeKey(_ config: ProviderConfig) {
        ProviderKeyStore.clear(for: config.id)
        keyHints[config.id] = nil
        cancelEditing()
        onAccountChanged()
    }

    // MARK: Claude account actions

    private var isClaudeSignedIn: Bool {
        if case .signedIn = claudeSignIn { return true }
        return false
    }

    /// Runs Claude Code's own `claude auth login --claudeai`, which opens the
    /// browser and stores Claude Code's own credential. Hotch waits up to five
    /// minutes, then asks Claude Code for usage straight away.
    private func connectClaude() {
        claudePhase = .connecting
        claudeLoginLink = nil
        claudeConnectTask?.cancel()
        claudeConnectTask = Task { @MainActor in
            let result = await ClaudeCodeLogin.run { link in
                Task { @MainActor in claudeLoginLink = link }
            }
            claudeLoginLink = nil
            switch result {
            case .success:
                claudePhase = .idle
                ClaudeCodeBridge.invalidateSignIn()
                // A connected provider is one the user wants to see, same as
                // saving an API key.
                settings.setEnabled(true, providerID: "claude")
                // Whatever interval the throttle learned was learned against
                // a Claude Code that had no sign-in; without the reset the
                // first poll would be declined and the row would stay on "sign
                // in" for two minutes after a sign-in that worked.
                ClaudeProvider.throttle.reset()
                ClaudeProvider.lastVerdict.clear()
                claudeSignIn = ClaudeCodeBridge.signIn(blockingIfUnknown: true)
                onAccountChanged()
            case .failure(.cancelled):
                claudePhase = .idle
            case .failure(let failure):
                claudePhase = .failed(failure.message)
            }
            claudeConnectTask = nil
        }
    }

    /// Stops waiting and ends the `claude auth login` child, putting the row
    /// back to a state the user can act on.
    private func cancelClaudeConnect() {
        claudeConnectTask?.cancel()
        claudeConnectTask = nil
        claudeLoginLink = nil
        claudePhase = .idle
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController {
    private let settings: AppSettings
    private let store: UsageStore
    private var window: NSWindow?
    var onShowWelcome: () -> Void = {}
    var onPreviewAlert: () -> Void = {}

    init(settings: AppSettings, store: UsageStore) {
        self.settings = settings
        self.store = store
    }

    /// On screen, for the updater: a relaunch would close it under the user.
    var isOpen: Bool { window?.isVisible == true }

    func show() {
        // The 440pt viewport still has to fit *this* display, title bar and all,
        // so it is a ceiling rather than a promise. Only a very small or heavily
        // scaled screen ever brings it down.
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 40
        let height = max(320, min(SettingsView.viewportHeight, available))
        let size = NSSize(width: SettingsView.columnWidth, height: height)

        // Rebuilt on every open so account and key status are read fresh — which
        // also means it always opens scrolled to the top.
        let view = SettingsView(settings: settings,
                                viewportHeight: height,
                                onShowWelcome: onShowWelcome,
                                onPreviewAlert: onPreviewAlert,
                                onAccountChanged: { [weak store] in store?.requestRefresh() })
        let hosting = NSHostingController(rootView: view)

        if let window {
            window.contentViewController = hosting
            window.setContentSize(size)
        } else {
            let created = NSWindow(contentViewController: hosting)
            created.title = "Hotch Settings"
            // Not `.resizable`: the column is fixed at 500 and the sections
            // below the fold are reached by scrolling, so there is nothing a
            // drag handle could usefully do.
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.setContentSize(size)
            created.center()
            window = created
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
