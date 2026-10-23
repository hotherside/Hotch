import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - What every anchor needs

/// The stores and actions the card and its anchors draw from, passed as one
/// value so adding an anchor does not mean threading eight parameters.
@MainActor
struct CardDeps {
    let store: UsageStore
    let sessionStore: SessionStore
    let clipboard: ClipboardStore
    let focus: FocusStore
    let system: SystemMonitor
    let backpack: BackpackManager
    let pages: PopoverPageModel
    var openSettings: () -> Void = {}
    var signInClaude: () -> Void = {}
    var refresh: () -> Void = {}
    var quit: () -> Void = {}
    /// Brings forward the app a session runs in, and puts the card away.
    var jump: (AgentSession) -> Void = { _ in }
    /// A click on an alert: go to the session, or open what it is about.
    var actOnAlert: (LiveActivity) -> Void = { _ in }
}

/// The anchors share one motion family with the card.
enum AnchorMotion {
    static var morph: Animation { HMotion.reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.32, bounce: 0.12) }
    static var settle: TimeInterval { HMotion.reduceMotion ? 0.01 : 0.34 }
    static let dwell: TimeInterval = 0.22
    /// Resting on the tab's face, rather than pushing against the screen
    /// edge, waits a little longer: the tab now covers a scroll bar's width.
    static let tabDwell: TimeInterval = 0.24
    static let leave: TimeInterval = 0.3
    /// Resting on a section icon this long opens it; crossing it does not.
    static let hoverIntent: TimeInterval = 0.23
    static var glide: TimeInterval { HMotion.reduceMotion ? 0.01 : 0.28 }
    static let poll: TimeInterval = 0.025
}

// MARK: - The card window

@MainActor
final class CardPresence: ObservableObject {
    @Published var visible = false
    /// Where the card grows from: the side of the anchor that opened it.
    @Published var origin: UnitPoint = .topTrailing
    @Published var showsTabs = true
    /// The menu bar's card also carries refresh and quit.
    @Published var showsAppButtons = false
    /// The window corner that stays put while the card changes height. The
    /// card is drawn against it, so the window catching up a frame later
    /// (or shrinking only after the motion) never moves the card.
    @Published var alignment: Alignment = .topTrailing
    /// The card's content exists only while it is on screen (and for the
    /// fade out). A hidden card that kept observing the stores re-rendered
    /// on every system tick, which cost a sustained 40% of a core.
    @Published var mounted = false
}

private struct CardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct CardRoot: View {
    @ObservedObject var presence: CardPresence
    let deps: CardDeps
    let onSize: (CGSize) -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if presence.mounted {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    CompactCard(store: deps.store, sessionStore: deps.sessionStore, clipboard: deps.clipboard,
                                focus: deps.focus, pages: deps.pages, system: deps.system, backpack: deps.backpack,
                                now: context.date, showsTabs: presence.showsTabs,
                                showsAppButtons: presence.showsAppButtons,
                                onRefresh: deps.refresh, onOpenSettings: deps.openSettings,
                                onQuit: deps.quit,
                                onSignInClaude: deps.signInClaude, onJump: deps.jump)
                }
            } else {
                Color.clear.frame(width: CardMetrics.width, height: 10)
            }
        }
        .environment(\.usageDisplayMode, settings.displayMode)
        .background(GlassBackground(radius: CardMetrics.radius))
        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous))
        .fixedSize()
        .background(GeometryReader { geo in
            Color.clear.preference(key: CardSizeKey.self, value: geo.size)
        })
        .onPreferenceChange(CardSizeKey.self) { onSize($0) }
        .scaleEffect(presence.visible || HMotion.reduceMotion ? 1 : 0.96, anchor: presence.origin)
        .opacity(presence.visible ? 1 : 0)
        .blur(radius: presence.visible || HMotion.reduceMotion ? 0 : 4)
        .animation(presence.visible ? AnchorMotion.morph : .easeIn(duration: 0.15), value: presence.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: presence.alignment)
    }
}

/// Glass that follows the system appearance, with a hairline edge.
struct GlassBackground: View {
    var radius: CGFloat
    var corners: RectangleCornerRadii? = nil
    var outline: AnyShape? = nil
    var body: some View {
        GlassShape(shape: outline
            ?? corners.map { AnyShape(UnevenRoundedRectangle(cornerRadii: $0, style: .continuous)) }
            ?? AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }
}

/// The glass itself, in a concrete shape: an animatable shape (the rail
/// growing a bubble) keeps animating through it, which a type-erased one
/// would not promise.
struct GlassShape<S: Shape>: View {
    var shape: S
    @Environment(\.snapshotRendering) private var snapshot
    var body: some View {
        // ImageRenderer cannot rasterise a material, so renders get a flat
        // stand-in of the same tone.
        shape.fill(snapshot || HMotion.reduceTransparency ? AnyShapeStyle(Dynamic.color(dark: .init(white: 0.13, alpha: HMotion.reduceTransparency ? 1 : 0.96),
                                                          light: .init(white: 0.96, alpha: HMotion.reduceTransparency ? 1 : 0.97)))
                            : AnyShapeStyle(.regularMaterial))
            .overlay(shape.fill(Dynamic.color(dark: .init(white: 0.08, alpha: 0.45), light: .init(white: 1, alpha: 0.35))))
            .overlay(shape.stroke(Dynamic.color(dark: .init(white: 1, alpha: 0.14), light: .init(white: 0, alpha: 0.12)), lineWidth: 0.75))
    }
}

/// One borderless panel hosting the compact card, placed by whichever anchor
/// opened it. Its frame follows the card's size, anchored at the corner the
/// card grows from, so the card never covers more of the screen than it draws.
@MainActor
final class CardPanelController {
    let panel: NotchPanel
    let presence = CardPresence()
    let deps: CardDeps
    private var host: FirstMouseHostingView<CardRoot>!
    private(set) var contentSize = CGSize(width: CardMetrics.width, height: 360)
    private var placement: ((CGSize) -> CGRect)?
    private var hideWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var shadow: ShadowFollower!
    private var cancellables: Set<AnyCancellable> = []
    /// Opened by the keyboard shortcut or a click: stays until dismissed.
    var pinned = false {
        didSet {
            syncKeyable()
            // Clicking a peek that is already open must also receive Esc.
            if pinned && !oldValue && presence.visible { panel.makeKey() }
        }
    }

    var isShown: Bool { presence.visible }
    var frame: CGRect { panel.frame }
    /// A focused text field (the focus timer's task name) holds the card open.
    var isEditing: Bool { panel.isKeyWindow && deps.pages.page == .focus }

    init(deps: CardDeps) {
        self.deps = deps
        panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: CardMetrics.width, height: 360),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        shadow = ShadowFollower(panel)
        host = FirstMouseHostingView(rootView: CardRoot(presence: presence, deps: deps,
                                                        onSize: { _ in }))
        host.onIntrinsicSizeChange = { [weak self] size in
            MainActor.assumeIsolated { self?.sizeChanged(size) }
        }
        host.autoresizingMask = [.width, .height]
        // Hotch places and sizes these windows itself. Left to its default,
        // the hosting view resizes the window to the content from the
        // bottom-left corner, which pushed a right-anchored pill off screen.
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        deps.pages.$page
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncKeyable() }
            .store(in: &cancellables)
    }

    func show(origin: UnitPoint, alignment: Alignment, showsTabs: Bool, appButtons: Bool = false,
              placement: @escaping (CGSize) -> CGRect) {
        hideWork?.cancel()
        self.placement = placement
        presence.origin = origin
        presence.alignment = alignment
        presence.showsAppButtons = appButtons
        presence.showsTabs = showsTabs
        presence.mounted = true
        panel.setFrame(placement(contentSize), display: false)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presence.visible = true
                self.syncKeyable()
                // Opened on purpose (shortcut, click): take the keyboard so
                // Esc closes it, without activating Hotch.
                if self.pinned { self.panel.makeKey() }
            }
        }
        shadow.follow()
    }

    func hide() {
        guard presence.visible else { return }
        presence.visible = false
        pinned = false
        panel.keyable = false
        if panel.isKeyWindow { panel.resignKey() }
        shadow.follow(for: 0.2)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.presence.visible else { return }
                self.panel.orderOut(nil)
                self.presence.mounted = false
                // A detour is not a place to come back to.
                self.deps.pages.macDetail = nil
                self.deps.pages.backpackCard = false
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Moves the card with its anchor (the rail dragged, the pill moved).
    func reposition() {
        guard presence.visible, let placement else { return }
        panel.setFrame(placement(contentSize), display: true)
    }

    private func sizeChanged(_ size: CGSize) {
        guard size.width > 1, size.height > 20, presence.mounted else { return }
        let old = contentSize
        contentSize = size
        guard presence.visible, let placement else { return }
        let target = placement(size)
        shrinkWork?.cancel()
        shadow.follow()
        if size.height < old.height - 0.5 {
            // Shrinking: let the content finish animating before the window
            // pulls in, or the outgoing section is clipped mid-transition.
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.presence.visible, let placement = self.placement else { return }
                    self.panel.setFrame(placement(self.contentSize), display: true)
                    self.shadow.follow(for: 0.05)
                }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.settle, execute: work)
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// The card takes the keyboard only for the focus timer's text field, or
    /// when the shortcut pinned it (so Esc can close it).
    private func syncKeyable() {
        panel.keyable = presence.visible && (deps.pages.page == .focus || pinned)
        if !panel.keyable && panel.isKeyWindow { panel.resignKey() }
    }
}

// MARK: - Screen-edge rail

@MainActor
final class RailState: ObservableObject {
    enum Phase: Equatable { case collapsed, expanded, alert }
    @Published var phase: Phase = .collapsed
    @Published var side: HotchPrefs.EdgeSide = .right
    @Published var alert: LiveActivity?
    @Published var dragging = false
    /// How far below the window's top the current shape is drawn.
    @Published var inset: CGFloat = 0
    /// The section icon under the pointer, lit before hovering commits to it.
    @Published var hovered: PanelPage?
}

/// Refreshes a window's shadow every frame while SwiftUI animates what it
/// draws. The window server builds the shadow from the content once, so
/// without this it lags the shape through every morph.
@MainActor
final class ShadowFollower {
    private weak var window: NSWindow?
    private var timer: Timer?
    private var until = Date.distantPast

    init(_ window: NSWindow) { self.window = window }

    func follow(for duration: TimeInterval = AnchorMotion.settle + 0.08) {
        until = max(until, Date().addingTimeInterval(duration))
        window?.invalidateShadow()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.invalidateShadow()
                if Date() >= self.until {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Six permanent section targets on the screen edge. AI, Sessions and Mac
/// carry compact live readouts; hovering opens the card beside the same
/// targets. Drag it to another display or to the left, right or bottom edge.
///
/// **The window never moves while the rail changes shape.** It is as tall as
/// every shape at this position and its top and screen-edge side stay put;
/// the view draws each shape at a fixed distance from that corner. A change
/// of shape is then pure SwiftUI animation. Resizing the window mid-morph,
/// as 2.1 did, put the shape in the wrong place for a frame and made it
/// jump wherever the tab and column were clamped differently (near the top
/// or bottom of the screen).
@MainActor
final class RailController {
    /// The shapes as drawn: the resting tab, the open column, an alert.
    static let tabSize = CGSize(width: RailGeometry.width, height: RailGeometry.height)
    static let columnSize = tabSize
    static var alertSize: CGSize { CGSize(width: tabSize.width + RailView.bubbleWidth, height: tabSize.height) }
    /// Lying along the bottom it is a second, smaller Dock in the space beside
    /// the real one: the same height and the same gap under it, worked out
    /// from the strip macOS keeps clear for the Dock (51pt here: a 44pt Dock
    /// 5pt off the bottom). With the Dock hidden or on a side, those defaults.
    static var dock: (height: CGFloat, gap: CGFloat) {
        guard let screen = Displays.screen(withID: HotchPrefs.shared.railDisplay) else { return (44, 5) }
        let strip = screen.visibleFrame.minY - screen.frame.minY
        guard strip >= 30 else { return (44, 5) }
        return (max(34, strip - 7), 5)
    }
    /// Bottom targets keep their positions while the card opens.
    static var barSize: CGSize { CGSize(width: RailGeometry.bottomWidth, height: dock.height) }
    static var barOpenSize: CGSize { barSize }

    static func size(for phase: RailState.Phase, side: HotchPrefs.EdgeSide) -> CGSize {
        if side == .bottom { return phase == .expanded ? barOpenSize : barSize }
        switch phase {
        case .collapsed: return tabSize
        case .expanded: return columnSize
        case .alert: return alertSize
        }
    }

    let panel: NotchPanel
    let state = RailState()
    let card: CardPanelController
    private let prefs = HotchPrefs.shared
    private var host: FirstMouseHostingView<RailView>!
    private var shadow: ShadowFollower!
    private var timer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var settleWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    /// Where the pointer holds the shape, as a share of its size, so the
    /// shape can turn to face another edge without leaving the pointer.
    private var dragStart: (grab: CGPoint, reopen: Bool, pinned: Bool)?
    /// Gliding to an edge after a drop or a side change; the pointer watch
    /// and placement refreshes wait for it.
    private var landing = false
    private var clickMonitor: Any?
    /// Along the bottom an alert is a label above the bar, in its own window.
    private let label = DockLabel()

    init(card: CardPanelController) {
        self.card = card
        panel = NotchPanel(contentRect: CGRect(origin: .zero, size: RailController.columnSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        shadow = ShadowFollower(panel)
        let deps = card.deps
        host = FirstMouseHostingView(rootView: RailView(
            state: state, pages: deps.pages, store: deps.store, sessionStore: deps.sessionStore,
            system: deps.system, focus: deps.focus,
            onSelect: { [weak self] page in self?.select(page) },
            onDrag: { [weak self] phase in self?.drag(phase) },
            onHover: { [weak self] page, inside in self?.hover(page, inside) },
            onAlertTap: { [weak self] alert in self?.card.deps.actOnAlert(alert) },
            onMove: { side in HotchPrefs.shared.edgeSide = side },
            onOpenSettings: deps.openSettings))
        host.autoresizingMask = [.width, .height]
        // Hotch places and sizes these windows itself. Left to its default,
        // the hosting view resizes the window to the content from the
        // bottom-left corner, which pushed a right-anchored pill off screen.
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        state.side = prefs.edgeSide
        label.onTap = { [weak self] alert in self?.card.deps.actOnAlert(alert) }
    }

    /// The display the rail was put on, or the main display.
    var screen: NSScreen? { Displays.screen(withID: prefs.railDisplay) }

    /// An app is full screen on the rail's display: the rail steps aside
    /// (invisible, letting clicks through) and comes back while it is open,
    /// speaking or being moved. A push against the edge still opens it.
    var stepAside = false {
        didSet { if stepAside != oldValue { applyVisibility() } }
    }

    private func applyVisibility() {
        let hidden = stepAside && state.phase == .collapsed && !state.dragging && !landing
        panel.ignoresMouseEvents = hidden
        guard (panel.alphaValue < 0.5) != hidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HMotion.reduceMotion ? 0.01 : (hidden ? 0.2 : 0.14)
            panel.animator().alphaValue = hidden ? 0 : 1
        }
    }

    private var centerY: CGFloat {
        guard let visible = screen?.visibleFrame else { return 400 }
        return visible.maxY - CGFloat(prefs.edgeOffset) * visible.height
    }

    /// Where a shape of this size sits on screen: on its edge, centred on
    /// the rail's stored position, kept on screen.
    private func frame(for size: CGSize) -> CGRect {
        guard let screen else { return CGRect(origin: .zero, size: size) }
        if state.side == .bottom {
            let full = screen.frame
            let gap = Self.dock.gap
            let x = min(max(full.minX + CGFloat(prefs.bottomOffset) * full.width - size.width / 2, full.minX + gap),
                        full.maxX - size.width - gap)
            return CGRect(x: x, y: full.minY + gap, width: size.width, height: size.height)
        }
        let visible = screen.visibleFrame
        let y = min(max(centerY - size.height / 2, visible.minY + 6), visible.maxY - size.height - 6)
        let x = state.side == .right ? screen.frame.maxX - size.width : screen.frame.minX
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The window for a phase: tall enough for every shape at this position,
    /// as wide as the shape (an alert is wide). Top and edge side are the
    /// same for every phase.
    private func panelFrame(for phase: RailState.Phase) -> CGRect {
        guard let screen else { return CGRect(origin: .zero, size: Self.columnSize) }
        if state.side == .bottom { return frame(for: Self.size(for: phase, side: .bottom)) }
        let shapes = [Self.tabSize, Self.columnSize, Self.alertSize].map { frame(for: $0) }
        let top = shapes.map(\.maxY).max() ?? 0
        let bottom = shapes.map(\.minY).min() ?? 0
        let width = phase == .alert ? Self.alertSize.width : Self.columnSize.width
        let x = state.side == .right ? screen.frame.maxX - width : screen.frame.minX
        return CGRect(x: x, y: bottom, width: width, height: top - bottom)
    }

    private var restingFrame: CGRect { frame(for: Self.size(for: .collapsed, side: state.side)) }
    private var openFrame: CGRect { frame(for: Self.size(for: .expanded, side: state.side)) }

    /// The speaking bubble on screen, beside the readout it is about (or,
    /// along the bottom, the line the bar grows on top).
    private var bubbleFrame: CGRect {
        if state.side == .bottom { return label.frame }
        let tab = frame(for: Self.tabSize)
        let w = RailView.bubbleWidth, h = RailView.bubbleHeight
        let y = tab.maxY - RailView.bubbleCenter(for: state.alert) - h / 2
        return CGRect(x: state.side == .right ? tab.minX - w : tab.maxX, y: y, width: w, height: h)
    }

    private func inset(for phase: RailState.Phase) -> CGFloat {
        guard state.side != .bottom else { return 0 }
        return panelFrame(for: phase).maxY - frame(for: Self.size(for: phase, side: state.side)).maxY
    }

    func start() {
        state.side = prefs.edgeSide
        state.inset = inset(for: .collapsed)
        panel.setFrame(panelFrame(for: .collapsed), display: true)
        panel.orderFrontRegardless()
        applyVisibility()
        card.deps.system.setDemand(.menuBar, for: "rail")
        let timer = Timer(timeInterval: AnchorMotion.poll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hoverWork?.cancel()
        settleWork?.cancel()
        state.hovered = nil
        removeClickMonitor()
        card.hide()
        label.hide()
        panel.orderOut(nil)
        card.deps.system.setDemand(.idle, for: "rail")
    }

    /// The side or position changed in Settings, the right-click menu or a
    /// drop. A new side glides across rather than jumping.
    func refreshPlacement() {
        guard dragStart == nil, !landing else { return }
        if state.side != prefs.edgeSide && state.phase != .alert {
            let reopen = state.phase == .expanded
            let pinned = card.pinned
            settleWork?.cancel()
            removeClickMonitor()
            card.hide()
            withAnimation(AnchorMotion.morph) {
                state.dragging = true
                state.side = prefs.edgeSide
            }
            land(reopen: reopen, pinned: pinned)
            return
        }
        state.side = prefs.edgeSide
        settleWork?.cancel()
        state.inset = inset(for: state.phase)
        panel.setFrame(panelFrame(for: state.phase), display: true)
        card.reposition()
        shadow.follow(for: 0.05)
    }

    // MARK: Phases

    private func set(_ phase: RailState.Phase) {
        let target = panelFrame(for: phase)
        settleWork?.cancel()
        // A bigger window is put in place before the shape grows into it, a
        // smaller one once the shape has shrunk. Both keep the corner on the
        // edge where they are, so neither moves what is drawn.
        let cover = panel.frame.union(target)
        if !Self.same(cover, panel.frame) { panel.setFrame(cover, display: true) }
        withAnimation(AnchorMotion.morph) {
            state.phase = phase
            state.inset = inset(for: phase)
        }
        shadow.follow()
        applyVisibility()
        if state.side == .bottom, phase == .alert, let alert = state.alert, let screen {
            let bar = restingFrame
            label.show(alert, over: bar.minX + RailView.barCenter(RailView.readoutIndex(for: alert)),
                       above: bar.maxY + 6, on: screen.frame)
        } else {
            label.hide()
        }
        guard !Self.same(cover, target) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.phase == phase else { return }
                self.panel.setFrame(target, display: true)
                self.shadow.follow(for: 0.05)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.settle, execute: work)
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    func expand(pinned: Bool = false) {
        insideSince = nil
        outsideSince = nil
        set(.expanded)
        let side = state.side
        card.pinned = pinned
        let edge: RailGeometry.Side = side == .bottom ? .bottom : (side == .right ? .right : .left)
        // Reserve the cap plus header, footer and padding. Every page grows
        // away from one attachment, recalculated only if the rail moves.
        card.show(origin: side == .bottom ? .bottom : (side == .right ? .topTrailing : .topLeading),
                  alignment: side == .bottom ? .bottom : (side == .right ? .topTrailing : .topLeading),
                  showsTabs: false) { [weak self] size in
            guard let self, let visible = self.screen?.visibleFrame else { return CGRect(origin: .zero, size: size) }
            let column = self.openFrame
            let attachment = RailGeometry.cardAttachment(rail: column, visible: visible, side: edge,
                                                         maximumHeight: CardMetrics.maxSectionHeight + 76)
            return RailGeometry.cardFrame(size: size, rail: column, visible: visible,
                                          side: edge, attachment: attachment)
        }
        if pinned { installClickMonitor() }
        Haptics.tap()
    }

    func collapse() {
        removeClickMonitor()
        hoverWork?.cancel()
        state.hovered = nil
        card.hide()
        set(.collapsed)
    }

    func toggle() {
        guard dragStart == nil, !landing else { return }
        state.phase == .expanded ? collapse() : expand(pinned: true)
    }

    private func select(_ page: PanelPage) {
        hoverWork?.cancel()
        let wasCollapsed = state.phase != .expanded
        if wasCollapsed {
            openSection(page, contextual: true)
            expand(pinned: true)
        } else {
            card.pinned = true
            installClickMonitor()
            guard card.deps.pages.page != page || card.deps.pages.macDetail != nil || card.deps.pages.backpackCard else { return }
            card.deps.pages.select(page)
            Haptics.tap()
        }
    }

    private func openSection(_ page: PanelPage, contextual: Bool) {
        card.deps.pages.select(page)
        if contextual, page == .mac { card.deps.pages.macDetail = .memory }
    }

    /// The compact readouts occupy their section's permanent slot. Opening
    /// from Memory still goes straight to Mac › Memory.
    private func openOnReadout(at point: CGPoint) {
        let tab = restingFrame
        let position = state.side == .bottom ? point.x - tab.minX : tab.maxY - point.y
        let index = RailGeometry.nearestSlot(to: position, bottom: state.side == .bottom)
        openSection(PanelPage.allCases[index], contextual: true)
    }

    /// Hovering an icon lights it at once and opens its section only once
    /// the pointer rests there, so a pointer crossing the column on its way
    /// to the card does not flip sections as it passes.
    private func hover(_ page: PanelPage, _ inside: Bool) {
        if inside {
            withAnimation(.easeOut(duration: 0.12)) { state.hovered = page }
            hoverWork?.cancel()
            guard state.phase == .expanded else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.state.hovered == page, self.state.phase == .expanded,
                          self.dragStart == nil else { return }
                    guard self.card.deps.pages.page != page else { return }
                    self.card.deps.pages.select(page)
                    Haptics.tap()
                }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.hoverIntent, execute: work)
        } else if state.hovered == page {
            hoverWork?.cancel()
            withAnimation(.easeOut(duration: 0.12)) { state.hovered = nil }
        }
    }

    // MARK: Pointer

    private func tick() {
        guard !state.dragging, !landing, let screen else { return }
        let point = NSEvent.mouseLocation
        let now = Date()
        switch state.phase {
        case .collapsed, .alert:
            // A held button means a grab, not a hover: leave the tab as it is
            // so the drag picks up what was pressed.
            if NSEvent.pressedMouseButtons != 0 {
                insideSince = nil
                return
            }
            // Pushing the pointer against the screen edge beside the tab is
            // the quick gesture (the edge is an infinitely deep target);
            // resting on the tab's face opens it a beat later.
            let tab = restingFrame
            let edge: CGRect
            switch state.side {
            case .right: edge = CGRect(x: screen.frame.maxX - 14, y: tab.minY - 4, width: 14, height: tab.height + 8)
            case .left: edge = CGRect(x: screen.frame.minX, y: tab.minY - 4, width: 14, height: tab.height + 8)
            case .bottom: edge = CGRect(x: tab.minX - 4, y: screen.frame.minY, width: tab.width + 8,
                                        height: tab.minY - screen.frame.minY + 6)
            }
            let onEdge = edge.contains(point)
            // An alert's bubble is for clicking (it goes to what it is
            // about); resting on it does not open the card.
            let onAlert = state.phase == .alert && bubbleFrame.insetBy(dx: -2, dy: -4).contains(point)
            let onFace = tab.contains(point) && !(stepAside && state.phase == .collapsed)
            if (onEdge || onFace) && !onAlert {
                if let since = insideSince {
                    let dwell = onEdge ? AnchorMotion.dwell : AnchorMotion.tabDwell
                    if now.timeIntervalSince(since) >= dwell {
                        openOnReadout(at: point)
                        expand()
                    }
                } else {
                    insideSince = now
                }
            } else {
                insideSince = nil
            }
        case .expanded:
            let inside = openFrame.insetBy(dx: -8, dy: -10).contains(point)
                || (card.isShown && (card.frame.insetBy(dx: -10, dy: -10).contains(point)
                    || RailGeometry.hoverBridgeContains(point, rail: openFrame, card: card.frame)))
            if inside || card.pinned || card.isEditing {
                outsideSince = nil
            } else if let since = outsideSince {
                if now.timeIntervalSince(since) >= AnchorMotion.leave { collapse() }
            } else {
                outsideSince = now
            }
        }
    }

    /// The rail comes off the edge and follows the pointer anywhere on the
    /// screen, turning to face whichever edge is nearest the pointer (left,
    /// right, or the bottom beside the Dock). Let go and it glides onto that
    /// edge where it was dropped.
    private func drag(_ phase: RailView.DragPhase) {
        let mouse = NSEvent.mouseLocation
        // Whichever display the pointer is on: the rail can be carried to
        // another one and stays there.
        guard let screen = Displays.screen(containing: mouse) ?? screen else { return }
        let visible = screen.visibleFrame
        switch phase {
        case .changed:
            if dragStart == nil {
                guard state.phase != .alert, !landing else { return }
                // Pick up just the drawn shape as the window, so it can
                // change shape under the pointer.
                let size = Self.size(for: state.phase, side: state.side)
                let x = state.side == .right ? panel.frame.maxX - size.width : panel.frame.minX
                let shape = CGRect(x: x, y: panel.frame.maxY - state.inset - size.height,
                                   width: size.width, height: size.height)
                let grab = CGPoint(x: (mouse.x - shape.minX) / shape.width, y: (mouse.y - shape.minY) / shape.height)
                dragStart = (grab, state.phase == .expanded, card.pinned)
                settleWork?.cancel()
                hoverWork?.cancel()
                removeClickMonitor()
                card.hide()
                state.inset = 0
                panel.setFrame(shape, display: true)
                withAnimation(AnchorMotion.morph) {
                    state.dragging = true
                    state.hovered = nil
                }
                shadow.follow()
            }
            guard let start = dragStart else { return }
            let edge = nearestEdge(to: mouse, on: screen)
            if edge != state.side {
                state.side = edge
                shadow.follow()
            }
            let size = Self.size(for: state.phase, side: state.side)
            let x = min(max(mouse.x - start.grab.x * size.width, screen.frame.minX), screen.frame.maxX - size.width)
            let y = min(max(mouse.y - start.grab.y * size.height, screen.frame.minY), visible.maxY - size.height)
            panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        case .ended:
            guard let start = dragStart else { return }
            dragStart = nil
            let side = nearestEdge(to: mouse, on: screen)
            let dropped = panel.frame
            prefs.railDisplay = Displays.id(of: screen)
            if side == .bottom {
                prefs.bottomOffset = Double(min(max((dropped.midX - screen.frame.minX) / screen.frame.width, 0), 1))
            } else {
                prefs.edgeOffset = Double(min(max((visible.maxY - dropped.midY) / visible.height, 0), 1))
            }
            state.side = side
            prefs.edgeSide = side
            land(reopen: start.reopen, pinned: start.pinned)
        }
    }

    private func nearestEdge(to point: CGPoint, on screen: NSScreen) -> HotchPrefs.EdgeSide {
        let f = screen.frame
        let distances: [(HotchPrefs.EdgeSide, CGFloat)] = [
            (.left, point.x - f.minX), (.right, f.maxX - point.x), (.bottom, point.y - f.minY),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }

    /// Glide onto the edge. An open rail stays open if the pointer is still
    /// on it or the card was opened from the keyboard; otherwise it folds.
    private func land(reopen: Bool, pinned: Bool) {
        landing = true
        let phase: RailState.Phase = reopen ? .expanded : .collapsed
        let target = panelFrame(for: phase)
        withAnimation(AnchorMotion.morph) { state.inset = inset(for: phase) }
        shadow.follow(for: AnchorMotion.glide + 0.1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AnchorMotion.glide
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.landing = false
                self.panel.setFrame(target, display: true)
                withAnimation(AnchorMotion.morph) { self.state.dragging = false }
                self.shadow.follow()
                self.applyVisibility()
                Haptics.tap()
                guard reopen else { return }
                if pinned || self.openFrame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) {
                    self.expand(pinned: pinned)
                } else {
                    self.collapse()
                }
            }
        }
    }

    // MARK: Alerts

    /// The tab grows into a short message for a few seconds, then folds back.
    func present(_ activity: LiveActivity, done: @escaping () -> Void) {
        guard state.phase == .collapsed, dragStart == nil, !landing else { done(); return }
        state.alert = activity
        set(.alert)
        DispatchQueue.main.asyncAfter(deadline: .now() + activity.hold) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { done(); return }
                if self.state.phase == .alert { self.set(.collapsed) }
                DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.settle) {
                    MainActor.assumeIsolated {
                        self.state.alert = nil
                        done()
                    }
                }
            }
        }
    }

    // MARK: Pinned dismissal

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                if !self.openFrame.contains(point) && !self.card.frame.contains(point) {
                    self.collapse()
                }
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

struct RailView: View {
    enum DragPhase { case changed, ended }

    @ObservedObject var state: RailState
    @ObservedObject var pages: PopoverPageModel
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var system: SystemMonitor
    var focus: FocusStore? = nil
    let onSelect: (PanelPage) -> Void
    let onDrag: (DragPhase) -> Void
    var onHover: (PanelPage, Bool) -> Void = { _, _ in }
    var onAlertTap: (LiveActivity) -> Void = { _ in }
    var onMove: (HotchPrefs.EdgeSide) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var selection
    @Environment(\.snapshotRendering) private var snapshot

    private var right: Bool { state.side == .right }
    /// Lying along the bottom edge beside the Dock, rather than standing on
    /// a side.
    private var bottom: Bool { state.side == .bottom }
    private var mode: UsageDisplayMode { settings.displayMode }
    private var size: CGSize { RailController.size(for: state.phase, side: state.side) }

    // MARK: Metrics

    /// A long, tangent curve lets the rail flow out of the display edge.
    static let taper = RailGeometry.taper
    static let ring: CGFloat = 19
    static let ringLine: CGFloat = 1.8
    static let valueHeight: CGFloat = 10
    static let ringToValue: CGFloat = 1
    static var item: CGFloat { ring + ringToValue + valueHeight }
    static let bubbleWidth: CGFloat = 264
    static let bubbleHeight: CGFloat = 32
    static let barItem = RailGeometry.slot
    static let barRadius: CGFloat = 15

    private var ringSize: CGFloat { Self.ring }
    private var ringLine: CGFloat { Self.ringLine }

    /// Readout identities are Mac (memory), AI and Sessions. They never
    /// borrow another section's position when the rail opens.
    private static let readoutSlots = [PanelPage.mac.rawValue, PanelPage.ai.rawValue, PanelPage.agents.rawValue]
    static func ringCenter(_ index: Int) -> CGFloat {
        RailGeometry.center(readoutSlots[min(2, max(0, index))])
    }

    static func bubbleCenter(for alert: LiveActivity?) -> CGFloat {
        readoutIndex(for: alert).map(ringCenter) ?? RailController.tabSize.height / 2
    }

    static func readoutIndex(for alert: LiveActivity?) -> Int? {
        let key = alert?.key ?? ""
        if key == "mem" { return 0 }
        if key.hasPrefix("limit-") { return 1 }
        if key.hasPrefix("need-") || key.hasPrefix("done-") { return 2 }
        return nil
    }

    static func barCenter(_ index: Int?) -> CGFloat {
        guard let index else { return RailController.barSize.width / 2 }
        return RailGeometry.center(readoutSlots[min(2, max(0, index))], bottom: true)
    }

    // MARK: Body

    @ViewBuilder
    private var outline: some View {
        if state.dragging {
            // Off the edge it has nothing to blend into: a plain rounded
            // body, the tapers folded away.
            GlassBackground(radius: 14)
                .padding(bottom ? .horizontal : .vertical, Self.taper * 0.4)
                .transition(.opacity)
        } else {
            GlassShape(shape: RailShape(edge: state.side, taper: Self.taper,
                                        tabWidth: bottom ? nil : RailController.tabSize.width,
                                        bubble: state.phase == .alert && !bottom ? 1 : 0,
                                        bubbleCenter: Self.bubbleCenter(for: state.alert),
                                        bubbleLength: Self.bubbleWidth,
                                        bubbleHeight: Self.bubbleHeight))
                .transition(.opacity)
        }
    }

    var body: some View {
        Group {
            if bottom { bar } else { tab }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // Simultaneous, so a drag can start on a section icon too: the whole
        // rail is the handle.
        .simultaneousGesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in if state.phase != .alert { onDrag(.changed) } }
            .onEnded { _ in onDrag(.ended) })
        .contextMenu {
            ForEach(HotchPrefs.EdgeSide.allCases.filter { $0 != state.side }) { side in
                Button("Move to \(side.label) Edge") { onMove(side) }
            }
            Divider()
            Button("Hotch Settings…") { onOpenSettings() }
        }
        // Drawn at a fixed distance from the window's corner on the edge, so
        // the window can be resized without moving anything on screen.
        .padding(.top, state.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: windowCorner)
        .animation(AnchorMotion.morph, value: state.phase)
        .animation(AnchorMotion.morph, value: state.dragging)
    }

    private var windowCorner: Alignment {
        switch state.side {
        case .right: return .topTrailing
        case .left: return .topLeading
        case .bottom: return .bottom
        }
    }

    /// Standing on a side: readouts in a column, an alert as a bubble.
    private var tab: some View {
        ZStack(alignment: right ? .topTrailing : .topLeading) {
            outline
            slots
                .frame(width: RailController.tabSize.width, height: size.height)
            if state.phase == .alert, let a = state.alert {
                bubbleContent(a)
                    .frame(width: Self.bubbleWidth - 24, height: Self.bubbleHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onAlertTap(a) }
                    .help("Click to go to it")
                    .offset(x: right ? -(RailController.tabSize.width + 10) : RailController.tabSize.width + 10,
                            y: Self.bubbleCenter(for: a) - Self.bubbleHeight / 2)
                    .transition(.opacity)
            }
        }
    }

    /// Lying along the bottom: readouts in a row, in a container like the
    /// Dock's. An alert floats above it as a label, the way the Dock names an
    /// app (`DockLabel`).
    private var bar: some View {
        ZStack {
            dockGlass
            slots
        }
    }

    /// The Dock's own glass on macOS 26 and later, so the two read as a
    /// pair; Hotch's glass before that, and in renders.
    @ViewBuilder
    private var dockGlass: some View {
        let shape = RoundedRectangle(cornerRadius: Self.barRadius, style: .continuous)
        if #available(macOS 26.0, *), !snapshot, !HMotion.reduceTransparency {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            GlassShape(shape: shape)
        }
    }

    // MARK: Resting

    /// All six targets exist in every phase, with the same identity, center
    /// and accessible hit area. Expanding only reveals the card/highlight.
    @ViewBuilder
    private var slots: some View {
        if bottom {
            HStack(spacing: 0) {
                ForEach(PanelPage.allCases, id: \.rawValue) { sectionButton($0) }
            }
            .padding(.horizontal, RailGeometry.bottomInset)
        } else {
            VStack(spacing: 0) {
                ForEach(PanelPage.allCases, id: \.rawValue) { sectionButton($0) }
            }
            .padding(.vertical, RailGeometry.endInset)
        }
    }

    /// Memory gives the Mac slot its live context. The ring
    /// is memory used; amber, then red, as the kernel reports pressure.
    private var memoryReadout: some View {
        let memory = system.latest?.memory
        let color: Color = switch memory?.pressure {
        case .critical: HP.red
        case .warning: HP.amber
        default: HP.memory
        }
        return readout(memory.map { SysFmt.percent($0.usedPercent) }, unit: "%",
                       tint: memory?.pressure == .critical ? HP.red : HP.text) {
            ring(memory.map { $0.usedPercent / 100 }, color: color) { icon("memorychip") }
        }
        .help("Memory used")
    }

    /// The tightest plan window, around its provider's mark.
    private var aiReadout: some View {
        let tight = tightestWindow(in: store)
        let identity = tight.map { ProviderIdentity.identity(for: $0.0.providerID) }
        let critical = tight?.1.isCritical ?? false
        return readout(tight.flatMap { $0.1.percent(mode) }.map(SysFmt.percent), unit: "%",
                       tint: critical ? HP.red : HP.text) {
            ring(tight.flatMap { $0.1.fillShare(mode) },
                 color: critical ? HP.red : (identity?.accent ?? HP.text3)) {
                if let identity {
                    BrandMark(kind: identity.mark, size: 8, tint: identity.accent)
                } else {
                    icon(PanelPage.ai.symbol)
                }
            }
        }
        .help("Tightest AI plan window")
    }

    /// Active sessions, one short arc each (amber waits on you), so a count
    /// never reads as a percentage.
    private var sessionReadout: some View {
        let live = sessionStore.sessions
            .filter { $0.activity <= .shell }
            .sorted { $0.activity < $1.activity }
        let colors = live.prefix(Self.sessionSlots).map { session in
            session.activity == .needsInput ? HP.amber : ProviderIdentity.identity(for: session.providerID).accent
        }
        return readout("\(live.count)", unit: nil,
                       tint: needsYou ? HP.amber : (live.isEmpty ? HP.text3 : HP.text)) {
            ZStack {
                Circle().stroke(HP.track, lineWidth: ringLine)
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    let span = 1 / Double(Self.sessionSlots)
                    Circle()
                        .trim(from: Double(index) * span + 0.02, to: Double(index + 1) * span - 0.02)
                        .stroke(color, style: StrokeStyle(lineWidth: ringLine, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                icon(PanelPage.agents.symbol)
            }
            .frame(width: ringSize, height: ringSize)
        }
        .help(live.isEmpty ? "No active sessions" : "\(live.count) active session\(live.count == 1 ? "" : "s")")
    }

    static let sessionSlots = 6

    /// A ring with its icon in the middle and the value underneath.
    private func readout<Ring: View>(_ number: String?, unit: String?, tint: Color,
                                     @ViewBuilder ring: () -> Ring) -> some View {
        VStack(spacing: Self.ringToValue) {
            ring()
            Group {
                if let number {
                    Text(number).foregroundStyle(tint)
                        + Text(unit ?? "").font(.system(size: 7, weight: .semibold, design: .rounded))
                            .foregroundStyle(HP.text3)
                } else {
                    Text("–").foregroundStyle(HP.text3)
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .frame(height: Self.valueHeight)
        }
        .frame(width: RailGeometry.slot, height: Self.item)
    }

    private func ring<Center: View>(_ share: Double?, color: Color,
                                    @ViewBuilder center: () -> Center) -> some View {
        // Whole percents, and no easing: memory and CPU move every second,
        // and a ring easing each move kept the tab drawing frames almost
        // continuously (about 7% of a core at rest).
        let step = share.map { (min(1, max(0, $0)) * 100).rounded() / 100 }
        return ZStack {
            Circle().stroke(HP.track, lineWidth: ringLine)
            if let step {
                Circle()
                    .trim(from: 0, to: max(0.015, step))
                    .stroke(color, style: StrokeStyle(lineWidth: ringLine, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center()
        }
        .frame(width: ringSize, height: ringSize)
        .transaction { $0.animation = nil }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(HP.text2)
    }

    private var needsYou: Bool { sessionStore.needsInputCount > 0 }

    // MARK: Section targets

    @ViewBuilder
    private func sectionVisual(_ page: PanelPage) -> some View {
        switch page {
        case .mac: memoryReadout
        case .ai: aiReadout
        case .agents: sessionReadout
        case .focus:
            if let focus {
                AnchorFocusReadout(focus: focus, style: .rail)
            } else {
                Image(systemName: page.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(HP.text3)
            }
        default:
            Image(systemName: page.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.phase == .expanded && pages.page == page ? HP.text : HP.text3)
        }
    }

    private func sectionValue(_ page: PanelPage) -> String {
        switch page {
        case .mac:
            return system.latest.map { "Memory, \(SysFmt.percent($0.memory.usedPercent)) percent used" } ?? "Memory unavailable"
        case .ai:
            let tight = tightestWindow(in: store)
            return tight.flatMap { $0.1.percent(mode) }.map { "\(SysFmt.percent($0)) percent \(mode == .used ? "used" : "remaining")" } ?? "AI usage unavailable"
        case .agents:
            let count = sessionStore.sessions.filter { $0.activity <= .shell }.count
            return "\(count) active sessions" + (needsYou ? ", needs attention" : "")
        case .focus:
            guard let focus, let time = AnchorFocusClock.readout(focus) else { return "No timer running" }
            return "\(time.value) \(time.caption)"
        default: return ""
        }
    }

    private func sectionButton(_ page: PanelPage) -> some View {
        let selected = state.phase == .expanded && page == pages.page && !pages.backpackCard
        let hovered = state.hovered == page && !selected
        return Button { onSelect(page) } label: {
            sectionVisual(page)
                .frame(width: RailGeometry.slot, height: RailGeometry.slot)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(HP.pill)
                            .matchedGeometryEffect(id: "selection", in: selection)
                    } else if hovered {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(HP.pill.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { onHover(page, $0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page.title)
        .accessibilityValue(sectionValue(page))
        .accessibilityHint(state.phase == .expanded ? "Show section" : "Open section. Drag to move the rail.")
        .help(page.title + (sectionValue(page).isEmpty ? "" : " · " + sectionValue(page)))
    }

    // MARK: Speaking

    private func bubbleContent(_ a: LiveActivity) -> some View {
        HStack(spacing: 7) {
            if right {
                alertIcon(a)
                Text(a.leading).foregroundStyle(HP.text).lineLimit(1)
                Spacer(minLength: 4)
                if a.dot { Circle().fill(a.trailingTint).frame(width: 5, height: 5) }
                Text(a.trailing).foregroundStyle(a.trailingTint).lineLimit(1).fixedSize()
            } else {
                if a.dot { Circle().fill(a.trailingTint).frame(width: 5, height: 5) }
                Text(a.trailing).foregroundStyle(a.trailingTint).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                Text(a.leading).foregroundStyle(HP.text).lineLimit(1)
                alertIcon(a)
            }
        }
        .font(.system(size: 11, weight: .semibold))
    }

    @ViewBuilder
    private func alertIcon(_ a: LiveActivity) -> some View {
        switch a.icon {
        case .brand(let id):
            let identity = ProviderIdentity.identity(for: id)
            BrandMark(kind: identity.mark, size: 13, tint: identity.accent)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 11, weight: .semibold)).foregroundStyle(a.tint)
        }
    }
}

/// The rail's whole outline, one path so the glass and its hairline run
/// unbroken: the tab (square on the screen edge, ends thinning into it) and,
/// while it speaks, a bubble that slides out of the tab beside the readout
/// the alert is about, joined to it by small inward curves.
struct RailShape: Shape {
    var edge: HotchPrefs.EdgeSide
    var taper: CGFloat
    /// The tab's depth from the edge, with any bubble reaching beyond it;
    /// nil when the tab is the whole shape.
    var tabWidth: CGFloat?
    /// 0 hidden in the tab, 1 fully out.
    var bubble: CGFloat
    /// From the top of the shape to the bubble's middle.
    var bubbleCenter: CGFloat
    var bubbleLength: CGFloat
    var bubbleHeight: CGFloat

    var animatableData: CGFloat {
        get { bubble }
        set { bubble = newValue }
    }

    /// Drawn once, for the right edge, and mirrored for the left.
    func path(in rect: CGRect) -> Path {
        switch edge {
        case .right:
            return standing(in: rect)
        case .left:
            return standing(in: rect)
                .applying(CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
        case .bottom:
            // The bottom bar is a Dock-style container, drawn by the view.
            return Path(roundedRect: rect, cornerRadius: RailView.barRadius, style: .continuous)
        }
    }

    private func standing(in rect: CGRect) -> Path {
        let tabWidth = self.tabWidth ?? rect.width
        let tab = CGRect(x: rect.maxX - tabWidth, y: rect.minY, width: tabWidth, height: rect.height)
        var path = EdgeTabShape(right: true, taper: taper).path(in: tab)
        let out = bubbleLength * max(0, min(1, bubble))
        if out > 0.5 {
            let inner = tab.minX
            let top = rect.minY + bubbleCenter - bubbleHeight / 2
            // Ends at the screen edge, under the tab, so its far corners never show.
            let body = CGRect(x: inner - out, y: top, width: out + tabWidth, height: bubbleHeight)
            path = path.union(Path(roundedRect: body, cornerRadius: min(bubbleHeight / 2, out / 2), style: .continuous))
            // The inward curves where the bubble meets the tab, grown in
            // with the bubble so a short stub has no ears.
            let r = min(8, out / 3)
            if r > 0.5 {
                var fillets = Path()
                fillets.move(to: CGPoint(x: inner + 0.5, y: top - r))
                fillets.addLine(to: CGPoint(x: inner, y: top - r))
                fillets.addQuadCurve(to: CGPoint(x: inner - r, y: top), control: CGPoint(x: inner, y: top))
                fillets.addLine(to: CGPoint(x: inner - r, y: top + 0.5))
                fillets.addLine(to: CGPoint(x: inner + 0.5, y: top + 0.5))
                fillets.closeSubpath()
                let bottom = top + bubbleHeight
                fillets.move(to: CGPoint(x: inner + 0.5, y: bottom + r))
                fillets.addLine(to: CGPoint(x: inner, y: bottom + r))
                fillets.addQuadCurve(to: CGPoint(x: inner - r, y: bottom), control: CGPoint(x: inner, y: bottom))
                fillets.addLine(to: CGPoint(x: inner - r, y: bottom - 0.5))
                fillets.addLine(to: CGPoint(x: inner + 0.5, y: bottom - 0.5))
                fillets.closeSubpath()
                path = path.union(fillets)
            }
        }
        return path
    }
}

/// The rail's outline. Square against the screen edge; at the top and bottom
/// an S-curve leaves the edge at a tangent and thins the tab to nothing, so it
/// reads as a swell in the edge rather than a box stuck to it. Drawn for the
/// right edge and mirrored for the left.
struct EdgeTabShape: Shape {
    var right: Bool
    var taper: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = min(taper, rect.height / 2)
        // Closed just past the edge, so the stroke along it is clipped away
        // by the window and only the curved side shows a hairline.
        let edge = rect.maxX + 1
        let inner = rect.minX
        var p = Path()
        p.move(to: CGPoint(x: edge, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addCurve(to: CGPoint(x: inner, y: rect.minY + t),
                   control1: CGPoint(x: rect.maxX, y: rect.minY + t * 0.62),
                   control2: CGPoint(x: inner, y: rect.minY + t * 0.38))
        p.addLine(to: CGPoint(x: inner, y: rect.maxY - t))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                   control1: CGPoint(x: inner, y: rect.maxY - t * 0.38),
                   control2: CGPoint(x: rect.maxX, y: rect.maxY - t * 0.62))
        p.addLine(to: CGPoint(x: edge, y: rect.maxY))
        p.closeSubpath()
        guard !right else { return p }
        return p.applying(CGAffineTransform(translationX: rect.minX + rect.maxX, y: 0).scaledBy(x: -1, y: 1))
    }
}

/// The bottom bar's alert: a small glass label floating above the bar, over
/// the readout it is about, the way the Dock names an app above its icon.
/// Its own window, so the bar never changes shape and the label can be
/// wider than the bar.
@MainActor
final class DockLabel {
    private let panel: NotchPanel
    private let state = DockLabelState()
    private var host: FirstMouseHostingView<DockLabelView>!
    private var hideWork: DispatchWorkItem?
    var onTap: (LiveActivity) -> Void = { _ in }

    init() {
        panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 28),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        host = FirstMouseHostingView(rootView: DockLabelView(state: state, onTap: { [weak self] alert in
            self?.onTap(alert)
        }))
        host.sizingOptions = [.intrinsicContentSize]
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    var frame: CGRect { state.visible ? panel.frame : .zero }

    func show(_ alert: LiveActivity, over x: CGFloat, above y: CGFloat, on screen: CGRect) {
        hideWork?.cancel()
        state.alert = alert
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let left = min(max(x - size.width / 2, screen.minX + 5), screen.maxX - size.width - 5)
        panel.setFrame(CGRect(x: left, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        withAnimation(AnchorMotion.morph) { state.visible = true }
    }

    func hide() {
        guard state.visible else { return }
        withAnimation(.easeIn(duration: 0.15)) { state.visible = false }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.state.visible else { return }
                self.panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

@MainActor
final class DockLabelState: ObservableObject {
    @Published var alert: LiveActivity?
    @Published var visible = false
}

struct DockLabelView: View {
    @ObservedObject var state: DockLabelState
    var onTap: (LiveActivity) -> Void = { _ in }
    @Environment(\.snapshotRendering) private var snapshot

    var body: some View {
        Group {
            if let a = state.alert {
                HStack(spacing: 7) {
                    switch a.icon {
                    case .brand(let id):
                        let identity = ProviderIdentity.identity(for: id)
                        BrandMark(kind: identity.mark, size: 12, tint: identity.accent)
                    case .symbol(let name):
                        Image(systemName: name).font(.system(size: 11, weight: .semibold)).foregroundStyle(a.tint)
                    }
                    Text(a.leading).foregroundStyle(HP.text)
                    if a.dot { Circle().fill(a.trailingTint).frame(width: 5, height: 5) }
                    Text(a.trailing).foregroundStyle(a.trailingTint)
                }
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 28)
                .modifier(LabelGlass(snapshot: snapshot))
                .contentShape(Capsule())
                .onTapGesture { onTap(a) }
                .help("Click to go to it")
            }
        }
        .scaleEffect(state.visible ? 1 : 0.92, anchor: .bottom)
        .offset(y: state.visible ? 0 : 4)
        .opacity(state.visible ? 1 : 0)
    }
}

/// The Dock's own glass on macOS 26 and later; Hotch's glass before that.
private struct LabelGlass: ViewModifier {
    var snapshot: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !snapshot {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(GlassShape(shape: Capsule()))
        }
    }
}

/// The plan window closest to its limit, across every provider: what the
/// rail tab, the pill and the orb all lead with.
@MainActor
func tightestWindow(in store: UsageStore) -> (ProviderUsage, UsageWindow)? {
    var best: (ProviderUsage, UsageWindow)?
    for u in store.usages {
        for w in u.windows where (w.consumedPercent ?? -1) > (best?.1.consumedPercent ?? -1) {
            best = (u, w)
        }
    }
    return best
}

// MARK: - Floating pill and orb

@MainActor
final class FloatState: ObservableObject {
    enum Style { case pill, orb }
    @Published var style: Style = .pill
    @Published var alert: LiveActivity?
    @Published var dragging = false
    /// Hangs from the right: grows leftward, the orb's ring stays right.
    @Published var right = true
    /// Too near the bottom of the screen to grow down: grows up instead.
    @Published var growsUp = false
}

/// A small floating object you can put anywhere. The pill reads like a status
/// line; the orb is a single ring, chat-head style. Hover either and the card
/// opens beside it; drag it and it snaps to the nearer side on release.
@MainActor
final class FloatController {
    let panel: NotchPanel
    let state = FloatState()
    let card: CardPanelController
    private let prefs = HotchPrefs.shared
    private var host: FirstMouseHostingView<FloatView>!
    private var timer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var size = CGSize(width: 200, height: 30)
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var clickMonitor: Any?
    private var shrinkWork: DispatchWorkItem?
    private var shadow: ShadowFollower!
    private static let margin: CGFloat = 12

    init(card: CardPanelController, style: FloatState.Style) {
        self.card = card
        state.style = style
        panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 30),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        shadow = ShadowFollower(panel)
        let deps = card.deps
        host = FirstMouseHostingView(rootView: FloatView(
            state: state, store: deps.store, sessionStore: deps.sessionStore, system: deps.system, focus: deps.focus,
            onSize: { _ in },
            onDrag: { [weak self] ended in self?.drag(ended: ended) },
            onTap: { [weak self] in
                guard let self else { return }
                if let alert = self.state.alert { self.card.deps.actOnAlert(alert) } else { self.toggle() }
            }))
        host.onIntrinsicSizeChange = { [weak self] size in
            MainActor.assumeIsolated { self?.sizeChanged(size) }
        }
        host.autoresizingMask = [.width, .height]
        // Hotch places and sizes these windows itself. Left to its default,
        // the hosting view resizes the window to the content from the
        // bottom-left corner, which pushed a right-anchored pill off screen.
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
    }

    /// The display the pill or orb was put on, or the main display.
    var screen: NSScreen? { Displays.screen(withID: prefs.floatDisplay) }
    private var visible: CGRect { screen?.visibleFrame ?? .zero }

    /// An app is full screen on this display: the pill or orb steps aside,
    /// and comes back while the card is open or it has something to say.
    var stepAside = false {
        didSet { if stepAside != oldValue { applyVisibility() } }
    }

    private var hiddenForFullscreen: Bool { stepAside && !card.isShown && state.alert == nil && !state.dragging }

    private func applyVisibility() {
        let hidden = hiddenForFullscreen
        panel.ignoresMouseEvents = hidden
        guard (panel.alphaValue < 0.5) != hidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HMotion.reduceMotion ? 0.01 : (hidden ? 0.2 : 0.14)
            panel.animator().alphaValue = hidden ? 0 : 1
        }
    }

    /// The display changed (connected, disconnected, rearranged).
    func refreshPlacement() {
        panel.setFrame(storedFrame(for: size), display: true)
        card.reposition()
        applyVisibility()
    }

    /// Right half of the screen anchors the object by its right edge, so it
    /// grows leftwards and never off screen.
    private var anchoredRight: Bool { prefs.floatX > 0.5 }

    private func storedFrame(for size: CGSize) -> CGRect {
        let v = visible
        let x = v.minX + Self.margin + CGFloat(prefs.floatX) * (v.width - size.width - Self.margin * 2)
        let y = v.maxY - Self.margin - size.height - CGFloat(prefs.floatY) * (v.height - size.height - Self.margin * 2)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func start() {
        state.right = anchoredRight
        host.layoutSubtreeIfNeeded()
        let measured = host.intrinsicContentSize
        if measured.width > 1, measured.height > 1 { size = measured }
        panel.setFrame(storedFrame(for: size), display: true)
        panel.orderFrontRegardless()
        applyVisibility()
        card.deps.system.setDemand(.menuBar, for: "float")
        let timer = Timer(timeInterval: AnchorMotion.poll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        removeClickMonitor()
        card.hide()
        panel.orderOut(nil)
        card.deps.system.setDemand(.idle, for: "float")
    }

    /// The anchored side and the top (or, near the bottom of the screen, the
    /// bottom) stay still while the object grows a message and folds it
    /// away. The window grows first and shrinks last, so the shape is never
    /// clipped while it moves, and the view is drawn against that corner.
    private func sizeChanged(_ newSize: CGSize) {
        guard newSize.width > 1, newSize.height > 1, !state.dragging else { return }
        size = newSize
        shrinkWork?.cancel()
        shadow.follow()
        let old = panel.frame
        let cover = CGSize(width: max(old.width, newSize.width), height: max(old.height, newSize.height))
        panel.setFrame(place(cover, from: old), display: true)
        card.reposition()
        guard cover != newSize else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.state.dragging else { return }
                self.panel.setFrame(self.place(self.size, from: self.panel.frame), display: true)
                self.shadow.follow(for: 0.05)
                self.card.reposition()
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.settle, execute: work)
    }

    private func place(_ size: CGSize, from old: CGRect) -> CGRect {
        let x = anchoredRight ? old.maxX - size.width : old.minX
        let y = state.growsUp ? old.minY : old.maxY - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func expand(pinned: Bool = false) {
        insideSince = nil
        outsideSince = nil
        let anchor = panel.frame
        let right = anchoredRight
        let v = visible
        card.pinned = pinned
        let below = anchor.minY - 8 - card.contentSize.height >= v.minY + 6
        let alignment: Alignment = below ? (right ? .topTrailing : .topLeading)
                                         : (right ? .bottomTrailing : .bottomLeading)
        card.show(origin: right ? .topTrailing : .topLeading, alignment: alignment, showsTabs: true) { size in
            var x = right ? anchor.maxX - size.width : anchor.minX
            x = min(max(x, v.minX + 6), v.maxX - size.width - 6)
            let below = anchor.minY - 8 - size.height
            let y = below >= v.minY + 6 ? below : min(anchor.maxY + 8, v.maxY - size.height - 6)
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        if pinned { installClickMonitor() }
        applyVisibility()
    }

    func collapse() {
        removeClickMonitor()
        card.hide()
        applyVisibility()
    }

    func toggle() {
        card.isShown ? collapse() : expand(pinned: true)
    }

    private func tick() {
        guard !state.dragging, !hiddenForFullscreen else { return }
        let point = NSEvent.mouseLocation
        let now = Date()
        if !card.isShown {
            if panel.frame.insetBy(dx: -2, dy: -2).contains(point) {
                if let since = insideSince {
                    if now.timeIntervalSince(since) >= AnchorMotion.dwell + 0.04 { expand() }
                } else {
                    insideSince = now
                }
            } else {
                insideSince = nil
            }
        } else {
            let inside = panel.frame.insetBy(dx: -6, dy: -6).contains(point)
                || card.frame.insetBy(dx: -8, dy: -8).contains(point)
                || bridge.contains(point)
            if inside || card.pinned || card.isEditing {
                outsideSince = nil
            } else if let since = outsideSince {
                if now.timeIntervalSince(since) >= AnchorMotion.leave { collapse() }
            } else {
                outsideSince = now
            }
        }
    }

    /// The gap between the object and the card, so crossing it is not leaving.
    private var bridge: CGRect {
        panel.frame.union(card.frame).insetBy(dx: 30, dy: 0)
    }

    private func drag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if !ended {
            if dragStart == nil {
                dragStart = (mouse, panel.frame.origin)
                state.dragging = true
                collapse()
            }
            guard let start = dragStart else { return }
            panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                         y: start.origin.y + mouse.y - start.mouse.y))
            return
        }
        dragStart = nil
        state.dragging = false
        // Dropped on another display: it lives there now.
        if let dropped = Displays.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY)) {
            prefs.floatDisplay = Displays.id(of: dropped)
        }
        state.right = panel.frame.midX > visible.midX
        // Snap to the nearer side, like a picture-in-picture window, and
        // keep the height where it was dropped.
        let v = visible
        let frame = panel.frame
        let right = frame.midX > v.midX
        let usableW = max(1, v.width - frame.width - Self.margin * 2)
        let usableH = max(1, v.height - frame.height - Self.margin * 2)
        prefs.floatX = right ? 1 : 0
        let top = min(max(v.maxY - Self.margin - frame.maxY, 0), usableH)
        prefs.floatY = Double(top / usableH)
        _ = usableW
        let target = storedFrame(for: frame.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            panel.animator().setFrame(target, display: true)
        }
    }

    /// The pill or orb shows the message itself for a few seconds.
    func present(_ activity: LiveActivity, done: @escaping () -> Void) {
        guard !card.isShown, !state.dragging else { done(); return }
        // Grow away from the bottom of the screen: a message line or two is
        // about 32pt.
        state.growsUp = panel.frame.minY - 36 < visible.minY + 6
        withAnimation(AnchorMotion.morph) { state.alert = activity }
        applyVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + activity.hold) { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(AnchorMotion.morph) { self?.state.alert = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + AnchorMotion.settle) {
                    MainActor.assumeIsolated { self?.applyVisibility() }
                    done()
                }
            }
        }
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                if !self.panel.frame.contains(point) && !self.card.frame.contains(point) { self.collapse() }
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

struct FloatView: View {
    @ObservedObject var state: FloatState
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var system: SystemMonitor
    var focus: FocusStore? = nil
    let onSize: (CGSize) -> Void
    let onDrag: (Bool) -> Void
    let onTap: () -> Void

    @Environment(\.usageDisplayMode) private var mode

    private var corner: Alignment {
        switch (state.growsUp, state.right) {
        case (false, true): return .topTrailing
        case (false, false): return .topLeading
        case (true, true): return .bottomTrailing
        case (true, false): return .bottomLeading
        }
    }

    var body: some View {
        Group {
            if state.style == .pill { pill } else { orb }
        }
        .fixedSize()
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { _ in onDrag(false) }
            .onEnded { _ in onDrag(true) })
        .onTapGesture(perform: onTap)
        .animation(AnchorMotion.morph, value: state.alert?.id)
        // Drawn against the corner the window keeps still, so the window
        // catching up with a new size never moves the object.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
    }

    // MARK: Pill

    /// The pill stays as it is when something needs saying: the message
    /// arrives as a second line in the same glass.
    private var pill: some View {
        VStack(alignment: state.right ? .trailing : .leading, spacing: 0) {
            if state.growsUp, let a = state.alert { messageRow(a, divider: .bottom) }
            pillRow
                .frame(maxWidth: .infinity, alignment: state.right ? .trailing : .leading)
            if !state.growsUp, let a = state.alert { messageRow(a, divider: .top) }
        }
        .background(GlassBackground(radius: 15))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .help("Hotch · hover to open, drag to move")
    }

    private func messageRow(_ a: LiveActivity, divider edge: VerticalEdge) -> some View {
        message(a)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Rectangle().fill(HP.track).frame(height: 0.5).padding(.horizontal, 11)
            }
            .transition(.opacity.combined(with: .offset(y: edge == .top ? -6 : 6)))
    }

    private var pillRow: some View {
        HStack(spacing: 9) {
            if let (usage, window) = tightest {
                let identity = ProviderIdentity.identity(for: usage.providerID)
                HStack(spacing: 5) {
                    BrandMark(kind: identity.mark, size: 12, tint: identity.accent)
                    Text(window.percent(mode).map { Fmt.percent($0) } ?? "—")
                        .foregroundStyle(window.isCritical ? HP.red : HP.text)
                }
                divider
            }
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                    .shadow(color: statusColor.opacity(0.8), radius: needsYou ? 3 : 0)
                Text(statusText).foregroundStyle(needsYou ? HP.amber : HP.text)
            }
            if let memory = system.latest?.memory {
                divider
                HStack(spacing: 3) {
                    Text("Mem").foregroundStyle(HP.text3)
                    Text("\(SysFmt.percent(memory.usedPercent))%")
                        .foregroundStyle(memory.pressure == .critical ? HP.red : HP.text).monospacedDigit()
                }
            }
            if let focus {
                AnchorFocusReadout(focus: focus, style: .inline)
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 11)
        .frame(height: 30)
    }

    private var divider: some View {
        Rectangle().fill(HP.track).frame(width: 1, height: 12)
    }

    // MARK: Orb

    /// The orb keeps its place on its side; a message stretches it into a
    /// capsule toward the middle of the screen, the ring still at the end.
    private var orb: some View {
        HStack(spacing: 0) {
            if !state.right { orbCore }
            if let focus {
                AnchorFocusReadout(focus: focus, style: .inline)
            }
            if let a = state.alert {
                message(a)
                    .padding(state.right ? .leading : .trailing, 18)
                    .padding(state.right ? .trailing : .leading, 4)
                    .transition(.opacity.combined(with: .offset(x: state.right ? 10 : -10)))
            }
            if state.right { orbCore }
        }
        .frame(height: 46)
        .background(GlassBackground(radius: 23))
        .clipShape(Capsule(style: .continuous))
        .overlay(alignment: state.right ? .topTrailing : .topLeading) {
            if needsYou || working > 0 {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1.5))
                    .shadow(color: statusColor.opacity(0.8), radius: 3)
                    .modifier(Pulse(on: working > 0 && !needsYou))
                    .offset(x: state.right ? 0 : 36)
            }
        }
        .contentShape(Capsule())
        .help("Hotch · hover to open, drag to move")
    }

    private var orbCore: some View {
        ZStack {
            if let (usage, window) = tightest {
                let identity = ProviderIdentity.identity(for: usage.providerID)
                ForecastRing(share: window.fillShare(mode), isCritical: window.isCritical,
                             color: identity.accent, size: 36, lineWidth: 3.4)
                BrandMark(kind: identity.mark, size: 14, tint: identity.accent)
            } else {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HP.text2)
            }
        }
        .frame(width: 46, height: 46)
    }

    // MARK: Message

    private func message(_ a: LiveActivity) -> some View {
        HStack(spacing: 7) {
            switch a.icon {
            case .brand(let id):
                let identity = ProviderIdentity.identity(for: id)
                BrandMark(kind: identity.mark, size: 12, tint: identity.accent)
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 11, weight: .semibold)).foregroundStyle(a.tint)
            }
            Text(a.leading).foregroundStyle(HP.text)
            if a.dot { Circle().fill(a.trailingTint).frame(width: 5, height: 5) }
            Text(a.trailing).foregroundStyle(a.trailingTint)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: Data

    private var tightest: (ProviderUsage, UsageWindow)? { tightestWindow(in: store) }

    private var needsYou: Bool { sessionStore.needsInputCount > 0 }
    private var working: Int { sessionStore.sessions.filter { $0.activity == .working || $0.activity == .shell }.count }

    private var statusColor: Color {
        if needsYou { return HP.amber }
        if working > 0 { return HP.ok }
        return HP.text3.opacity(0.6)
    }

    private var statusText: String {
        if needsYou { return sessionStore.needsInputCount == 1 ? "1 needs you" : "\(sessionStore.needsInputCount) need you" }
        if working > 0 { return "\(working) working" }
        return "idle"
    }
}

// MARK: - Keyboard shortcut

/// ⌥⌘H, registered with Carbon's hot key API: it needs no Accessibility
/// permission, unlike a global key monitor.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: () -> Void = {}

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_H), modifiers: UInt32 = UInt32(cmdKey | optionKey)) {
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { hotKey.action() }
            }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x4854_4348), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil
        handler = nil
    }
}

// MARK: - Choosing the anchor

/// Owns whichever anchor is in use and switches between them live.
@MainActor
final class AnchorManager {
    let card: CardPanelController
    private var rail: RailController?
    private var float: FloatController?
    private var notch: NotchWindowController?
    private var notchHover: HoverMonitor?
    private var outsideClickMonitor: Any?
    private let hotKey = HotKey()
    private var escMonitor: Any?
    private let fullscreen = FullscreenWatcher()
    /// With "Menu bar only", the shortcut opens the popover instead.
    var onMenuBarToggle: () -> Void = {}
    /// Native notch alerts use the original wing presenter owned by the app.
    var onNotchActivity: (LiveActivity) -> Void = { _ in }

    init(deps: CardDeps) {
        card = CardPanelController(deps: deps)
        hotKey.action = { [weak self] in self?.toggle() }
        fullscreen.onChange = { [weak self] in self?.applyFullscreen() }
        fullscreen.start()
        // Esc closes a card the shortcut opened.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.dismiss()
                handled = true
            }
            return handled ? nil : event
        }
    }

    var current: HotchPrefs.Anchor = .menuBar

    func apply(_ anchor: HotchPrefs.Anchor) {
        rail?.stop()
        float?.stop()
        notchHover?.stop()
        notch?.stop()
        rail = nil
        float = nil
        notch = nil
        notchHover = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        current = anchor
        switch anchor {
        case .notch:
            let deps = card.deps
            let n = NotchWindowController(store: deps.store, sessionStore: deps.sessionStore,
                                         clipboard: deps.clipboard, focus: deps.focus, model: PanelModel(),
                                         system: deps.system, backpack: deps.backpack)
            n.onOpenSettings = deps.openSettings
            n.actions.signInClaude = deps.signInClaude
            let hover = HoverMonitor()
            n.onExpandedChange = { [weak hover] expanded in hover?.noteExpanded(expanded) }
            hover.hotZones = { [weak n] in
                guard let n else { return nil }
                return (n.hoverZones, n.panelHoverZone)
            }
            hover.onExpand = { [weak n] point in n?.expand(near: point) }
            hover.onCollapse = { [weak n, weak hover] in
                n?.collapse()
                if n?.isExpanded == true { hover?.noteExpanded(true) }
            }
            notch = n
            notchHover = hover
            hover.start()
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let n = self.notch, n.isExpanded,
                          !n.panelHoverZone.contains(NSEvent.mouseLocation),
                          !n.hoverZones.contains(where: { $0.contains(NSEvent.mouseLocation) }) else { return }
                    self.dismiss()
                }
            }
        case .edge:
            let r = RailController(card: card)
            r.start()
            rail = r
        case .pill, .orb:
            let f = FloatController(card: card, style: anchor == .pill ? .pill : .orb)
            f.start()
            float = f
        case .menuBar:
            break
        }
        applyFullscreen()
    }

    /// Steps the anchor aside while an app is full screen on its display.
    private func applyFullscreen() {
        if let rail { rail.stepAside = fullscreen.isFullscreen(rail.screen) }
        if let float { float.stepAside = fullscreen.isFullscreen(float.screen) }
    }

    func applyShortcut(_ enabled: Bool) {
        enabled ? hotKey.register() : hotKey.unregister()
    }

    func refreshPlacement() {
        rail?.refreshPlacement()
        float?.refreshPlacement()
        if let notch {
            notch.invalidateHoverZones()
            let point = notch.geometry.map { CGPoint(x: $0.screenFrame.midX, y: $0.screenFrame.midY) }
            notch.updatePlacement(near: point)
        }
        applyFullscreen()
    }

    func toggle() {
        if let notch {
            if notch.isExpanded { dismiss() }
            else { notch.pinned = true; notch.expand(); notchHover?.noteExpanded(true) }
        } else if let rail { rail.toggle() } else if let float { float.toggle() } else { onMenuBarToggle() }
    }

    func dismiss() {
        rail?.collapse()
        float?.collapse()
        notch?.collapse(force: true)
        notchHover?.noteExpanded(false)
    }

    /// Brings forward the app a session runs in and puts the card away.
    func jump(to session: AgentSession) {
        SessionJump.go(to: session) { [weak self] success in
            if success { self?.dismiss() }
        }
    }

    /// A click on an alert acts on it: a session waiting or finished goes to
    /// its app; anything else opens the part of the card it is about.
    func act(on alert: LiveActivity) {
        let key = alert.key
        if key.hasPrefix("need-") || key.hasPrefix("done-"),
           let id = key.split(separator: "-", maxSplits: 1).last.map(String.init),
           let session = card.deps.sessionStore.sessions.first(where: { $0.id == id }) {
            jump(to: session)
            return
        }
        switch true {
        case key == "mem": open(.mac, detail: .memory)
        case key.hasPrefix("limit-"): open(.ai)
        case key == "thermal": open(.mac)
        case key == "focus": open(.focus)
        case key.hasPrefix("need-"), key.hasPrefix("done-"): open(.agents)
        default: open(.now)
        }
    }

    /// Opens the card on a section, pinned so it waits for the person.
    func open(_ page: PanelPage, detail: SystemDetailKind? = nil) {
        let pages = card.deps.pages
        pages.page = page
        pages.backpackCard = false
        pages.macDetail = detail
        if let notch {
            notch.setPage(page)
            if let detail { notch.setDetail(detail) }
            notch.pinned = true
            notch.expand()
            notch.focusKeyboardIfPinned()
            notchHover?.noteExpanded(true)
        } else if let rail { rail.expand(pinned: true) } else if let float { float.expand(pinned: true) } else { onMenuBarToggle() }
    }

    func present(_ activity: LiveActivity, done: @escaping () -> Void) {
        if notch != nil {
            onNotchActivity(activity)
            done()
        } else if let rail { rail.present(activity, done: done) } else if let float { float.present(activity, done: done) } else { done() }
    }

    var isShown: Bool { card.isShown || notch?.isExpanded == true }
    func changePage(by delta: Int) {
        if let notch { notch.changePage(by: delta) } else { card.deps.pages.change(by: delta) }
    }
    var cardWindow: NSWindow? { notch?.contentWindow ?? (card.isShown ? card.panel : nil) }
    var cardFrame: CGRect? { notch?.isExpanded == true ? notch?.panelFrame : (card.isShown ? card.frame : nil) }
}
