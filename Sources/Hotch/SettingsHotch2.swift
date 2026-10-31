import SwiftUI

/// The Settings sections Hotch 2 adds: the menu bar readouts, the notch
/// alerts, the Mac's sensors and Backpack mode. Kept in its own view so the
/// provider rows above it stay one file's business.
struct HotchMoreSettings: View {
    @ObservedObject private var prefs = HotchPrefs.shared
    @ObservedObject private var backpack = BackpackManager.shared
    @ObservedObject private var settings = AppSettings.shared
    var onPreviewAlert: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Where Hotch lives").padding(.top, 18)
            Picker("", selection: $prefs.anchor) {
                ForEach(HotchPrefs.Anchor.allCases) { anchor in
                    Text(anchor.label).tag(anchor)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .font(.system(size: 12))
            if prefs.anchor == .edge {
                HStack(spacing: 8) {
                    Text("Edge").font(.system(size: 12))
                    Picker("", selection: $prefs.edgeSide) {
                        ForEach(HotchPrefs.EdgeSide.allCases) { side in Text(side.label).tag(side) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .padding(.top, 8)
                Text("Show on the tab")
                    .font(.system(size: 12))
                    .padding(.top, 10)
                HStack(spacing: 14) {
                    ForEach(HotchPrefs.RailReadout.allCases) { readout in
                        Toggle(readout.label, isOn: railBinding(readout))
                            .disabled(!canToggle(readout))
                            .help(railHelp(readout))
                    }
                }
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
                .padding(.top, 6)
                Toggle("A running Focus timer takes the last slot", isOn: $prefs.railFocusClock)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
                    .padding(.top, 6)
            }
            Toggle("Open the card with ⌥⌘H", isOn: $prefs.shortcutEnabled)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
                .padding(.top, 8)
            note("The edge tab shows what you tick above, one slot each, with a ring of usage for each AI provider. Hover the tab to peek at the card; click it to keep the card open. The card's own tabs, Hotch, AI, Mac and Desk, take you everywhere else. Notch brings back the original top-of-screen view. Pill and orb can sit anywhere.")

            header("Menu bar").padding(.top, 18)
            Text("Show beside the usage number")
                .font(.system(size: 12))
            HStack(spacing: 16) {
                Toggle("CPU", isOn: $prefs.menuBarCPU)
                Toggle("Memory", isOn: $prefs.menuBarMemory)
                Toggle("Network", isOn: $prefs.menuBarNetwork)
            }
            .font(.system(size: 12))
            .toggleStyle(.checkbox)
            .padding(.top, 6)
            note("Optional live readings beside the menu bar icon.")

            header("Alerts").padding(.top, 18)
            Toggle("Speak up when something needs you", isOn: $prefs.notchAlerts)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
            note("Your screen companion briefly shows a message when an agent needs you or finishes, a plan window passes 85%, the Mac runs hot or short of memory, or a focus timer ends.")
            Button("Try a sample alert", action: onPreviewAlert)
                .controlSize(.small)
                .padding(.top, 8)
                .disabled(prefs.anchor == .menuBar)
            if prefs.anchor == .menuBar {
                note("Choose a screen edge, notch, pill or orb to see companion alerts.")
            }

            header("This Mac").padding(.top, 18)
            Toggle("Temperatures, fans and power", isOn: $prefs.advancedSensors)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
            note("Read from the Mac's sensors through interfaces Apple does not document. CPU, memory, network, disk and battery always work; switch this off if a macOS update ever upsets the sensor readings.")

            header("Backpack mode").padding(.top, 18)
            HStack(spacing: 10) {
                Image(systemName: backpack.isOn ? "backpack.fill" : "backpack")
                    .foregroundStyle(backpack.isOn ? Color.green : Color.secondary)
                Text(backpackStatus)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                backpackButton
            }
            note("Close the lid on the go and your agents keep running. macOS only lets an administrator stop lid-close sleep, so Hotch uses a small helper you approve once. It always restores normal sleep: when your agents finish, at \(Int(BackpackPolicy.batteryFloor))% battery, if the Mac runs hot, after \(Int(BackpackPolicy.maxHours)) hours, or if Hotch quits. The screen locks as the lid closes, Low Power Mode keeps it cool while it runs, and opening the lid again ends it with a short summary.")
        }
    }

    private func railBinding(_ readout: HotchPrefs.RailReadout) -> Binding<Bool> {
        Binding(get: { prefs.railReadouts.contains(readout) },
                set: { on in
                    if on { prefs.railReadouts.insert(readout) } else { prefs.railReadouts.remove(readout) }
                })
    }

    /// A provider's readout needs the provider switched on, and the last
    /// readout left on stays on, so the tab is never empty.
    private func canToggle(_ readout: HotchPrefs.RailReadout) -> Bool {
        if let id = readout.providerID, !settings.isEnabled(id) { return false }
        let shown = prefs.railReadouts.filter { $0.providerID.map(settings.isEnabled) ?? true }
        return !(shown == [readout])
    }

    private func railHelp(_ readout: HotchPrefs.RailReadout) -> String {
        if let id = readout.providerID, !settings.isEnabled(id) {
            return "Switch \(readout.label) on under AI providers to show its usage here"
        }
        switch readout {
        case .claude, .codex: return "\(readout.label)'s tightest plan window"
        case .sessions: return "Live agent sessions; amber while one needs you"
        case .memory: return "Memory used, coloured by pressure"
        case .cpu: return "CPU use"
        }
    }

    private var backpackStatus: String {
        switch backpack.phase {
        case .on: return "On"
        case .needsApproval: return "Needs one-time approval"
        case .unavailable(let reason): return reason
        case .ending: return "Ending"
        default: return "Ready"
        }
    }

    @ViewBuilder
    private var backpackButton: some View {
        switch backpack.phase {
        case .needsApproval:
            Button("Open System Settings") { backpack.openApprovalSettings() }
        case .on:
            Button("End now") { backpack.stop() }
        default:
            EmptyView()
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 6)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }
}

/// Software updates: the two Sparkle switches and a manual check. Ask first is
/// the default; automatic installs wait for a quiet moment (see `UpdatePolicy`).
struct UpdateSettings: View {
    @ObservedObject private var updates = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("App updates")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 6)
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updates.checksAutomatically },
                set: { updates.setChecksAutomatically($0) }))
                .disabled(!updates.isRunning)
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { updates.installsAutomatically },
                set: { updates.setInstallsAutomatically($0) }))
                .disabled(!updates.checksAutomatically)
                .padding(.top, 4)
                .disabled(!updates.isRunning)
            HStack(spacing: 10) {
                // "Restart to Install" once an update has downloaded: Settings
                // being open is what holds it back, so this is where it is
                // most likely to be clicked.
                Button(updates.actionTitle) { updates.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(!updates.canAct)
                if let checked = Fmt.ago(updates.lastChecked) {
                    Text("Last checked \(checked)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .font(.system(size: 12))
        .toggleStyle(.checkbox)
    }

    private var note: String {
        guard updates.isRunning else {
            return "This copy was built without an update feed, so it does not check for updates."
        }
        let host = (Bundle.main.infoDictionary?["SUFeedURL"] as? String)
            .flatMap(URL.init(string:))?.host ?? "the update feed"
        return "Once a day Hotch asks \(host) whether a newer version exists. The request names only the Hotch and Sparkle versions: no usage, settings or system profile. Updates are signed and show their release notes before you choose Install. Automatic installs wait until the card is closed and no Focus timer or Backpack session is running."
    }
}
