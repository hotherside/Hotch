import SwiftUI

/// The compact card: Hotch's one piece of content, shown by whichever anchor
/// is in use (the screen-edge rail, the floating pill or orb, the menu bar
/// popover, the keyboard shortcut).
///
/// 360pt wide and set about a fifth smaller than the first Hotch 2 panel,
/// which was 640 wide with 23pt numbers and read as a slab on a 14" screen.
/// Height is whatever the section needs, capped so a busy list scrolls.
enum CardMetrics {
    static let width: CGFloat = 360
    static let inset: CGFloat = 10
    static var column: CGFloat { width - inset * 2 }
    static let maxSectionHeight: CGFloat = 430
    static let radius: CGFloat = 18
}

/// Type scale for the card.
enum CT {
    static let kicker: CGFloat = 11
    static let caption: CGFloat = 11
    static let body: CGFloat = 12
    static let title: CGFloat = 13
    static let value: CGFloat = 17
    static let smallValue: CGFloat = 14.5
}

struct CompactCard: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var focus: FocusStore
    @ObservedObject var pages: PopoverPageModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var backpack: BackpackManager
    let now: Date
    var history: UsageHistoryStore = .shared
    /// The rail carries its own section icons, so its card hides the tab row.
    var showsTabs: Bool = true
    /// The popover adds refresh and quit to the footer.
    var showsAppButtons: Bool = false
    var scrollable: Bool = true
    var onRefresh: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSignInClaude: () -> Void = {}
    var onJump: (AgentSession) -> Void = { _ in }

    @Environment(\.usageDisplayMode) private var mode

    private var nav: SectionNav {
        SectionNav(go: { pages.select($0) },
                   openDetail: { kind in
                       withAnimation(HMotion.detail) {
                           if pages.page != .mac { pages.page = .mac }
                           pages.macDetail = kind
                       }
                   },
                   openSettings: onOpenSettings,
                   signInClaude: onSignInClaude,
                   jump: onJump)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 28)
                .padding(.bottom, 6)
            section
                .frame(width: CardMetrics.column, alignment: .topLeading)
            footer
                .frame(height: 24)
                .padding(.top, 6)
        }
        .padding(.horizontal, CardMetrics.inset)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(width: CardMetrics.width, alignment: .topLeading)
        .onAppear { system.setDemand(.panel, for: "card") }
        .onDisappear { system.setDemand(.idle, for: "card") }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if showsTabs {
                HotchTabBar(selection: Binding(get: { pages.page }, set: { pages.select($0) }),
                            dimSelection: pages.backpackCard,
                            compact: true,
                            onSelect: { pages.select($0) })
            } else {
                Kicker(text: pages.backpackCard ? "Backpack" : pages.page.wingTitle)
            }
            Spacer(minLength: 4)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var section: some View {
        let layout = SectionLayout.popover(width: CardMetrics.column)
        let content = Group {
            if pages.backpackCard {
                BackpackCard(backpack: backpack, sessions: sessionStore.sessions, now: now,
                             layout: layout, active: true)
            } else {
                switch pages.page {
                case .now:
                    CompactNow(store: store, sessionStore: sessionStore, system: system,
                               history: history, now: now, nav: nav)
                case .ai:
                    CompactAI(store: store, history: history, now: now, nav: nav)
                case .agents:
                    CompactAgents(sessions: sessionStore.sessions, now: now, onJump: onJump)
                case .mac:
                    if let detail = pages.macDetail {
                        MacDetailView(system: system, kind: detail, layout: layout, nav: nav)
                    } else {
                        CompactMac(system: system, nav: nav)
                    }
                case .focus:
                    PopoverFocusSection(focus: focus, now: now)
                case .clipboard:
                    PopoverClipboardSection(items: clipboard.items, enabled: clipboard.enabled, now: now,
                                            onCopy: { clipboard.copyBack($0) })
                }
            }
        }
        .id(pages.backpackCard ? "bp" : "\(pages.page.rawValue)-\(pages.macDetail?.rawValue ?? "")")
        .transition(HMotion.sectionTransition)

        // Always the same container: swapping a scroll view for a plain stack
        // between sections rebuilt the whole area, and for a moment the old
        // and new sections stood one above the other.
        if scrollable {
            ScrollView(.vertical) { content }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: CardMetrics.maxSectionHeight)
                .fixedSize(horizontal: false, vertical: true)
                .animation(HMotion.section, value: pages.page)
                .animation(HMotion.section, value: pages.backpackCard)
                .animation(HMotion.detail, value: pages.macDetail)
        } else {
            content
                .animation(HMotion.section, value: pages.page)
                .animation(HMotion.section, value: pages.backpackCard)
                .animation(HMotion.detail, value: pages.macDetail)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Text(footerText)
                .font(.system(size: CT.caption))
                .foregroundStyle(HP.text3)
                .lineLimit(1)
            Spacer(minLength: 6)
            button(backpack.isOn ? "backpack.fill" : "backpack", help: "Backpack mode",
                   tint: backpack.isOn ? HP.ok : HP.text2, selected: pages.backpackCard) {
                withAnimation(HMotion.section) { pages.backpackCard.toggle() }
            }
            if showsAppButtons {
                button("arrow.clockwise", help: "Refresh now", action: onRefresh)
            }
            button("gearshape", help: "Settings", action: onOpenSettings)
            if showsAppButtons {
                button("power", help: "Quit Hotch", action: onQuit)
            }
        }
    }

    private var footerText: String {
        if pages.backpackCard { return backpack.footerLine }
        switch pages.page {
        case .now, .ai:
            if store.isRefreshing { return "Checking usage…" }
            return Fmt.ago(store.lastRefresh, now: now).map { "Checked \($0)" } ?? "No usage check yet"
        case .agents: return sessionStore.summaryLine ?? "from each agent's own records"
        case .mac: return system.latest == nil ? "Waiting for Mac readings" : "live · every second"
        case .focus: return ""
        case .clipboard: return clipboard.enabled ? "memory only" : "clipboard history is off"
        }
    }

    private func button(_ symbol: String, help: String, tint: Color = HP.text2, selected: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Now

struct CompactNow: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var system: SystemMonitor
    let history: UsageHistoryStore
    let now: Date
    let nav: SectionNav

    private var shown: [ProviderUsage] {
        store.usages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CompactAgentsStrip(sessions: sessionStore.sessions, nav: nav)
            Kicker(text: "AI capacity").padding(.horizontal, 2)
            if shown.isEmpty {
                Button(action: nav.openSettings) {
                    HStack {
                        Text("No AI accounts connected yet").font(.system(size: CT.body, weight: .semibold))
                        Spacer()
                        Text("Settings").font(.system(size: CT.caption)).foregroundStyle(HP.text3)
                    }
                    .padding(.horizontal, 10).frame(height: 40)
                }
                .buttonStyle(TileButtonStyle(radius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.prefix(4).enumerated()), id: \.element.id) { index, usage in
                        if index > 0 { Rectangle().fill(HP.stroke).frame(height: 1) }
                        Button {
                            if usage.needsSetup { nav.openSettings() } else { nav.go(.ai) }
                        } label: {
                            CompactProviderRow(usage: usage, history: history, now: now, nav: nav)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(.horizontal, 10)
                .tile(radius: 12)
            }
            CompactMacSummary(system: system, nav: nav)
        }
    }
}

struct CompactProviderRow: View {
    let usage: ProviderUsage
    let history: UsageHistoryStore
    let now: Date
    let nav: SectionNav

    @Environment(\.usageDisplayMode) private var mode
    private var identity: ProviderIdentity { ProviderIdentity.identity(for: usage.providerID) }

    private var tightest: UsageWindow? {
        usage.windows.max { ($0.consumedPercent ?? -1) < ($1.consumedPercent ?? -1) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                if let window = tightest {
                    ForecastRing(share: window.fillShare(mode), isCritical: window.isCritical,
                                 color: identity.accent, size: 32, lineWidth: 3)
                } else {
                    Circle().stroke(HP.track, lineWidth: 3).frame(width: 32, height: 32)
                }
                BrandMark(kind: identity.mark, size: 13, tint: identity.accent)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(usage.displayName).fontWeight(.semibold).foregroundStyle(HP.text)
                    Spacer(minLength: 3)
                    if let window = tightest {
                        Text(window.percent(mode).map { "\(Fmt.percent($0)) \(mode.unit)" } ?? "No reading")
                            .fontWeight(.semibold)
                            .foregroundStyle(window.isCritical ? HP.amber : HP.text)
                            .monospacedDigit()
                    } else if let balance = usage.balance {
                        Text("\(Fmt.money(balance.amount, currency: balance.currency)) left")
                            .fontWeight(.semibold).foregroundStyle(HP.text)
                    }
                }
                .font(.system(size: CT.body))
                if let window = tightest {
                    Text([window.displayName,
                          Fmt.remaining(to: window.resetsAt, now: now).map { "Resets \($0)" } ?? "Reset time unavailable"]
                        .joined(separator: " · "))
                        .font(.system(size: CT.caption)).foregroundStyle(HP.text2)
                        .lineLimit(1)
                }
                if let status = usage.freshnessCaption(now: now) {
                    Text(status).font(.system(size: CT.caption))
                        .foregroundStyle(usage.needsSetup || usage.isStale(now: now) ? HP.amber : HP.text2)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct CompactAgentsStrip: View {
    let sessions: [AgentSession]
    let nav: SectionNav

    private var needing: [AgentSession] { sessions.filter { $0.activity == .needsInput } }
    private var working: Int { sessions.filter { $0.activity == .working || $0.activity == .shell }.count }
    private var idle: Int { sessions.filter { $0.activity == .waiting }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(needing.prefix(2)) { session in
                Button { nav.jump(session) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(HP.amber)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Needs your attention")
                                .font(.system(size: CT.caption, weight: .semibold)).foregroundStyle(HP.amber)
                            Text(session.name).font(.system(size: CT.title, weight: .semibold))
                                .foregroundStyle(HP.text).lineLimit(1)
                            Text(session.waitingFor.flatMap { $0.isEmpty ? nil : $0 } ?? AgentStatus.word(session))
                                .font(.system(size: CT.caption)).foregroundStyle(HP.text2).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward").foregroundStyle(HP.amber)
                            .accessibilityHidden(true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TileButtonStyle(radius: 12))
                .help(session.waitingFor ?? "Go to the session")
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens \(session.surface ?? "the session’s app")")
            }
            Button { nav.go(.agents) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").foregroundStyle(HP.text2).accessibilityHidden(true)
                    Text(summary).foregroundStyle(HP.text2)
                    Spacer(minLength: 3)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HP.text3).accessibilityHidden(true)
                }
                .font(.system(size: CT.body))
                .padding(.horizontal, 4).frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("Sessions: \(summary)")
        }
    }

    private var summary: String {
        let live = sessions.filter { $0.activity != .ended }.count
        guard live > 0 else { return "No active sessions" }
        var parts = ["\(working) working"]
        if !needing.isEmpty { parts.append("\(needing.count) need you") }
        if idle > 0 { parts.append("\(idle) idle") }
        return parts.joined(separator: " · ")
    }
}

/// One calm entry point into the full Mac metrics page.
struct CompactMacSummary: View {
    @ObservedObject var system: SystemMonitor
    let nav: SectionNav

    private var warning: String? {
        guard let snap = system.latest else { return nil }
        if snap.memory.pressure == .critical { return "Memory pressure is high" }
        if snap.thermal.state == .critical || snap.thermal.state == .serious { return "Mac is running hot" }
        if snap.thermal.components.contains(where: { $0.tempC >= $0.hotAt }) { return "A component is running hot" }
        if snap.memory.pressure == .warning { return "Memory pressure is raised" }
        if snap.thermal.state == .fair || snap.thermal.components.contains(where: { $0.tempC >= $0.warmAt }) {
            return "Mac is running warm"
        }
        if let power = snap.power, power.hasBattery, !power.isCharging, power.batteryPercent <= 20 {
            return "Battery is low"
        }
        return nil
    }

    var body: some View {
        Button { nav.go(.mac) } label: {
            HStack(spacing: 10) {
                Image(systemName: warning == nil ? "laptopcomputer" : "exclamationmark.triangle")
                    .font(.system(size: 17)).foregroundStyle(warning == nil ? HP.text2 : HP.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(warning ?? (system.latest == nil ? "Reading your Mac…" : "Mac overview"))
                        .font(.system(size: CT.body, weight: .semibold))
                        .foregroundStyle(warning == nil ? HP.text : HP.amber)
                    if let snap = system.latest {
                        Text("CPU \(SysFmt.percent(snap.cpu.total))% · Memory \(SysFmt.percent(snap.memory.usedPercent))%")
                            .font(.system(size: CT.caption)).monospacedDigit().foregroundStyle(HP.text2)
                    } else {
                        Text("Metrics appear when available").font(.system(size: CT.caption)).foregroundStyle(HP.text2)
                    }
                }
                Spacer(minLength: 3)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HP.text3).accessibilityHidden(true)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(TileButtonStyle(radius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens all Mac metrics")
    }
}

struct CompactMacTiles: View {
    @ObservedObject var system: SystemMonitor
    let nav: SectionNav

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            if let snap = system.latest {
                tile(.cpu, "CPU", SysFmt.temp(snap.thermal.cpuTempC)) {
                    value(snap.cpu.total, SysFmt.percent(snap.cpu.total), "%")
                } chart: {
                    Sparkline(values: Array(system.cpuHistory.suffix(30)), maxValue: 100, color: HP.cpu, lineWidth: 1.2)
                }
                tile(.gpu, "GPU", SysFmt.temp(snap.thermal.gpuTempC)) {
                    value(snap.gpu?.utilization ?? 0, snap.gpu.map { SysFmt.percent($0.utilization) } ?? "—", "%")
                } chart: {
                    Sparkline(values: Array(system.gpuHistory.suffix(30)), maxValue: 100, color: HP.gpu, lineWidth: 1.2)
                }
                tile(.memory, "Memory", nil, dot: HP.pressure(snap.memory.pressure)) {
                    value(snap.memory.usedPercent, SysFmt.percent(snap.memory.usedPercent), "%")
                } chart: {
                    MemoryBar(memory: snap.memory, height: 4)
                }
                tile(.network, "Net", nil) {
                    HStack(spacing: 4) {
                        (Text("↓").foregroundColor(HP.down) + Text(SysFmt.rateShort(snap.network.downBytesPerSecond)))
                        (Text("↑").foregroundColor(HP.up) + Text(SysFmt.rateShort(snap.network.upBytesPerSecond)))
                    }
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(HP.text)
                    .lineLimit(1)
                } chart: {
                    MirrorSparkline(above: Array(system.downHistory.suffix(30)), below: Array(system.upHistory.suffix(30)),
                                    aboveColor: HP.down, belowColor: HP.up, lineWidth: 1)
                }
                tile(.disk, "Disk", "free") {
                    value(0, "\(Int((Double(snap.disk.freeBytes) / 1_073_741_824).rounded()))", "GB")
                } chart: {
                    let used = snap.disk.totalBytes > 0 ? 1 - Double(snap.disk.freeBytes) / Double(snap.disk.totalBytes) : 0
                    SegmentBar(segments: [.init(fraction: used, color: HP.disk)], height: 4)
                }
                if let p = snap.power, p.hasBattery {
                    tile(.power, "Battery", p.systemWatts.map { String(format: "%.0f W", $0) }) {
                        value(p.batteryPercent, SysFmt.percent(p.batteryPercent), p.isCharging ? "% ⚡︎" : "%")
                    } chart: {
                        SegmentBar(segments: [.init(fraction: p.batteryPercent / 100,
                                                    color: p.batteryPercent <= 20 ? HP.red : HP.power)], height: 4)
                    }
                } else {
                    tile(.power, "Power", nil) {
                        value(snap.power?.systemWatts ?? 0, snap.power?.systemWatts.map { String(format: "%.0f", $0) } ?? "—", "W")
                    } chart: {
                        Sparkline(values: Array(system.powerHistory.suffix(30)), color: HP.power, lineWidth: 1.2)
                    }
                }
            } else {
                ForEach(0..<6, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HP.tile).frame(height: 52)
                }
            }
        }
    }

    private func value(_ v: Double, _ text: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0.5) {
            RollingNumber(value: v, text: text, size: CT.smallValue)
            Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
        }
    }

    private func tile<V: View, C: View>(_ kind: SystemDetailKind, _ label: String, _ trailing: String?,
                                        dot: Color? = nil,
                                        @ViewBuilder value: () -> V,
                                        @ViewBuilder chart: () -> C) -> some View {
        Button { nav.openDetail(kind) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Kicker(text: label)
                    Spacer(minLength: 2)
                    if let dot {
                        Circle().fill(dot).frame(width: 5, height: 5)
                    } else if let trailing {
                        Text(trailing).font(.system(size: 11)).foregroundStyle(HP.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 1)
                value()
                Spacer(minLength: 2)
                chart().frame(height: 11)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(height: 54)
        }
        .buttonStyle(TileButtonStyle(radius: 10))
    }
}

// MARK: - AI

struct CompactAI: View {
    @ObservedObject var store: UsageStore
    let history: UsageHistoryStore
    let now: Date
    let nav: SectionNav

    @Environment(\.usageDisplayMode) private var mode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.usages.isEmpty {
                Text("No AI accounts switched on").font(.system(size: CT.body, weight: .semibold))
                Button("Connect an account", action: nav.openSettings).buttonStyle(PillButtonStyle())
            }
            ForEach(store.usages) { usage in
                let identity = ProviderIdentity.identity(for: usage.providerID)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        BrandMark(kind: identity.mark, size: 15, tint: identity.accent).accessibilityHidden(true)
                        Text(usage.displayName).font(.system(size: CT.title, weight: .semibold))
                            .foregroundStyle(HP.text)
                        Spacer(minLength: 4)
                        if let plan = usage.plan {
                            Text(plan).font(.system(size: CT.caption)).foregroundStyle(HP.text2)
                        }
                    }
                    if let balance = usage.balance {
                        Text("\(Fmt.money(balance.amount, currency: balance.currency)) credit left")
                            .font(.system(size: CT.value, weight: .semibold)).foregroundStyle(HP.text)
                    }
                    ForEach(usage.windows, id: \.self) { window in
                        let reading = WindowReading(window: window, providerID: usage.providerID,
                                                    history: history, now: now, mode: mode)
                        HStack(alignment: .center, spacing: 10) {
                            ForecastRing(share: reading.share, projected: reading.projected,
                                         isCritical: window.isCritical, color: identity.accent,
                                         size: 28, lineWidth: 3).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(window.displayName).fontWeight(.medium)
                                    Spacer(minLength: 4)
                                    Text(window.percent(mode).map { "\(Fmt.percent($0)) \(mode.unit)" } ?? "No reading")
                                        .fontWeight(.semibold).monospacedDigit()
                                        .foregroundStyle(window.isCritical ? HP.amber : HP.text)
                                }
                                .font(.system(size: CT.body)).foregroundStyle(HP.text)
                                Text(Fmt.remaining(to: window.resetsAt, now: now).map { "Resets \($0)" } ?? "Reset time unavailable")
                                    .font(.system(size: CT.caption)).foregroundStyle(HP.text2)
                                if reading.alarming && !usage.isStale(now: now) {
                                    Text(reading.compact).font(.system(size: CT.caption, weight: .medium))
                                        .foregroundStyle(HP.amber)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let status = usage.freshnessCaption(now: now) {
                        Text(status).font(.system(size: CT.caption))
                            .foregroundStyle(usage.needsSetup || usage.isStale(now: now) ? HP.amber : HP.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if usage.needsSetup {
                        Button(usage.providerID == "claude" ? "Sign in with Claude Code" : "Open Settings",
                               action: usage.providerID == "claude" ? nav.signInClaude : nav.openSettings)
                            .buttonStyle(PillButtonStyle(compact: true))
                    }
                    if !usage.extras.isEmpty {
                        Text(usage.extras.joined(separator: " · "))
                            .font(.system(size: CT.caption)).foregroundStyle(HP.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).tile(radius: 12)
            }
            if store.usages.contains(where: { !$0.windows.isEmpty }) {
                Text("Lighter arc estimates usage before the reset.")
                    .font(.system(size: CT.caption)).foregroundStyle(HP.text3)
                    .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - Agents

struct CompactAgents: View {
    let sessions: [AgentSession]
    let now: Date
    var onJump: (AgentSession) -> Void = { _ in }

    @Environment(\.usageDisplayMode) private var mode

    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                Text("No agent sessions right now")
                    .font(.system(size: CT.body)).foregroundStyle(HP.text2)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, s in
                if index > 0 { Rectangle().fill(HP.stroke).frame(height: 1) }
                let identity = ProviderIdentity.identity(for: s.providerID)
                Button { onJump(s) } label: {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(HP.tile)
                        BrandMark(kind: identity.mark, size: 12, tint: identity.accent)
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.system(size: CT.title, weight: .semibold))
                            .foregroundStyle(s.activity == .ended ? HP.text2 : HP.text).lineLimit(1)
                        Text([s.projectName.isEmpty ? nil : s.projectName, s.surface,
                              s.contextPercent(mode).map { "\(Fmt.percent($0)) context" }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(HP.text3).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(AgentStatus.word(s)).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AgentStatus.color(s))
                        Text(AgentStatus.caption(s, now: now)).font(.system(size: 11))
                            .foregroundStyle(HP.text3).lineLimit(1)
                    }
                    .frame(maxWidth: 120, alignment: .trailing)
                }
                .frame(minHeight: 48)
                .padding(.horizontal, 6)
                }
                // A live session is one click from the app it runs in.
                .buttonStyle(RowButtonStyle())
                .disabled(s.activity == .ended)
                .help(s.activity == .ended ? "" : "Go to \(s.surface ?? "its app")")
                .accessibilityElement(children: .combine)
                .accessibilityHint(s.activity == .ended ? "Session has ended" : "Opens the session’s app")
                .padding(.horizontal, -6)
            }
        }
        .padding(.horizontal, 10)
        .tile(radius: 12)
    }
}

// MARK: - Mac

struct CompactMac: View {
    @ObservedObject var system: SystemMonitor
    let nav: SectionNav

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                if let snap = system.latest {
                    big(.cpu, "CPU", "\(SysFmt.percent(snap.cpu.total))", "%", HP.cpu, SysFmt.temp(snap.thermal.cpuTempC)) {
                        Sparkline(values: system.cpuHistory, maxValue: 100, color: HP.cpu, lineWidth: 1.3,
                                  secondary: system.systemCPUHistory)
                    }
                    big(.gpu, "GPU", snap.gpu.map { SysFmt.percent($0.utilization) } ?? "—", "%", HP.gpu,
                        SysFmt.temp(snap.thermal.gpuTempC)) {
                        Sparkline(values: system.gpuHistory, maxValue: 100, color: HP.gpu, lineWidth: 1.3)
                    }
                    big(.memory, "Memory", SysFmt.gigabytes(snap.memory.usedBytes), "GB", HP.memory, nil) {
                        VStack(spacing: 4) {
                            MemoryBar(memory: snap.memory, height: 5)
                            HStack(spacing: 4) {
                                Circle().fill(HP.pressure(snap.memory.pressure)).frame(width: 5, height: 5)
                                Text(snap.memory.pressure == .normal ? "normal" : (snap.memory.pressure == .warning ? "raised" : "high"))
                                Spacer(minLength: 2)
                                if snap.memory.swapUsedBytes > 0 {
                                    Text("swap \(SysFmt.bytes(snap.memory.swapUsedBytes))").lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            .font(.system(size: 11)).foregroundStyle(HP.text3)
                        }
                    }
                    big(.network, "Net", SysFmt.rateShort(snap.network.downBytesPerSecond), "↓", HP.down,
                        "↑ \(SysFmt.rateShort(snap.network.upBytesPerSecond))") {
                        MirrorSparkline(above: system.downHistory, below: system.upHistory,
                                        aboveColor: HP.down, belowColor: HP.up, lineWidth: 1.1)
                    }
                    big(.disk, "Disk", "\(Int((Double(snap.disk.freeBytes) / 1_073_741_824).rounded()))", "GB free", HP.disk, nil) {
                        MirrorSparkline(above: system.readHistory, below: system.writeHistory,
                                        aboveColor: HP.disk, belowColor: HP.text2, lineWidth: 1.1)
                    }
                    big(.power, "Power", snap.power?.systemWatts.map { String(format: "%.1f", $0) } ?? "—", "W", HP.power,
                        snap.thermal.fans.isEmpty ? nil : ((snap.thermal.fans.map(\.rpm).max() ?? 0) < 100 ? "fans off" : "fans on")) {
                        Sparkline(values: system.powerHistory, color: HP.power, lineWidth: 1.3)
                    }
                } else {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HP.tile).frame(height: 78)
                    }
                }
            }
            HStack(spacing: 10) {
                Kicker(text: "Busiest")
                if system.topByCPU.isEmpty { Text("measuring…").foregroundStyle(HP.text3) }
                ForEach(system.topByCPU.prefix(2)) { p in
                    HStack(spacing: 3) {
                        Text(p.name).foregroundStyle(HP.text).lineLimit(1)
                        Text("\(Int(p.cpuPercent.rounded()))%").foregroundStyle(HP.text2)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .tile(radius: 10)
            if let snap = system.latest {
                ThermalsTile(thermal: snap.thermal)
            }
        }
    }

    private func big<C: View>(_ kind: SystemDetailKind, _ label: String, _ value: String, _ unit: String,
                              _ color: Color, _ trailing: String?, @ViewBuilder chart: () -> C) -> some View {
        Button { nav.openDetail(kind) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Kicker(text: label)
                    Spacer(minLength: 2)
                    if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(HP.text3).lineLimit(1) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value).font(.system(size: CT.smallValue, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(color)
                        .contentTransition(.numericText()).animation(HMotion.tick, value: value)
                    Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(HP.text2)
                }
                .lineLimit(1)
                Spacer(minLength: 2)
                chart().frame(height: 24)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(height: 80)
        }
        .buttonStyle(TileButtonStyle(radius: 10))
    }
}

/// Every part the sensors cover as a coloured pill: green while it is fine,
/// amber once it runs warm, red when it is hot, each by its own limits (a
/// battery is hot far sooner than a core). The header sums it up in one
/// pill and says what the fans are doing.
struct ThermalsTile: View {
    let thermal: ThermalReading

    private enum Level: Int, Comparable {
        case ok, warm, hot
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var color: Color {
            switch self {
            case .ok: return HP.ok
            case .warm: return HP.amber
            case .hot: return HP.red
            }
        }
    }

    private func level(_ c: ComponentTemp) -> Level {
        if c.tempC >= c.hotAt { return .hot }
        if c.tempC >= c.warmAt { return .warm }
        return .ok
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Kicker(text: "Temperatures")
                Spacer(minLength: 4)
                if let fans { Text(fans).font(.system(size: 11)).foregroundStyle(HP.text3) }
                if !thermal.components.isEmpty { summary }
            }
            if thermal.components.isEmpty {
                Text("reading the sensors…")
                    .font(.system(size: 12))
                    .foregroundStyle(HP.text3)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible())], spacing: 5) {
                    ForEach(thermal.components) { pill($0) }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .tile(radius: 10)
    }

    /// "All normal", or the hottest part by name: "Warm · GPU", "Hot · SSD".
    /// macOS's own thermal state outranks it once it is past normal.
    private var summary: some View {
        let worst = thermal.components.max { (level($0), $0.tempC / $0.hotAt) < (level($1), $1.tempC / $1.hotAt) }
        let worstLevel = worst.map(level) ?? .ok
        let system: Level? = switch thermal.state {
        case .serious, .critical: .hot
        case .fair: .warm
        default: nil
        }
        let shown = max(worstLevel, system ?? .ok)
        let text: String
        switch shown {
        case .ok: text = "All normal"
        case .warm: text = "Warm · \(worst?.name ?? "Mac")"
        case .hot: text = thermal.state == .critical ? "Throttling" : "Hot · \(worst?.name ?? "Mac")"
        }
        return HStack(spacing: 4) {
            Circle().fill(shown.color).frame(width: 5, height: 5)
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(shown.color)
        .padding(.horizontal, 7)
        .frame(height: 17)
        .background(Capsule().fill(shown.color.opacity(0.14)))
    }

    private func pill(_ c: ComponentTemp) -> some View {
        let color = level(c).color
        return HStack(spacing: 5) {
            Image(systemName: c.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(c.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HP.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(Int(c.tempC.rounded()))°")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .frame(height: 21)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(0.13)))
        .help("\(c.name): \(String(format: "%.1f", c.tempC))°C · warm from \(Int(c.warmAt))°, hot from \(Int(c.hotAt))°")
    }

    private var fans: String? {
        guard let top = thermal.fans.map(\.rpm).max() else { return nil }
        return top < 100 ? "fans off" : "fans \(Int(top.rounded()).formatted()) rpm"
    }
}

// MARK: - Menu bar popover

/// The status item's popover: the same compact card, with refresh and quit.
struct CompactPopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var focus: FocusStore
    @ObservedObject var pages: PopoverPageModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var backpack: BackpackManager
    var onRefresh: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var onSignInClaude: () -> Void = {}
    var flatBackground: Bool = false
    var scrollable: Bool = true
    var fixedNow: Date? = nil
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // Rendered only while the popover is on screen: a loaded but closed
        // popover would otherwise re-render on every system tick.
        if pages.isShown || flatBackground {
            content
        } else {
            Color.clear.frame(width: CardMetrics.width, height: 300)
        }
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            CompactCard(store: store, sessionStore: sessionStore, clipboard: clipboard, focus: focus,
                        pages: pages, system: system, backpack: backpack, now: fixedNow ?? context.date,
                        showsTabs: true, showsAppButtons: true, scrollable: scrollable,
                        onRefresh: onRefresh, onOpenSettings: onOpenSettings, onQuit: onQuit,
                        onSignInClaude: onSignInClaude)
        }
        .environment(\.usageDisplayMode, settings.displayMode)
        .background(flatBackground || HMotion.reduceTransparency ? AnyShapeStyle(PopoverTheme.snapshotBackground)
                                   : AnyShapeStyle(PopoverTheme.material))
    }
}
