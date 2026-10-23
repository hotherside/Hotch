import AppKit
import Combine
import SwiftUI

/// One short message the closed notch can speak.
struct LiveActivity: Equatable, Identifiable {
    enum Icon: Equatable {
        case brand(String)
        case symbol(String)
    }

    let id = UUID()
    var icon: Icon
    var leading: String
    var trailing: String
    var tint: Color
    var trailingTint: Color
    var dot: Bool = false
    var hold: TimeInterval = 4.5
    /// A key for de-duplication: the same thing is not announced twice in a row.
    var key: String

    static func == (lhs: LiveActivity, rhs: LiveActivity) -> Bool { lhs.id == rhs.id }
}

/// The closed notch stays empty. It grows small wings only while something
/// needs you, then folds back into the hardware.
///
/// This is not the "glance sliver" v1 removed: that was a permanent slab on the
/// menu bar restating a number. These are events, each a few seconds long, and
/// each one is something you would otherwise have had to go and look for.
@MainActor
final class LiveActivityController {
    private let panel: NotchPanel
    private let host: NSHostingView<LiveActivityHost>
    private let state = LiveActivityState()
    private var queue: [LiveActivity] = []
    private var showing = false
    private var lastKeys: [String: Date] = [:]
    /// Asked before showing anything: the open panel already says it all.
    var panelIsOpen: () -> Bool = { false }
    /// Where alerts are shown. Set by the active anchor (the rail tab or the
    /// floating pill speaks them); nil falls back to the notch wings.
    var presenter: ((LiveActivity, @escaping () -> Void) -> Void)?

    static let wing: CGFloat = 128

    init() {
        panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 40),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        host = NSHostingView(rootView: LiveActivityHost(state: state))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Queues an activity. The same key within `cooldown` is dropped, so a
    /// flapping state cannot turn the notch into a strobe.
    func post(_ activity: LiveActivity, cooldown: TimeInterval = 120) {
        guard HotchPrefs.shared.notchAlerts else { return }
        let now = Date()
        if let last = lastKeys[activity.key], now.timeIntervalSince(last) < cooldown { return }
        lastKeys[activity.key] = now
        if queue.contains(where: { $0.key == activity.key }) { return }
        queue.append(activity)
        pump()
    }

    private func pump() {
        guard !showing, !queue.isEmpty else { return }
        if panelIsOpen() {
            // The panel shows the same facts; try again once it closes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.pump() }
            }
            return
        }
        let next = queue.removeFirst()
        if let presenter {
            showing = true
            presenter(next) { [weak self] in
                guard let self else { return }
                self.showing = false
                self.pump()
            }
            return
        }
        guard place() else { queue.removeAll(); return }
        showing = true
        state.activity = next
        state.expanded = false
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.spring(duration: 0.42, bounce: 0.18)) { self?.state.expanded = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + next.hold) { [weak self] in
            MainActor.assumeIsolated { self?.retract() }
        }
    }

    /// Folds the wings back into the notch, early if the panel opens.
    func retract() {
        guard showing else { return }
        withAnimation(.spring(duration: 0.34, bounce: 0)) { state.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.orderOut(nil)
                self.showing = false
                self.state.activity = nil
                self.pump()
            }
        }
    }

    /// Sits on the screen with a real notch when there is one, otherwise the
    /// main screen's menu bar centre.
    private func place() -> Bool {
        guard let geometry = NotchGeometryResolver.resolve(contentHeight: 0) else { return false }
        let notch = geometry.notchRect
        let height = geometry.isRealNotch ? notch.height : 28
        let width = notch.width + LiveActivityController.wing * 2
        state.notchWidth = geometry.isRealNotch ? notch.width : 0
        state.height = height
        let frame = CGRect(x: geometry.screenFrame.midX - width / 2,
                           y: geometry.screenFrame.maxY - height,
                           width: width, height: height)
        panel.setFrame(frame, display: false)
        return true
    }
}

@MainActor
final class LiveActivityState: ObservableObject {
    @Published var activity: LiveActivity?
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 185
    @Published var height: CGFloat = 32
}

struct LiveActivityHost: View {
    @ObservedObject var state: LiveActivityState

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.width
            let width = state.expanded ? full : max(state.notchWidth, 1)
            ZStack {
                NotchPanelShape(flare: 6, bottomRadius: 12)
                    .fill(Color.black)
                    .frame(width: width, height: state.height)
                if let a = state.activity {
                    HStack(spacing: 0) {
                        HStack(spacing: 7) {
                            icon(a)
                            Text(a.leading)
                                .foregroundStyle(a.tint)
                                .lineLimit(1)
                        }
                        .frame(width: LiveActivityController.wing - 14, alignment: .leading)
                        Color.clear.frame(width: max(state.notchWidth, 24))
                        HStack(spacing: 6) {
                            if a.dot {
                                Circle().fill(a.trailingTint).frame(width: 6, height: 6)
                                    .shadow(color: a.trailingTint.opacity(0.8), radius: 3)
                            }
                            Text(a.trailing)
                                .foregroundStyle(a.trailingTint)
                                .lineLimit(1)
                        }
                        .frame(width: LiveActivityController.wing - 14, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(state.expanded ? 1 : 0)
                    .blur(radius: state.expanded ? 0 : 4)
                    .animation(state.expanded ? .easeOut(duration: 0.25).delay(0.12) : .easeIn(duration: 0.12),
                               value: state.expanded)
                }
            }
            .frame(width: full, height: geo.size.height, alignment: .top)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func icon(_ a: LiveActivity) -> some View {
        switch a.icon {
        case .brand(let id):
            let identity = ProviderIdentity.identity(for: id)
            BrandMark(kind: identity.mark, size: 14, tint: identity.accent)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(a.tint)
        }
    }
}

// MARK: - Watching for events

/// Turns state changes into live activities. Edge-triggered throughout: a
/// thing is announced when it *becomes* true, never while it stays true.
@MainActor
final class LiveActivityWatcher {
    private let controller: LiveActivityController
    private var knownActivity: [String: AgentSession.Activity] = [:]
    private var announcedLimits: Set<String> = []
    private var lastPressure: MemoryPressure = .normal
    private var lastThermal: ProcessInfo.ThermalState = .nominal
    private var wasTimerRunning = false
    private var lastRemaining: TimeInterval?
    private var lastSummaryEnd: Date?
    private var primed = false

    init(controller: LiveActivityController) {
        self.controller = controller
    }

    /// Called once a second from the app's main tick.
    func check(sessions: [AgentSession], usages: [ProviderUsage], system: SystemSnapshot?, focus: FocusStore,
               backpack: BackpackManager) {
        defer { primed = true }

        // Backpack mode: the lid came back up. Say what happened while it was shut.
        if let summary = backpack.lastSummary, summary.endedAt != lastSummaryEnd {
            lastSummaryEnd = summary.endedAt
            if primed {
                let awake = BackpackManager.Summary.duration(summary.awakeFor)
                var right = summary.agentsFinished == 1 ? "1 finished" : "\(summary.agentsFinished) finished"
                if let a = summary.batteryStart, let b = summary.batteryEnd { right += " · \(a)→\(b)%" }
                controller.post(LiveActivity(icon: .symbol("backpack.fill"), leading: "Awake \(awake)",
                                             trailing: right, tint: HP.ok, trailingTint: .white,
                                             hold: 6, key: "backpack-\(summary.endedAt.timeIntervalSince1970)"),
                                cooldown: 0)
            }
        }

        // Agents: one needs you, or one just finished its turn.
        for s in sessions {
            let before = knownActivity[s.id]
            knownActivity[s.id] = s.activity
            guard primed, let before, before != s.activity else { continue }
            if s.activity == .needsInput {
                controller.post(LiveActivity(icon: .brand(s.providerID),
                                             leading: shortName(s), trailing: AgentStatus.word(s),
                                             tint: .white, trailingTint: HP.amber, dot: true, hold: 6,
                                             key: "need-\(s.id)"), cooldown: 60)
            } else if s.activity == .waiting && (before == .working || before == .needsInput) {
                controller.post(LiveActivity(icon: .brand(s.providerID),
                                             leading: shortName(s), trailing: "finished",
                                             tint: .white, trailingTint: HP.ok, hold: 3.5,
                                             key: "done-\(s.id)"), cooldown: 90)
            }
        }

        // Limits: a window crossing the warning line, once per reset.
        for u in usages {
            for w in u.windows {
                guard let consumed = w.consumedPercent else { continue }
                let key = "\(u.providerID)-\(w.label)-\(w.resetsAt.map { Int($0.timeIntervalSince1970 / 3600) } ?? 0)"
                if consumed >= NotchTheme.highConsumedThreshold {
                    if primed && !announcedLimits.contains(key) {
                        controller.post(LiveActivity(icon: .brand(u.providerID),
                                                     leading: "\(u.displayName) \(w.displayName.lowercased())",
                                                     trailing: "\(Fmt.percent(consumed)) used",
                                                     tint: .white, trailingTint: HP.red, hold: 5,
                                                     key: "limit-\(key)"), cooldown: 3600)
                    }
                    announcedLimits.insert(key)
                }
            }
        }

        // The Mac: memory pressure or heat getting serious.
        if let snap = system {
            if snap.memory.pressure == .critical && lastPressure != .critical && primed {
                controller.post(LiveActivity(icon: .symbol("memorychip"), leading: "Memory",
                                             trailing: "pressure high", tint: HP.amber, trailingTint: HP.amber,
                                             hold: 5, key: "mem"), cooldown: 600)
            }
            lastPressure = snap.memory.pressure
            if snap.thermal.state.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                && lastThermal.rawValue < ProcessInfo.ThermalState.serious.rawValue && primed {
                controller.post(LiveActivity(icon: .symbol("thermometer.high"), leading: "Mac",
                                             trailing: "running hot", tint: HP.amber, trailingTint: HP.amber,
                                             hold: 5, key: "thermal"), cooldown: 600)
            }
            lastThermal = snap.thermal.state
        }

        // Focus: a countdown that ran to its end (not one stopped by hand).
        if wasTimerRunning && !focus.isRunning && primed, let left = lastRemaining, left <= 2.5 {
            controller.post(LiveActivity(icon: .symbol("timer"), leading: "Focus",
                                         trailing: "time's up", tint: .white, trailingTint: HP.ok,
                                         hold: 4, key: "focus"), cooldown: 30)
        }
        wasTimerRunning = focus.isRunning
        lastRemaining = focus.isRunning ? focus.remaining() : nil
    }

    private func shortName(_ s: AgentSession) -> String {
        let name = s.name.trimmingCharacters(in: .whitespaces)
        return name.count > 16 ? String(name.prefix(15)) + "…" : name
    }
}
