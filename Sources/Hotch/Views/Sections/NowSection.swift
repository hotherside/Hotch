import SwiftUI

/// Home: one glance at everything. The AI limits that constrain you, which
/// agent wants you, and how the Mac is doing — each a tap away from its own
/// section.
struct NowSection: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var system: SystemMonitor
    let history: UsageHistoryStore
    let now: Date
    let active: Bool
    let layout: SectionLayout
    let nav: SectionNav

    @Environment(\.usageDisplayMode) private var mode

    private var windowed: [ProviderUsage] {
        store.usages.filter { !$0.windows.isEmpty || $0.balance != nil || $0.needsSetup || $0.detail != nil }
    }

    var body: some View {
        VStack(spacing: 8) {
            aiRow
                .modifier(Rise(active: active, index: 0))
            AgentsStrip(sessions: sessionStore.sessions, now: now, layout: layout, nav: nav)
                .modifier(Rise(active: active, index: 1))
            MacTilesRow(system: system, layout: layout, nav: nav)
                .modifier(Rise(active: active, index: 2))
        }
        .frame(width: layout.width, alignment: .top)
    }

    // MARK: AI

    @ViewBuilder
    private var aiRow: some View {
        let usages = windowed
        if usages.isEmpty {
            Button(action: nav.openSettings) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HP.text2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No AI accounts connected yet")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(HP.text)
                        Text("Sign in to Claude Code or Codex in Settings")
                            .font(.system(size: 11.5)).foregroundStyle(HP.text3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: layout.isPopover ? 64 : 96)
            }
            .buttonStyle(TileButtonStyle())
        } else {
            let columns = layout.isPopover ? 1 : min(3, usages.count)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(usages.prefix(layout.isPopover ? 4 : 3)) { usage in
                    ProviderGlanceTile(usage: usage, history: history, now: now, active: active,
                                       showMinis: columns <= 2, compact: layout.isPopover,
                                       narrow: columns >= 3)
                        .onTapGesture { nav.go(.ai) }
                }
            }
        }
    }
}

/// Staggered arrival inside a section: each row rises a few points into place.
struct Rise: ViewModifier {
    let active: Bool
    let index: Int
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: active ? 0 : -6)
            .animation(active ? .spring(duration: 0.34, bounce: 0.08).delay(0.05 + Double(index) * 0.035)
                              : .easeOut(duration: 0.14),
                       value: active)
    }
}

// MARK: - Provider glance tile

struct ProviderGlanceTile: View {
    let usage: ProviderUsage
    let history: UsageHistoryStore
    let now: Date
    let active: Bool
    var showMinis: Bool = true
    var compact: Bool = false
    /// Three tiles in a row: smaller ring, shorter captions.
    var narrow: Bool = false

    @Environment(\.usageDisplayMode) private var mode
    @State private var hovering = false

    private var identity: ProviderIdentity { ProviderIdentity.identity(for: usage.providerID) }

    /// The window actually constraining you: the most consumed.
    private var tightest: UsageWindow? {
        usage.windows.max { ($0.consumedPercent ?? -1) < ($1.consumedPercent ?? -1) }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let window = tightest {
                let reading = WindowReading(window: window, providerID: usage.providerID,
                                            history: history, now: now, mode: mode)
                ZStack {
                    ForecastRing(share: reading.share, projected: reading.projected,
                                 isCritical: window.isCritical, color: identity.accent,
                                 active: active, size: compact || narrow ? 44 : 52,
                                 lineWidth: compact || narrow ? 4 : 4.5)
                    BrandMark(kind: identity.mark, size: compact || narrow ? 15 : 18, tint: identity.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(usage.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(identity.accent)
                        Text(window.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(HP.text3)
                    }
                    .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        RollingNumber(value: window.percent(mode) ?? 0,
                                      text: window.percent(mode).map { "\(Int($0.rounded()))" } ?? "—",
                                      size: compact || narrow ? 20 : 23,
                                      color: window.isCritical ? HP.red : HP.text)
                        Text("%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(HP.text2)
                        if !narrow {
                            Text(" \(mode.unit)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(HP.text3)
                        }
                    }
                    HStack(spacing: 4) {
                        if let left = Fmt.remaining(to: window.resetsAt, now: now) {
                            Text(narrow ? left : "resets in \(left)").foregroundStyle(HP.text2)
                        }
                        if !narrow || reading.alarming {
                            Text(reading.alarming ? (reading.compact.components(separatedBy: " · ").first ?? "") : reading.compact)
                                .foregroundStyle(reading.verdictColor)
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                    if showMinis, let others = otherWindowsLine(excluding: window) {
                        Text(others)
                            .font(.system(size: 11))
                            .foregroundStyle(HP.text3)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
            } else if let balance = usage.balance {
                ZStack {
                    Circle().stroke(HP.track, lineWidth: 4.5).frame(width: 52, height: 52)
                    BrandMark(kind: identity.mark, size: 18, tint: identity.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(usage.displayName).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(identity.accent)
                    Text(Fmt.money(balance.amount, currency: balance.currency))
                        .font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(HP.text)
                    Text("credit left").font(.system(size: 11)).foregroundStyle(HP.text3)
                }
                Spacer(minLength: 0)
            } else {
                ZStack {
                    Circle().stroke(HP.track.opacity(0.6), lineWidth: 4.5).frame(width: 52, height: 52)
                    BrandMark(kind: identity.mark, size: 18, tint: identity.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(usage.displayName).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(identity.accent)
                    Text(usage.detail ?? (usage.needsSetup ? "needs setup in Settings" : "no data yet"))
                        .font(.system(size: 11.5)).foregroundStyle(HP.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: compact ? 70 : 96)
        .background(RoundedRectangle(cornerRadius: HP.tileRadius, style: .continuous)
            .fill(hovering ? HP.tileHover : HP.tile))
        .overlay(RoundedRectangle(cornerRadius: HP.tileRadius, style: .continuous)
            .strokeBorder(HP.stroke, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: HP.tileRadius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }

    /// "Week 41% · Fable week 22%", or the provider's extras ("2 reset
    /// credits") when it has only the one window.
    private func otherWindowsLine(excluding window: UsageWindow) -> String? {
        let others = usage.windows.filter { $0 != window }
            .map { "\($0.displayName) \($0.percent(mode).map { Fmt.percent($0) } ?? "—")" }
        let parts = others.isEmpty ? Array(usage.extras.prefix(1)) : others
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func minis(excluding window: UsageWindow) -> some View {
        let others = usage.windows.filter { $0 != window }.prefix(2)
        let extras = usage.extras.prefix(max(0, 2 - others.count))
        if !others.isEmpty || !extras.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(others), id: \.self) { w in
                    HStack(spacing: 10) {
                        Text(w.displayName).foregroundStyle(HP.text3)
                        Spacer(minLength: 4)
                        Text(w.percent(mode).map { Fmt.percent($0) } ?? "—")
                            .fontWeight(.semibold)
                            .foregroundStyle(w.isCritical ? HP.red : HP.text2)
                    }
                }
                ForEach(Array(extras), id: \.self) { extra in
                    Text(extra).foregroundStyle(HP.text3).lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .frame(width: 104, alignment: .leading)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(HP.stroke).frame(width: 1)
            }
        }
    }
}

// MARK: - Agents strip

struct AgentsStrip: View {
    let sessions: [AgentSession]
    let now: Date
    let layout: SectionLayout
    let nav: SectionNav

    private var live: [AgentSession] { sessions.filter { $0.activity != .ended } }
    private var needing: [AgentSession] { sessions.filter { $0.activity == .needsInput } }
    private var working: Int { sessions.filter { $0.isBusy && $0.activity != .needsInput }.count }
    private var idle: Int { sessions.filter { $0.activity == .waiting }.count }

    var body: some View {
        Button { nav.go(.agents) } label: {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, layout.isPopover ? 10 : 0)
                .frame(minHeight: 50)
        }
        .buttonStyle(TileButtonStyle())
    }

    @ViewBuilder
    private var content: some View {
        let row = HStack(spacing: 10) {
            Kicker(text: "Sessions")
            HStack(spacing: 4) {
                ForEach(live.prefix(8)) { s in
                    Circle().fill(AgentStatus.color(s)).frame(width: 7, height: 7)
                }
            }
            summary
            Spacer(minLength: 0)
        }
        if layout.isPopover {
            VStack(alignment: .leading, spacing: 8) {
                row
                if let first = needing.first { callout(first) }
            }
        } else {
            HStack(spacing: 10) {
                row
                if let first = needing.first { callout(first) }
            }
        }
    }

    private var summary: some View {
        Group {
            if sessions.isEmpty {
                Text("no sessions right now").foregroundStyle(HP.text3)
            } else {
                (Text(needing.count > 1 ? "\(needing.count) need you · " : "").foregroundColor(HP.amber)
                 + Text("\(working) working").foregroundColor(HP.text)
                 + Text(" · \(idle) idle").foregroundColor(HP.text3))
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(1)
    }

    private func callout(_ s: AgentSession) -> some View {
        HStack(spacing: 7) {
            Circle().fill(HP.amber).frame(width: 6, height: 6)
                .shadow(color: HP.amber.opacity(0.8), radius: 3)
            Text(s.name).foregroundStyle(HP.text).lineLimit(1)
            Text(AgentStatus.word(s)).foregroundStyle(HP.amber).lineLimit(1).fixedSize()
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: layout.isPopover ? .infinity : 290, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HP.amber.opacity(0.14)))
    }
}

// MARK: - Mac tiles row

struct MacTilesRow: View {
    @ObservedObject var system: SystemMonitor
    let layout: SectionLayout
    let nav: SectionNav

    var body: some View {
        let columns = layout.isPopover ? 3 : 6
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            if let snap = system.latest {
                tile(.cpu, label: "CPU", trailing: SysFmt.temp(snap.thermal.cpuTempC)) {
                    value(snap.cpu.total, "\(SysFmt.percent(snap.cpu.total))", unit: "%")
                } chart: {
                    Sparkline(values: Array(system.cpuHistory.suffix(30)), maxValue: 100, color: HP.cpu)
                }
                tile(.gpu, label: "GPU", trailing: SysFmt.temp(snap.thermal.gpuTempC)) {
                    value(snap.gpu?.utilization ?? 0, snap.gpu.map { SysFmt.percent($0.utilization) } ?? "—", unit: "%")
                } chart: {
                    Sparkline(values: Array(system.gpuHistory.suffix(30)), maxValue: 100, color: HP.gpu)
                }
                tile(.memory, label: "Memory", trailing: nil, trailingColor: HP.pressure(snap.memory.pressure),
                     trailingDot: true) {
                    value(memPercent(snap), SysFmt.percent(memPercent(snap)), unit: "%")
                } chart: {
                    MemoryBar(memory: snap.memory).frame(height: 5)
                }
                tile(.network, label: "Net", trailing: nil) {
                    VStack(alignment: .leading, spacing: 0) {
                        (Text("↓ ").foregroundColor(HP.down) + Text(SysFmt.rateShort(snap.network.downBytesPerSecond)))
                        (Text("↑ ").foregroundColor(HP.up) + Text(SysFmt.rateShort(snap.network.upBytesPerSecond)))
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(HP.text)
                } chart: {
                    MirrorSparkline(above: Array(system.downHistory.suffix(30)),
                                    below: Array(system.upHistory.suffix(30)),
                                    aboveColor: HP.down, belowColor: HP.up, lineWidth: 1.2)
                }
                tile(.disk, label: "Free", trailing: nil) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int((Double(snap.disk.freeBytes) / 1_073_741_824).rounded()))")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("GB").font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
                    }
                    .foregroundStyle(HP.text)
                } chart: {
                    let used = snap.disk.totalBytes > 0
                        ? 1 - Double(snap.disk.freeBytes) / Double(snap.disk.totalBytes) : 0
                    SegmentBar(segments: [.init(fraction: used, color: HP.disk)], height: 5)
                }
                if let power = snap.power, power.hasBattery {
                    tile(.power, label: "Battery", trailing: nil) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            RollingNumber(value: power.batteryPercent, text: SysFmt.percent(power.batteryPercent))
                            Text(power.isCharging ? "% ⚡︎" : "%")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
                                .lineLimit(1)
                        }
                    } chart: {
                        SegmentBar(segments: [.init(fraction: power.batteryPercent / 100,
                                                    color: power.batteryPercent <= 20 ? HP.red : HP.power)],
                                   height: 5)
                    }
                } else {
                    tile(.power, label: "Thermal", trailing: nil) {
                        Text(SysFmt.thermal(snap.thermal.state))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(snap.thermal.state.rawValue >= 2 ? HP.amber : HP.text)
                    } chart: {
                        Sparkline(values: Array(system.powerHistory.suffix(30)), color: HP.power)
                    }
                }
            } else {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: HP.tileRadius, style: .continuous)
                        .fill(HP.tile).frame(height: 80)
                }
            }
        }
    }

    private func memPercent(_ s: SystemSnapshot) -> Double {
        guard s.memory.totalBytes > 0 else { return 0 }
        return Double(s.memory.usedBytes) / Double(s.memory.totalBytes) * 100
    }

    private func value(_ v: Double, _ text: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0.5) {
            RollingNumber(value: v, text: text)
            Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
        }
    }

    private func tile<V: View, C: View>(_ kind: SystemDetailKind, label: String, trailing: String?,
                                        trailingColor: Color = HP.text3, trailingDot: Bool = false,
                                        @ViewBuilder value: () -> V,
                                        @ViewBuilder chart: () -> C) -> some View {
        Button { nav.openDetail(kind) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Kicker(text: label)
                    Spacer(minLength: 2)
                    if trailingDot {
                        Circle().fill(trailingColor).frame(width: 6, height: 6)
                    } else if let trailing {
                        Text(trailing).font(.system(size: 10, weight: .medium)).foregroundStyle(trailingColor)
                    }
                }
                Spacer(minLength: 2)
                value()
                Spacer(minLength: 4)
                chart().frame(height: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(height: 80)
        }
        .buttonStyle(TileButtonStyle())
    }
}

/// Memory composition, App → Wired → Compressed → Cached, in one hue.
struct MemoryBar: View {
    let memory: MemoryReading
    var height: CGFloat = 5
    var body: some View {
        let total = max(1, Double(memory.totalBytes))
        SegmentBar(segments: [
            .init(fraction: Double(memory.appBytes) / total, color: HP.memory),
            .init(fraction: Double(memory.wiredBytes) / total, color: HP.memory.opacity(0.62)),
            .init(fraction: Double(memory.compressedBytes) / total, color: HP.memory.opacity(0.38)),
            .init(fraction: Double(memory.cachedBytes) / total, color: HP.memory.opacity(0.18)),
        ], height: height)
    }
}
