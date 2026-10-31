import SwiftUI

/// What every agent on this Mac is doing, read from the vendors' own records:
/// Claude Code's session registry states its status outright (working, a shell
/// running, waiting on you and why, idle), and Codex lists its threads.
struct AgentsSection: View {
    let sessions: [AgentSession]
    let now: Date
    let active: Bool
    let layout: SectionLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No agent sessions right now")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(HP.text)
                    Text("Claude Code (desktop, terminal, VS Code) and Codex appear here as they run.")
                        .font(.system(size: 11.5)).foregroundStyle(HP.text3)
                }
                .padding(.top, 8)
            }
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                AgentRow(session: session, now: now, active: active, compact: layout.isPopover)
                    .modifier(Rise(active: active, index: min(index, 6)))
                if index < sessions.count - 1 {
                    Rectangle().fill(HP.stroke).frame(height: 1)
                }
            }
        }
        .frame(width: layout.width, alignment: .topLeading)
    }
}

struct AgentRow: View {
    let session: AgentSession
    let now: Date
    let active: Bool
    var compact: Bool = false

    @Environment(\.usageDisplayMode) private var mode
    private var identity: ProviderIdentity { ProviderIdentity.identity(for: session.providerID) }

    /// The step in flight when there is one: the command waiting for
    /// approval, or what a working session is doing. Otherwise where it runs.
    private var subtitle: String {
        if session.activity == .needsInput, let ask = session.step?.command ?? session.step?.label { return ask }
        if session.activity <= .shell, let step = session.step { return step.label }
        return [session.projectName.isEmpty ? nil : session.projectName, session.surface, compact ? nil : session.model]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HP.tile)
                RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(HP.stroke, lineWidth: 1)
                BrandMark(kind: identity.mark, size: 15, tint: identity.accent)
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .topTrailing) {
                if session.activity == .working || session.activity == .needsInput {
                    Circle().fill(AgentStatus.color(session))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                        .modifier(Pulse(on: session.activity == .working))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.activity == .ended ? HP.text2 : HP.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(HP.text3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !compact {
                HStack(spacing: 7) {
                    RingGauge(share: session.contextFillShare(mode),
                              isCritical: session.contextIsCritical,
                              identity: identity,
                              active: active,
                              size: 20, lineWidth: 2.6,
                              track: HP.track, trackDim: HP.track.opacity(0.6))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.contextPercent(mode).map { Fmt.percent($0) } ?? "—")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(HP.text)
                        Text("context").font(.system(size: 10)).foregroundStyle(HP.text3)
                    }
                }
                .frame(width: 78, alignment: .leading)
                .help(session.contextTokenCaption(mode).map { "Context window · \($0)" } ?? "No context reading")
            }

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(AgentStatus.color(session)).frame(width: 6, height: 6)
                    Text(AgentStatus.word(session))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentStatus.color(session))
                Text(AgentStatus.caption(session, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(HP.text3)
                    .lineLimit(1)
            }
            .frame(width: compact ? 104 : 132, alignment: .trailing)
        }
        .frame(height: 50)
    }
}

/// A slow breath on the status dot of a working agent: alive, not alarming.
struct Pulse: ViewModifier {
    let on: Bool
    @State private var phase = false
    func body(content: Content) -> some View {
        content
            .opacity(on && phase ? 0.45 : 1)
            .animation(on ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { if on { phase = true } }
    }
}
