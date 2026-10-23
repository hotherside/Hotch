import SwiftUI

/// The Settings sections Hotch 2 adds: the menu bar readouts, the notch
/// alerts, the Mac's sensors and Backpack mode. Kept in its own view so the
/// provider rows above it stay one file's business.
struct HotchMoreSettings: View {
    @ObservedObject private var prefs = HotchPrefs.shared
    @ObservedObject private var backpack = BackpackManager.shared

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
            }
            Toggle("Open the card with ⌥⌘H", isOn: $prefs.shortcutEnabled)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
                .padding(.top, 8)
            note("Screen edge: a tab with your tightest AI window, active sessions and CPU. Drag it anywhere and it lands on the nearest edge: left, right, or the bottom beside the Dock, where it lies down and covers nothing a window uses. Right-click it to switch edges. Push the pointer against it, or rest on it, and the card slides out. Floating: a pill or orb you can drop anywhere; it snaps to the nearer side. The menu bar icon is always there too, and also switches this from its right-click menu.")

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
            note("Plain text in the menu bar, like the system's own items. Off by default: the item stays one mark and one number until you ask for more.")

            header("Alerts").padding(.top, 18)
            Toggle("Speak up when something needs you", isOn: $prefs.notchAlerts)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)
            note("The edge tab or the floating pill briefly shows a short message when an agent needs you or finishes, a plan window passes 85%, the Mac runs hot or short of memory, or a focus timer ends. A few seconds each.")

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
