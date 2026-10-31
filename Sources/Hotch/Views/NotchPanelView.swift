import SwiftUI

/// The panel body. The top edge is dead flat and full width, and the top corners
/// flare outward with a concave fillet the way real notch hardware meets the
/// bezel. Bottom corners are generously rounded.
struct NotchPanelShape: InsettableShape {
    var flare: CGFloat = NotchTheme.topFlare
    var bottomRadius: CGFloat = NotchTheme.bottomCornerRadius
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let flare = max(0, self.flare - insetAmount)
        let bottom = min(max(0, bottomRadius - insetAmount),
                         min(max(0, r.width / 2 - flare), r.height / 2))

        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.maxX - flare, y: r.minY + flare),
                          control: CGPoint(x: r.maxX - flare, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - flare, y: r.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: r.maxX - flare - bottom, y: r.maxY),
                          control: CGPoint(x: r.maxX - flare, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + flare + bottom, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.minX + flare, y: r.maxY - bottom),
                          control: CGPoint(x: r.minX + flare, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + flare, y: r.minY + flare))
        path.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY),
                          control: CGPoint(x: r.minX + flare, y: r.minY))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NotchPanelShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

// MARK: - Actions

/// Closures the pages can trigger, assigned by the app delegate after the
/// windows are built.
@MainActor
final class PanelActions: ObservableObject {
    var openSettings: () -> Void = {}
    /// Raised while a text field on the focus page holds the caret, so the
    /// window controller can stop a hover panel from closing mid-word.
    var setEditing: (Bool) -> Void = { _ in }
    var setPage: (PanelPage) -> Void = { _ in }
    var setDetail: (SystemDetailKind?) -> Void = { _ in }
    var toggleBackpackCard: () -> Void = {}
    var signInClaude: () -> Void = {}
}

// MARK: - Chrome (the display window)

/// Everything that must never take a click: the body shape and the strip wings.
/// It spans the menu bar on both sides of the notch and keeps
/// `ignoresMouseEvents` forever.
///
/// Hotch 2: the shape is as tall as the **current section**, not the window.
/// The window is sized for the tallest section once; switching to or from This
/// Mac moves only the shape's bottom edge, on the section spring.
struct PanelChromeView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var focus: FocusStore
    @ObservedObject var model: PanelModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var backpack: BackpackManager
    let now: Date

    @Environment(\.usageDisplayMode) private var mode

    private var shape: NotchPanelShape { NotchPanelShape() }

    private var collapsedScaleX: CGFloat {
        guard model.panelWidth > 0 else { return 0.5 }
        return min(1, max(0.05, model.notchWidth / model.panelWidth))
    }

    private var collapsedScaleY: CGFloat {
        guard model.visibleShapeHeight > 0 else { return 0.2 }
        return min(1, max(0.05, model.notchHeight / model.visibleShapeHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                panelBody
                notchWings
            }
            .frame(width: model.panelWidth, height: model.visibleShapeHeight, alignment: .top)
            .clipShape(shape)
            .compositingGroup()
            .animation(HMotion.section, value: model.visibleShapeHeight)
            .scaleEffect(x: model.expanded ? 1 : collapsedScaleX,
                         y: model.expanded ? 1 : collapsedScaleY,
                         anchor: .top)
            .animation(model.expanded ? PanelMotion.open : PanelMotion.close, value: model.expanded)
            .opacity(model.expanded ? 1 : 0)
            .animation(model.expanded ? PanelMotion.open : PanelMotion.closeFade, value: model.expanded)

            Spacer(minLength: 0)
        }
        .frame(width: model.panelWidth, height: model.windowHeight, alignment: .top)
    }

    private var panelBody: some View {
        let height = max(1, model.visibleShapeHeight)
        let notchEnd = min(0.9, model.contentTopInset / height)
        let bodyMid = min(0.95, notchEnd + 0.45)
        return shape
            .fill(LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: notchEnd),
                    .init(color: NotchTheme.bodyTop, location: bodyMid),
                    .init(color: NotchTheme.bodyBottom, location: 1)
                ],
                startPoint: .top, endPoint: .bottom))
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    // MARK: Wings

    /// Either side of the physical notch while the panel is open. The panel
    /// covers the menu bar, so the wings give back what it hides: on the left
    /// whatever most deserves attention right now, on the right the headline
    /// the status item would have shown.
    @ViewBuilder
    private var notchWings: some View {
        if model.contentClearance >= NotchTheme.wingMinimumHeight {
            let wing = max(0, (model.panelWidth - model.notchWidth) / 2)
            HStack(spacing: 0) {
                leftWing
                    .padding(.leading, NotchTheme.contentMargin)
                    .frame(width: wing, alignment: .leading)
                Color.clear.frame(width: model.notchWidth)
                rightWing
                    .padding(.trailing, NotchTheme.contentMargin)
                    .frame(width: wing, alignment: .trailing)
            }
            .frame(width: model.panelWidth, height: model.contentClearance)
            .offset(y: model.topOverflow)
            .opacity(model.expanded ? 1 : 0)
            .animation(model.expanded ? PanelMotion.contentIn(after: PanelMotion.brandLead)
                                      : PanelMotion.wingsOut,
                       value: model.expanded)
            .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder
    private var leftWing: some View {
        HStack(spacing: 6) {
            if focus.isRunning, let time = AnchorFocusClock.readout(focus, now: now) {
                Image(systemName: focus.isPaused ? "pause.fill" : "timer").foregroundStyle(focus.isPaused ? HP.amber : HP.text2)
                Text("\(time.value) \(time.caption)").foregroundStyle(HP.text).monospacedDigit()
            } else if let needing = sessionStore.sessions.first(where: { $0.activity == .needsInput }) {
                Circle().fill(HP.amber).frame(width: 6, height: 6)
                    .shadow(color: HP.amber.opacity(0.8), radius: 3)
                Text(needing.name).foregroundStyle(HP.text).lineLimit(1)
                Text(AgentStatus.word(needing)).foregroundStyle(HP.amber).fixedSize()
            } else if backpack.isOn {
                Image(systemName: "backpack.fill").foregroundStyle(HP.ok)
                Text("Backpack on").foregroundStyle(HP.text)
            } else {
                Text(model.page.wingTitle.uppercased())
                    .tracking(1.2)
                    .foregroundStyle(HP.text3)
                    .contentTransition(.identity)
                    .animation(nil, value: model.page)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
    }

    private var rightWing: some View {
        HStack(spacing: 6) {
            if let consumed = store.highestConsumedPercent {
                let shown = mode == .used ? consumed : 100 - consumed
                Text(Fmt.percent(shown))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(consumed >= NotchTheme.highConsumedThreshold ? HP.red : HP.text)
                Text(mode.unit).foregroundStyle(HP.text3)
            }
            if let cpu = system.latest?.cpu.total {
                Rectangle().fill(HP.track).frame(width: 1, height: 11)
                Text("CPU").foregroundStyle(HP.text3)
                Text("\(SysFmt.percent(cpu))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(HP.text)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }
}

// MARK: - Pages (the interaction window)

/// Everything that wants a click, in the window below the menu bar strip: the
/// tab row, the section, and the footer.
///
/// The tabs sit at the **top**, just under the notch. Sections are not all the
/// same height, and with tabs at the bottom the row would jump away from the
/// pointer every time the shape changed height. At the top it never moves.
struct PanelPagesView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var focus: FocusStore
    @ObservedObject var model: PanelModel
    @ObservedObject var actions: PanelActions
    @ObservedObject var system: SystemMonitor
    @ObservedObject var backpack: BackpackManager
    @ObservedObject private var updates = AppUpdater.shared
    let now: Date
    var history: UsageHistoryStore = .shared
    /// False only in the snapshot modes: `ImageRenderer` cannot lay out a
    /// ScrollView, so renders clip the same content to the same box instead.
    var scrollable: Bool = true

    private var contentWidth: CGFloat { model.bodyWidth - NotchTheme.contentInset * 2 }

    private var nav: SectionNav {
        SectionNav(go: { page in actions.setPage(page) },
                   openDetail: { kind in actions.setDetail(kind) },
                   openSettings: { actions.openSettings() },
                   signInClaude: { actions.signInClaude() },
                   openBackpack: { if !model.backpackCard { actions.toggleBackpackCard() } })
    }

    var body: some View {
        VStack(spacing: 0) {
            tabRow
                .frame(height: PanelModel.tabRowHeight)
                .opacity(model.expanded ? 1 : 0)
                .animation(model.expanded ? PanelMotion.contentIn(after: PanelMotion.brandLead)
                                          : PanelMotion.footerOut,
                           value: model.expanded)

            sectionContent
                .frame(width: model.bodyWidth, height: model.contentHeight, alignment: .top)
                .clipped()

            footer
                .frame(height: PanelModel.footerHeight)
                .opacity(model.expanded ? 1 : 0)
                .animation(model.expanded ? PanelMotion.contentIn(after: PanelMotion.footerLead)
                                          : PanelMotion.footerOut,
                           value: model.expanded)
            Spacer(minLength: 0)
        }
        .frame(width: model.bodyWidth, alignment: .top)
        .animation(HMotion.section, value: model.contentHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: NotchTheme.bottomCornerRadius - 6,
                                          bottomTrailingRadius: NotchTheme.bottomCornerRadius - 6))
        .environment(\.colorScheme, .dark)
    }

    private var tabRow: some View {
        HStack {
            Spacer(minLength: 0)
            HotchTabBar(selection: Binding(get: { model.page }, set: { actions.setPage($0) }),
                        dimSelection: model.backpackCard,
                        onSelect: { actions.setPage($0) })
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var sectionContent: some View {
        ZStack(alignment: .top) {
            Group {
                if model.backpackCard {
                    BackpackCard(backpack: backpack, sessions: sessionStore.sessions, now: now,
                                 layout: .panel(width: contentWidth), active: model.expanded)
                        .padding(.top, 4)
                } else {
                    page(model.page)
                }
            }
            .id(model.backpackCard ? -1 : model.page.rawValue)
            .transition(HMotion.sectionTransition)
        }
        .animation(HMotion.section, value: model.page)
        .animation(HMotion.section, value: model.backpackCard)
    }

    @ViewBuilder
    private func page(_ page: PanelPage) -> some View {
        let layout = SectionLayout.panel(width: contentWidth)
        switch page {
        case .home:
            NowSection(store: store, sessionStore: sessionStore, system: system, history: history,
                       now: now, active: model.expanded, layout: layout, nav: nav, backpack: backpack)
                .padding(.top, 4)
        case .ai:
            // Usage first, then the sessions spending it: the card nests them
            // per provider, and this wide panel keeps its two full sections.
            scroll {
                VStack(spacing: 14) {
                    AISection(store: store, history: history, now: now, active: model.expanded,
                              layout: layout, nav: nav)
                    AgentsSection(sessions: sessionStore.sessions, now: now, active: model.expanded,
                                  layout: layout)
                }
            }
        case .mac:
            MacSection(system: system, detail: model.macDetail, active: model.expanded,
                       layout: layout, nav: nav)
                .padding(.top, 4)
        case .desk:
            scroll {
                VStack(alignment: .leading, spacing: 16) {
                    FocusPageContent(focus: focus, now: now, active: model.expanded,
                                     onEditingChanged: { actions.setEditing($0) })
                        .padding(.top, 12)
                    ClipboardPageRows(items: clipboard.items, enabled: clipboard.enabled, now: now,
                                      active: model.expanded, onCopy: { clipboard.copyBack($0) })
                    BackpackDiscoveryRow(backpack: backpack, action: nav.openBackpack)
                }
                .frame(width: contentWidth)
            }
        }
    }

    @ViewBuilder
    private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if scrollable {
            ScrollView(.vertical) {
                content()
                    .padding(.top, 2)
                    .frame(width: model.bodyWidth)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            content()
                .padding(.top, 2)
                .frame(width: model.bodyWidth, alignment: .top)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let offer = updates.offer, model.revealHint == nil, !model.backpackCard {
                UpdatePill(offer: offer) { updates.checkForUpdates() }
            } else {
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(HP.text3)
                    .lineLimit(1)
                    .contentTransition(.identity)
            }
            Spacer(minLength: 8)
            BackpackShortcut(backpack: backpack, selected: model.backpackCard,
                             action: actions.toggleBackpackCard)
            footerButton("gearshape.fill", tint: HP.text2, help: "Hotch Settings", action: actions.openSettings)
        }
        .padding(.leading, NotchTheme.contentInset)
        .padding(.trailing, NotchTheme.contentInset - 6)
        .overlay(alignment: .leading) { revealHintLine }
    }

    private func footerButton(_ symbol: String, tint: Color, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help(help)
    }

    private var footerText: String {
        if model.revealHint != nil { return "" }
        if model.backpackCard { return backpack.footerLine }
        switch model.page {
        case .home:
            return Fmt.ago(store.lastRefresh, now: now).map { "updated \($0)" } ?? "updating"
        case .ai:
            return sessionStore.summaryLine
                ?? Fmt.ago(store.lastRefresh, now: now).map { "updated \($0)" } ?? "updating"
        case .mac:
            return "live · every second"
        case .desk:
            return clipboard.enabled ? "clipboard in memory only · kept until you quit" : "clipboard history is off"
        }
    }

    @ViewBuilder
    private var revealHintLine: some View {
        if let hint = model.revealHint {
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(HP.text2)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, NotchTheme.contentInset)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Snapshot composition

/// The whole panel as one view, for the render modes: chrome behind, pages
/// laid at the content offset — exactly the geometry the two live windows
/// produce between them.
struct NotchPanelContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var focus: FocusStore
    @ObservedObject var model: PanelModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var backpack: BackpackManager
    let now: Date
    var history: UsageHistoryStore = .shared
    var actions: PanelActions = PanelActions()

    var body: some View {
        ZStack(alignment: .top) {
            PanelChromeView(store: store, sessionStore: sessionStore, focus: focus, model: model,
                            system: system, backpack: backpack, now: now)
            PanelPagesView(store: store, sessionStore: sessionStore, clipboard: clipboard,
                           focus: focus, model: model, actions: actions, system: system,
                           backpack: backpack, now: now, history: history, scrollable: false)
                .frame(height: model.visibleShapeHeight - model.contentTopInset, alignment: .top)
                .offset(y: model.contentTopInset)
                .opacity(model.expanded ? 1 : 0)
        }
        .frame(width: model.panelWidth, height: model.visibleShapeHeight, alignment: .top)
    }
}

// MARK: - Live roots

struct NotchChromeRootView: View {
    let store: UsageStore
    let sessionStore: SessionStore
    let focus: FocusStore
    @ObservedObject var model: PanelModel
    let system: SystemMonitor
    let backpack: BackpackManager
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if model.mounted {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    PanelChromeView(store: store, sessionStore: sessionStore, focus: focus, model: model,
                                    system: system, backpack: backpack, now: context.date)
                }
            } else { Color.clear }
        }
        .environment(\.usageDisplayMode, settings.displayMode)
        .frame(width: model.panelWidth, height: model.windowHeight, alignment: .top)
    }
}

struct NotchPagesRootView: View {
    let store: UsageStore
    let sessionStore: SessionStore
    let clipboard: ClipboardStore
    let focus: FocusStore
    @ObservedObject var model: PanelModel
    @ObservedObject var actions: PanelActions
    let system: SystemMonitor
    let backpack: BackpackManager
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if model.mounted {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    PanelPagesView(store: store, sessionStore: sessionStore, clipboard: clipboard,
                                   focus: focus, model: model, actions: actions, system: system,
                                   backpack: backpack, now: context.date)
                }
            } else { Color.clear }
        }
        .environment(\.usageDisplayMode, settings.displayMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
