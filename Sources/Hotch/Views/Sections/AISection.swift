import SwiftUI

/// Every AI plan window, with the forecast drawn onto the ring: the solid arc
/// is spent, the lighter arc is what the current pace spends before the reset.
/// Usage and forecast used to be two pages that had to be read together; now
/// they are one instrument.
struct AISection: View {
    @ObservedObject var store: UsageStore
    let history: UsageHistoryStore
    let now: Date
    let active: Bool
    let layout: SectionLayout
    let nav: SectionNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.usages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No AI accounts switched on").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HP.text)
                    Button("Open Settings", action: nav.openSettings)
                        .buttonStyle(PillButtonStyle())
                }
                .padding(.top, 8)
            }
            ForEach(Array(store.usages.enumerated()), id: \.element.id) { index, usage in
                ProviderUsageRow(usage: usage, history: history, now: now, active: active,
                                 layout: layout, nav: nav)
                    .modifier(Rise(active: active, index: index))
                if index < store.usages.count - 1 {
                    Rectangle().fill(HP.stroke).frame(height: 1)
                }
            }
            if store.usages.contains(where: { !$0.windows.isEmpty }) {
                HStack(spacing: 8) {
                    Capsule().fill(HP.text2.opacity(0.35)).frame(width: 18, height: 5)
                    Text("Lighter arc: what the current pace spends before the window resets")
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(HP.text3)
                .padding(.top, 10)
                .padding(.leading, layout.isPopover ? 0 : 124)
                .modifier(Rise(active: active, index: store.usages.count))
            }
        }
        .frame(width: layout.width, alignment: .topLeading)
    }
}

struct ProviderUsageRow: View {
    let usage: ProviderUsage
    let history: UsageHistoryStore
    let now: Date
    let active: Bool
    let layout: SectionLayout
    let nav: SectionNav

    @Environment(\.usageDisplayMode) private var mode
    private var identity: ProviderIdentity { ProviderIdentity.identity(for: usage.providerID) }

    private var staleness: String? {
        guard !usage.windows.isEmpty else { return nil }
        let age = now.timeIntervalSince(usage.asOf)
        return age > 120 ? "\(Fmt.duration(age)) old" : nil
    }

    var body: some View {
        if layout.isPopover {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    brandLine
                    Spacer()
                    if let plan = usage.plan { Text(plan).font(.system(size: 11)).foregroundStyle(HP.text3) }
                }
                windows(columns: 1)
                extrasLine
            }
            .padding(.vertical, 12)
        } else {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    brandLine
                    if let plan = usage.plan {
                        Text(plan).font(.system(size: 11)).foregroundStyle(HP.text3).padding(.leading, 26)
                    }
                    if let stale = staleness {
                        Text(stale).font(.system(size: 11)).foregroundStyle(HP.text3).padding(.leading, 26)
                    }
                    ForEach(usage.extras.prefix(2), id: \.self) { extra in
                        Text(extra).font(.system(size: 11)).foregroundStyle(HP.text3)
                            .lineLimit(1).padding(.leading, 26)
                    }
                }
                .frame(width: 112, alignment: .leading)
                windows(columns: max(1, min(3, usage.windows.count)))
            }
            .frame(minHeight: 96)
        }
    }

    private var brandLine: some View {
        HStack(spacing: 8) {
            BrandMark(kind: identity.mark, size: 18, tint: identity.accent)
            Text(usage.displayName.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(1)
                .foregroundStyle(identity.accent)
        }
    }

    @ViewBuilder
    private var extrasLine: some View {
        let parts = usage.extras + [staleness].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(HP.text3)
        }
    }

    @ViewBuilder
    private func windows(columns: Int) -> some View {
        if let balance = usage.balance {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.money(balance.amount, currency: balance.currency))
                    .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(HP.text)
                Text("credit left").font(.system(size: 11.5)).foregroundStyle(HP.text3)
                Spacer()
            }
        } else if usage.windows.isEmpty {
            HStack(spacing: 10) {
                Text(usage.detail ?? (usage.needsSetup ? "needs setup in Settings" : "no recent data"))
                    .font(.system(size: 12))
                    .foregroundStyle(usage.needsSetup ? identity.accent : HP.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if usage.needsSetup && usage.providerID == "claude" {
                    Button("Sign in with Claude Code", action: nav.signInClaude)
                        .buttonStyle(PillButtonStyle())
                } else if usage.needsSetup {
                    Button("Settings", action: nav.openSettings).buttonStyle(PillButtonStyle())
                }
                Spacer(minLength: 0)
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .leading),
                                     count: columns),
                      alignment: .leading, spacing: 10) {
                ForEach(usage.windows.prefix(columns == 1 ? 4 : 3), id: \.self) { window in
                    WindowStat(window: window, providerID: usage.providerID, history: history,
                               now: now, active: active, color: identity.accent,
                               compact: columns > 2)
                }
            }
        }
    }
}

/// One plan window: forecast ring, the number, its name and reset, the verdict.
struct WindowStat: View {
    let window: UsageWindow
    let providerID: String
    let history: UsageHistoryStore
    let now: Date
    let active: Bool
    let color: Color
    var compact: Bool = true

    @Environment(\.usageDisplayMode) private var mode

    var body: some View {
        let reading = WindowReading(window: window, providerID: providerID, history: history,
                                    now: now, mode: mode)
        HStack(spacing: compact ? 9 : 11) {
            ForecastRing(share: reading.share, projected: reading.projected,
                         isCritical: window.isCritical, color: color, active: active,
                         size: compact ? 36 : 40, lineWidth: compact ? 3.6 : 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    RollingNumber(value: window.percent(mode) ?? 0,
                                  text: window.percent(mode).map { "\(Int($0.rounded()))" } ?? "—",
                                  size: 19, color: window.isCritical ? HP.red : HP.text)
                    Text("%").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(HP.text2)
                }
                Text(window.displayName)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2).lineLimit(1)
                if let left = Fmt.remaining(to: window.resetsAt, now: now) {
                    Text(compact ? "resets \(left)" : "resets in \(left)")
                        .font(.system(size: 11)).foregroundStyle(HP.text3).lineLimit(1)
                }
                Text(compact ? reading.compact : reading.verdict)
                    .font(.system(size: compact ? 10.5 : 11, weight: .semibold))
                    .foregroundStyle(reading.verdictColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
