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
    static let headerHeight: CGFloat = 44
    /// Header, footer, their gaps, and the card’s outer vertical padding.
    static let chromeHeight: CGFloat = headerHeight + 6 + 24 + 6 + 8 + 4
    static let maxHeight: CGFloat = maxSectionHeight + chromeHeight
    /// A smaller page eases the card's height down over the section motion,
    /// so the window waits that long before shrinking to match, or it would
    /// cut off the bottom of the card on its way down.
    static var resizeSettle: TimeInterval { HMotion.reduceMotion ? 0 : HMotion.sectionDuration + 0.03 }
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
    @ObservedObject private var updates = AppUpdater.shared
    let now: Date
    var history: UsageHistoryStore = .shared
    /// Expanded cards keep all six destinations inside the content surface.
    var showsTabs: Bool = true
    /// The popover adds refresh and quit to the footer.
    var showsAppButtons: Bool = false
    var scrollable: Bool = true
    var onRefresh: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSignInClaude: () -> Void = {}
    var onJump: (AgentSession) -> Void = { _ in }
    /// An update to show regardless of the updater, for renders only.
    var renderedOffer: AppUpdater.Offer? = nil

    @Environment(\.usageDisplayMode) private var mode
    @State private var demandClient = "card-\(UUID().uuidString)"

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
                   jump: onJump,
                   openBackpack: { withAnimation(HMotion.section) { pages.backpackCard = true } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: showsTabs ? CardMetrics.headerHeight : 28)
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
        .onAppear { system.setDemand(.panel, for: demandClient) }
        .onDisappear { system.setDemand(.idle, for: demandClient) }
    }

    // MARK: Header

    /// The page's name and one line about it on the left, the four tabs as
    /// symbols on the right: one row where a labelled tab bar and a title
    /// would have taken two.
    private var header: some View {
        Group {
            if showsTabs {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pages.backpackCard ? "Backpack" : pages.page.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(HP.text)
                        Text(headerCaption.text)
                            .font(.system(size: CT.caption))
                            .foregroundStyle(headerCaption.alert ? HP.amber : HP.text3)
                    }
                    .lineLimit(1)
                    // The words change with the page, in the same frame,
                    // rather than dissolving after it has already gone.
                    .contentTransition(.identity)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .accessibilityElement(children: .combine)
                    HotchTabBar(selection: Binding(get: { pages.page }, set: { pages.select($0) }),
                                dimSelection: pages.backpackCard,
                                compact: true,
                                iconsOnly: true,
                                onSelect: { pages.select($0) })
                }
            } else {
                Kicker(text: pages.backpackCard ? "Backpack" : pages.page.wingTitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerCaption: (text: String, alert: Bool) {
        if pages.backpackCard { return ("Keep agents working with the lid closed", false) }
        switch pages.page {
        case .home:
            return (now.formatted(.dateTime.weekday(.wide).day().month(.wide)), false)
        case .ai:
            return (sessionStore.summaryLine ?? "No sessions right now", sessionStore.needsInputCount > 0)
        case .mac:
            if let warning = system.latest?.warning { return (warning, true) }
            return (system.latest == nil ? "Waiting for readings" : "Live \u{00B7} every second", false)
        case .desk:
            if let readout = FocusDisplay.readout(focus, now: now) {
                return ("Focus \u{00B7} \(readout.value) \(readout.caption)", false)
            }
            return (clipboard.enabled ? "Focus, clipboard and Backpack" : "Focus and Backpack", false)
        }
    }

    // MARK: Sections

    private var sectionIdentity: String {
        pages.backpackCard ? "backpack" : "\(pages.page.rawValue)-\(pages.macDetail?.rawValue ?? "")"
    }

    private var section: some View {
        SectionViewport(identity: sectionIdentity, maximumHeight: CardMetrics.maxSectionHeight,
                        scrollable: scrollable) {
            sectionContent
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        let layout = SectionLayout.popover(width: CardMetrics.column)
        Group {
            if pages.backpackCard {
                BackpackCard(backpack: backpack, sessions: sessionStore.sessions, now: now,
                             layout: layout, active: true)
            } else {
                switch pages.page {
                case .home:
                    CompactHome(store: store, sessionStore: sessionStore, system: system, focus: focus,
                                clipboard: clipboard, history: history, now: now, nav: nav)
                case .ai:
                    CompactAITab(store: store, sessions: sessionStore.sessions, history: history,
                                 now: now, nav: nav)
                case .mac:
                    if let detail = pages.macDetail {
                        MacDetailView(system: system, kind: detail, layout: layout, nav: nav)
                    } else {
                        CompactMac(system: system, nav: nav)
                    }
                case .desk:
                    CompactDesk(focus: focus, clipboard: clipboard, backpack: backpack, now: now, nav: nav)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Text(footerText)
                .font(.system(size: CT.caption))
                .foregroundStyle(HP.text3)
                .lineLimit(1)
                .contentTransition(.identity)
            Spacer(minLength: 6)
            // Backpack lives on the Desk tab. The footer only carries it while
            // it is on (a mode that keeps the Mac awake should never be out of
            // sight) or while its card is open, as the way back.
            if backpack.isOn || pages.backpackCard {
                BackpackShortcut(backpack: backpack, selected: pages.backpackCard, action: nav.openBackpack)
            }
            // A found update sits with the app's own buttons until it is
            // dealt with.
            if let offer = renderedOffer ?? updates.offer {
                UpdateButton(offer: offer) { updates.checkForUpdates() }
                    .padding(.horizontal, 2)
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
        case .home, .ai:
            if store.isRefreshing { return "Checking usage…" }
            return Fmt.ago(store.lastRefresh, now: now).map { "Checked \($0)" } ?? "No usage check yet"
        case .mac: return "Click a tile for detail"
        case .desk: return clipboard.enabled ? "Click an item to copy it again" : "Clipboard history is off"
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

// MARK: - Mac

struct CompactMac: View {
    @ObservedObject var system: SystemMonitor
    let nav: SectionNav
    @State private var demandClient = "compact-mac-\(UUID().uuidString)"

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
        .onAppear { system.setDemand(.processes, for: demandClient) }
        .onDisappear { system.setDemand(.idle, for: demandClient) }
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
