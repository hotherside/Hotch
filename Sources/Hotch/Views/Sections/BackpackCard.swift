import SwiftUI

/// A labelled entry to the overview, shared by the compact and native footers.
/// Opening the overview never starts a session.
struct BackpackShortcut: View {
    @ObservedObject var backpack: BackpackManager
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: backpack.isOn ? "backpack.fill" : "backpack")
                    .font(.system(size: 11, weight: .medium))
                Text(backpack.isOn ? "Backpack on" : "Backpack")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(backpack.isOn ? HP.ok : HP.text2)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? HP.tileHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .fixedSize()
        .help("Open Backpack mode · keep agents working with the lid closed")
        .accessibilityLabel(backpack.isOn ? "Backpack mode is on" : "Backpack mode")
        .accessibilityHint("Opens details and setup")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Calm, persistent discovery on Home. Availability is visible before opening
/// the details, and the entire row is an explicit navigation action.
struct BackpackDiscoveryRow: View {
    @ObservedObject var backpack: BackpackManager
    var action: () -> Void

    private var availability: String {
        switch backpack.phase {
        case .on: return "On · ends when agents finish"
        case .needsApproval: return "Setup needed · helper approval"
        case .unavailable: return "Currently unavailable · view details"
        case .ending: return "Ending…"
        case .off: return backpack.lastError == nil ? "Ready to start" : "Couldn’t start · view details"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: backpack.isOn ? "backpack.fill" : "backpack")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(backpack.isOn ? HP.ok : HP.text2)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(backpack.isOn ? "Backpack on" : "Backpack mode")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HP.text)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(HP.text3)
                    }
                    Text("Keep agents working with the lid closed")
                        .font(.system(size: 11))
                        .foregroundStyle(HP.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(availability)
                        .font(.system(size: 10.5))
                        .foregroundStyle(backpack.isOn ? HP.ok : HP.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .buttonStyle(TileButtonStyle(radius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Backpack details and setup")
    }
}

/// Backpack mode: close the lid on the go and the agents keep working.
///
/// The card says exactly what it will do and when it stops, because the thing
/// it overrides — sleeping when the lid closes — is a safety behaviour. Every
/// guardrail is listed where the switch is, not buried in Settings.
struct BackpackCard: View {
    @ObservedObject var backpack: BackpackManager
    let sessions: [AgentSession]
    let now: Date
    let layout: SectionLayout
    let active: Bool

    private var busyAgents: Int { sessions.filter { $0.activity == .working || $0.activity == .shell }.count }

    var body: some View {
        let stack = layout.isPopover
        Group {
            if stack {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) { icon; titleBlock }
                    rules
                    actions
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    icon
                    VStack(alignment: .leading, spacing: 0) {
                        titleBlock
                        rules.padding(.top, 12)
                        actions.padding(.top, 14)
                    }
                }
            }
        }
        .frame(width: layout.width, alignment: .topLeading)
        .modifier(Rise(active: active, index: 0))
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(HP.ok.opacity(0.15))
            Image(systemName: backpack.isOn ? "backpack.fill" : "backpack")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(HP.ok)
        }
        .frame(width: layout.isPopover ? 56 : 72, height: layout.isPopover ? 56 : 72)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(backpack.isOn ? "Backpack mode is on" : "Backpack mode")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(HP.text)
            Text(lead)
                .font(.system(size: 12.5))
                .foregroundStyle(HP.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let error = backpack.lastError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(HP.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var lead: String {
        switch backpack.phase {
        case .on:
            return busyAgents > 0
                ? "Close the lid whenever you like. \(busyAgents) agent\(busyAgents == 1 ? " is" : "s are") still working; once they finish, the Mac sleeps as normal."
                : "Close the lid whenever you like. Nothing is running right now, so the Mac will sleep after a short grace."
        case .needsApproval:
            return "One-time setup: allow Hotch's helper in System Settings so it can keep the Mac awake with the lid closed."
        case .unavailable(let reason):
            return reason
        default:
            return "Close the lid and your agents keep working. Hotch keeps the Mac awake only while it has to, then lets it sleep."
        }
    }

    private var rules: some View {
        let columns = layout.isPopover ? 1 : 2
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .leading),
                                        count: columns),
                         alignment: .leading, spacing: 7) {
            rule("checkmark.circle", "Ends when your agents finish")
            rule("battery.25percent", "Ends at \(Int(BackpackPolicy.batteryFloor))% battery")
            rule("thermometer.medium", "Ends if the Mac runs hot")
            rule("lock", "Locks the screen as the lid closes")
            rule("leaf", "Low Power Mode while it runs")
            rule("clock", "Gives up after \(Int(BackpackPolicy.maxHours)) hours")
        }
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(HP.text3)
                .frame(width: 16)
            Text(text).font(.system(size: 12)).foregroundStyle(HP.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch backpack.phase {
            case .on(let since):
                Button("End Backpack mode") { backpack.stop() }
                    .buttonStyle(PillButtonStyle())
                Text("awake \(Fmt.duration(max(0, now.timeIntervalSince(since)))) · \(busyAgents) working")
                    .font(.system(size: 11.5)).foregroundStyle(HP.text3)
            case .needsApproval:
                Button("Allow in System Settings") { backpack.openApprovalSettings() }
                    .buttonStyle(PillButtonStyle(kind: .go))
                Text("then come back and press Start")
                    .font(.system(size: 11.5)).foregroundStyle(HP.text3)
            case .unavailable:
                EmptyView()
            case .ending:
                Text("Ending…").font(.system(size: 12)).foregroundStyle(HP.text3)
            default:
                Button("Start Backpack mode") { backpack.start() }
                    .buttonStyle(PillButtonStyle(kind: .go))
            }
        }
    }
}

/// The guardrail numbers, one place.
enum BackpackPolicy {
    static let batteryFloor: Double = 20
    static let maxHours: Double = 4
}
