import SwiftUI

/// What a section can ask its surface to do. Closures, so the same section
/// views drive the notch panel and the popover, each with its own page state.
struct SectionNav {
    var go: (PanelPage) -> Void = { _ in }
    var openDetail: (SystemDetailKind?) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var signInClaude: () -> Void = {}
    /// Brings forward the app a session runs in.
    var jump: (AgentSession) -> Void = { _ in }
}

/// Where a section is drawn. The panel is wide and short; the popover is a
/// narrow column. Sections lay themselves out from this rather than guessing.
struct SectionLayout {
    var isPopover: Bool
    /// Width of the content column.
    var width: CGFloat

    static func panel(width: CGFloat) -> SectionLayout { SectionLayout(isPopover: false, width: width) }
    static func popover(width: CGFloat) -> SectionLayout { SectionLayout(isPopover: true, width: width) }
}

/// Reading a window as a forecast ring: the solid share, the share the current
/// pace adds before the reset, and the verdict — all in the user's direction.
struct WindowReading {
    let window: UsageWindow
    let share: Double?
    let projected: Double
    let verdict: String
    let verdictColor: Color
    let alarming: Bool
    /// The verdict without the landing figure, for narrow columns:
    /// "on track", "tight · ~7:06 pm", "runs out · ~9:14 pm".
    let compact: String

    init(window: UsageWindow, providerID: String, history: UsageHistoryStore,
         now: Date, mode: UsageDisplayMode) {
        self.window = window
        let forecast = history.forecast(providerID: providerID,
                                        windowLabel: window.shortWindowLabel, now: now)
        let consumed = window.consumedPercent
        let landing = ForecastDisplay.projectedConsumed(window: window, forecast: forecast, now: now)
        let spend = max(0, ((landing ?? consumed ?? 0) - (consumed ?? 0)) / 100)
        if let consumed {
            if mode == .used {
                share = consumed / 100
                projected = spend
            } else {
                // Remaining: the arc is what is left; the translucent tail is
                // the part of it this pace will spend before the reset.
                let left = 1 - consumed / 100
                share = max(0, left - spend)
                projected = min(spend, left)
            }
        } else {
            share = nil
            projected = 0
        }
        let (outlook, detail) = ForecastDisplay.outlook(forecast: forecast, window: window,
                                                       now: now, mode: mode)
        switch outlook {
        case .collecting:
            verdict = "measuring pace"
            compact = "measuring"
        case .idle:
            verdict = "barely any burn"
            compact = "quiet"
        case .onTrack:
            verdict = detail.isEmpty ? outlook.word : "\(outlook.word) · \(detail)"
            compact = outlook.word
        default:
            verdict = detail.isEmpty ? outlook.word : "\(outlook.word) · \(detail)"
            // "runs out ~9:14 PM" / "tight, cap ~7:06 PM": the time is the
            // useful half, so it survives and the separator goes.
            compact = detail.isEmpty ? outlook.word
                : (outlook == .runsOut ? "runs out \(detail)" : "tight \(detail.replacingOccurrences(of: "cap ", with: ""))")
        }
        alarming = outlook.isAlarming
        verdictColor = outlook.isAlarming ? HP.amber : HP.text3
    }

}

extension UsageWindow {
    /// A human name for the window, from what the provider called it.
    var displayName: String {
        if let scope, !scope.isEmpty { return "\(scope) week" }
        let lower = label.lowercased()
        if lower.hasPrefix("session") || windowMinutes == 300 { return "Session" }
        if lower.hasPrefix("week") || windowMinutes == 10080 { return "Week" }
        if lower.hasPrefix("daily") || windowMinutes == 1440 { return "Day" }
        return label
    }
}

extension AgentSession {
    /// Whether the agent is doing something, for summaries and Backpack mode.
    var isBusy: Bool {
        switch activity {
        case .working, .needsInput: return true
        case .waiting, .ended: return false
        default: return true // .shell: a background shell still running
        }
    }
}

enum AgentStatus {
    static func word(_ s: AgentSession) -> String {
        switch s.activity {
        case .needsInput: return s.providerID == "codex" ? "needs approval" : "needs you"
        case .working: return "working"
        case .waiting: return "idle"
        case .ended: return "ended"
        default: return "shell running"
        }
    }

    static func color(_ s: AgentSession) -> Color {
        let brand = ProviderIdentity.identity(for: s.providerID).accent
        switch s.activity {
        case .needsInput: return HP.amber
        case .working: return brand
        case .waiting, .ended: return HP.text3
        default: return brand.opacity(0.75)
        }
    }

    static func caption(_ s: AgentSession, now: Date) -> String {
        if s.activity == .needsInput, let reason = s.waitingFor, !reason.isEmpty {
            let ago = Fmt.ago(s.lastEventAt, now: now) ?? ""
            return ago.isEmpty ? reason : "\(reason) · \(ago)"
        }
        return SessionDisplay.age(for: s, now: now) ?? ""
    }
}

// Provider fetch failures preserve the last successful snapshot. Its age and
// supplied detail remain visible instead of inventing a connection state.
extension ProviderUsage {
    func isStale(now: Date) -> Bool { now.timeIntervalSince(asOf) > 10 * 60 }

    func freshnessCaption(now: Date) -> String? {
        if needsSetup { return detail ?? "Finish setup in Settings" }
        var parts: [String] = []
        if let detail, !detail.isEmpty { parts.append(detail) }
        if isStale(now: now) {
            parts.append("Last reading \(Fmt.ago(asOf, now: now) ?? "over 10m ago") · may be out of date")
        } else if windows.isEmpty && balance == nil && parts.isEmpty {
            return "No usage reading available"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
