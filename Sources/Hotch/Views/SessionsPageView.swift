import SwiftUI

/// The sessions page: what the agents on this machine are doing right now,
/// without cycling through terminal tabs to find out.
///
/// Same reading discipline as usage rows: every state shown is derived from
/// local files and says what it actually knows. "Needs input" is a heuristic —
/// a tool call that has sat unanswered longer than a tool plausibly runs — and
/// it is amber, not red, because a session waiting on a keystroke is a nudge
/// rather than an emergency.
enum SessionDisplay {
    /// The status word and its colour, per surface.
    ///
    /// **Two of these were white.** `NotchTheme.unitText` and `mutedText` are
    /// `Color.white` at low opacity — correct on the near-black panel, and on
    /// the light popover they rendered "waiting" as white-on-white and "ended"
    /// as very nearly the same. The page had a state it simply did not show.
    ///
    /// The same mistake as `RingGauge`'s track: a component written for the
    /// panel, reused on the popover, carrying a literal colour that only ever
    /// made sense against black. The popover's equivalents are semantic
    /// (`Color.secondary`), so they follow the system's light and dark
    /// appearance instead of assuming one. `working` and `needs input` keep
    /// their brand and amber accents, which are saturated enough to read on
    /// either background — which is exactly why only two of the four broke, and
    /// why it was easy to miss.
    static func status(for session: AgentSession,
                       surface: SessionContextGauge.Surface = .panel)
    -> (label: String, color: Color) {
        let identity = ProviderIdentity.identity(for: session.providerID)
        let panel = surface == .panel
        switch session.activity {
        case .working: return ("working", identity.accent)
        case .shell: return ("shell", identity.accent)
        case .needsInput: return ("needs input", NotchTheme.attention)
        case .waiting:
            return ("waiting", panel ? NotchTheme.unitText : PopoverTheme.secondaryText)
        case .ended:
            return ("ended", panel ? NotchTheme.mutedText : PopoverTheme.mutedText)
        }
    }

    /// The age caption. Working sessions report how long they have been at it
    /// (the interesting number is the run, not the last write); everything else
    /// reports how long ago it last moved.
    static func age(for session: AgentSession, now: Date) -> String? {
        if session.activity == .working, let started = session.startedAt {
            return "for " + Fmt.duration(max(0, now.timeIntervalSince(started)))
        }
        return Fmt.ago(session.lastEventAt, now: now)
    }

    static let emptyText = "no recent sessions \u{2014} Claude Code and Codex activity appears here"
}

// MARK: - Context gauge

/// The per-session context meter: the usage ring at half size, reporting the
/// one window the usage page cannot see.
///
/// **Why a ring and not a number.** The plan windows on the home page are rings,
/// and this is the same question asked of a different window — how much room is
/// left before the thing stops going. Giving it its own vocabulary would mean
/// two meters on two pages measuring headroom and looking unrelated. So it is
/// the same instrument: same anti-clockwise sweep, same brand gradient, same red
/// past 85%, same Used/Remaining preference. Only smaller, because five of them
/// share a page with nothing else to anchor against.
///
/// A session with nothing readable draws the dim track and an em dash. That is
/// the same distinction `RingGauge` already makes between "at zero" and
/// "unmeasured", and it matters more here than on the usage page: a fresh Codex
/// thread that has not reported a turn yet is not a session at 0% context.
struct SessionContextGauge: View {
    let session: AgentSession
    /// Drives the ring's draw-in. The popover has no expansion state and passes
    /// true; the panel hands down the same flag its rows animate on.
    var active: Bool = true
    var surface: Surface = .panel

    @Environment(\.usageDisplayMode) private var mode

    enum Surface {
        case panel
        case popover

        var primary: Color { self == .panel ? NotchTheme.primaryText : PopoverTheme.primaryText }
        var muted: Color { self == .panel ? NotchTheme.mutedText : PopoverTheme.mutedText }
        /// White at low opacity on the panel; the popover's semantic equivalent,
        /// which survives a light background.
        var track: Color { self == .panel ? NotchTheme.ringTrack : PopoverTheme.track }
        var trackDim: Color { self == .panel ? NotchTheme.ringTrackDim : PopoverTheme.trackDim }
        var valueSize: CGFloat { 12 }
        var captionSize: CGFloat { self == .panel ? 9 : PopoverTheme.captionSize - 1 }
        /// Same on both surfaces. Trimming it for the narrower popover was the
        /// obvious saving and the wrong one: it bought the name a few points
        /// and truncated the *number* instead, so every row read "272.9k us…".
        /// The figure is the content; the name is the thing that elides
        /// gracefully. The popover buys its width back from the status column.
        var columnWidth: CGFloat { NotchTheme.contextColumnWidth }
        /// "1h 9m ago" is the widest thing the popover's status column holds,
        /// set two points smaller than the panel's.
        var statusWidth: CGFloat {
            self == .panel ? NotchTheme.sessionStatusColumnWidth
                           : NotchTheme.sessionStatusColumnWidth - 8
        }
    }

    private var identity: ProviderIdentity {
        ProviderIdentity.identity(for: session.providerID)
    }

    var body: some View {
        HStack(spacing: 7) {
            RingGauge(share: session.contextFillShare(mode),
                      isCritical: session.contextIsCritical,
                      identity: identity,
                      active: active,
                      size: NotchTheme.contextRingSize,
                      lineWidth: NotchTheme.contextRingLineWidth,
                      track: surface.track,
                      trackDim: surface.trackDim)

            VStack(alignment: .leading, spacing: 1) {
                if let percent = session.contextPercent(mode) {
                    Text(Fmt.percent(percent))
                        .font(.system(size: surface.valueSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(surface.primary)
                    if let caption = session.contextTokenCaption(mode) {
                        Text(caption)
                            .font(.system(size: surface.captionSize))
                            .foregroundStyle(surface.muted)
                            .lineLimit(1)
                    }
                } else {
                    Text("\u{2014}")
                        .font(.system(size: surface.valueSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(surface.muted)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: surface.columnWidth, alignment: .leading)
        .help("Context window \u{00B7} \(session.contextTokenCaption(mode) ?? "no reading")")
    }
}

// MARK: - Panel row

struct SessionRowView: View {
    let session: AgentSession
    let now: Date
    let active: Bool
    let rowIndex: Int
    /// Only the exit reads it — see `PanelMotion.rowOut(_:of:)`.
    let rowCount: Int

    private var identity: ProviderIdentity {
        ProviderIdentity.identity(for: session.providerID)
    }

    var body: some View {
        let status = SessionDisplay.status(for: session)

        HStack(spacing: 12) {
            BrandMark(kind: identity.mark, size: 15, tint: identity.accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryText)
                    .lineLimit(1)
                if !session.projectName.isEmpty {
                    Text(session.projectName)
                        .font(.system(size: 9.5))
                        .foregroundStyle(NotchTheme.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            SessionContextGauge(session: session, active: active)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 5, height: 5)
                        // The one state worth spotting from across the room
                        // gets a faint halo; everything else stays quiet.
                        .shadow(color: session.activity == .needsInput
                                    ? status.color.opacity(0.8) : .clear,
                                radius: 3)
                    Text(status.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(status.color)
                }
                if let age = SessionDisplay.age(for: session, now: now) {
                    Text(age)
                        .font(.system(size: 9.5))
                        .foregroundStyle(NotchTheme.mutedText)
                }
            }
            .frame(width: NotchTheme.sessionStatusColumnWidth, alignment: .trailing)
        }
        .frame(height: NotchTheme.sessionRowHeight)
        .opacity(active ? 1 : 0)
        .offset(y: active ? 0 : -4)
        .animation(active ? PanelMotion.rowIn(rowIndex)
                          : PanelMotion.rowOut(rowIndex, of: rowCount),
                   value: active)
    }
}

/// The row stack for the panel's sessions page.
struct SessionsPageRows: View {
    let sessions: [AgentSession]
    let now: Date
    let active: Bool

    var body: some View {
        VStack(spacing: NotchTheme.sessionRowGap) {
            if sessions.isEmpty {
                Text(SessionDisplay.emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.mutedText)
                    .frame(maxWidth: .infinity, minHeight: NotchTheme.sessionRowHeight)
                    .opacity(active ? 1 : 0)
                    .animation(PanelMotion.contentIn(after: active ? PanelMotion.brandLead : 0),
                               value: active)
            }
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                SessionRowView(session: session, now: now, active: active,
                               rowIndex: index, rowCount: sessions.count)
            }
        }
    }
}

// MARK: - Popover section

/// The same list re-laid for the popover's narrow column.
struct PopoverSessionsSection: View {
    let sessions: [AgentSession]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if sessions.isEmpty {
                Text(SessionDisplay.emptyText)
                    .font(.system(size: PopoverTheme.bodySize))
                    .foregroundStyle(PopoverTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 {
                    Rectangle()
                        .fill(PopoverTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 10)
                }
                row(session)
            }
        }
    }

    private func row(_ session: AgentSession) -> some View {
        let identity = ProviderIdentity.identity(for: session.providerID)
        let status = SessionDisplay.status(for: session, surface: .popover)

        return HStack(spacing: 9) {
            BrandMark(kind: identity.mark, size: 14, tint: identity.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: PopoverTheme.titleSize, weight: .semibold))
                    .foregroundStyle(PopoverTheme.primaryText)
                    .lineLimit(1)
                if !session.projectName.isEmpty {
                    Text(session.projectName)
                        .font(.system(size: PopoverTheme.captionSize))
                        .foregroundStyle(PopoverTheme.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            SessionContextGauge(session: session, surface: .popover)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Circle().fill(status.color).frame(width: 5, height: 5)
                    Text(status.label)
                        .font(.system(size: PopoverTheme.captionSize, weight: .medium))
                        .foregroundStyle(status.color)
                }
                if let age = SessionDisplay.age(for: session, now: now) {
                    Text(age)
                        .font(.system(size: PopoverTheme.captionSize))
                        .foregroundStyle(PopoverTheme.mutedText)
                }
            }
            .frame(width: SessionContextGauge.Surface.popover.statusWidth, alignment: .trailing)
        }
    }
}
