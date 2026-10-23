import AppKit
import SwiftUI

// MARK: - Geometry

struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    /// Hover target, global coordinates, bottom left origin. On a screen with
    /// no real notch this is the full menu bar strip, which is a comfortable
    /// hover target even though the panel reserves far less space for it.
    var notchRect: CGRect
    /// Black strip reserved at the top of the panel before content begins.
    /// Matches the notch on real hardware, but stays small on a virtual notch
    /// so the panel is not mostly dead space.
    var contentClearance: CGFloat
    /// Window frame, global coordinates, bottom left origin. Taller than the
    /// visible panel: it overflows above the screen top and leaves room below
    /// for the drop shadow.
    var panelRect: CGRect
    /// Visible height of the panel body, measured down from the screen top.
    var bodyHeight: CGFloat
    var isRealNotch: Bool
}

enum NotchGeometryResolver {
    /// Total extra width beyond the notch, split evenly between the two wings.
    static let wingAllowance: CGFloat = 300
    /// Hotch 2 is 640 wide: room for three provider tiles or six Mac tiles in a
    /// row. On a 14" MacBook Pro that leaves two 227pt wings beside the notch.
    static let minPanelWidth: CGFloat = PanelMetrics.panelWidth
    /// Panel height below the clearance strip, for the default two rows.
    static let contentHeight: CGFloat = contentHeight(forRows: 2)

    /// Content height that fits the given number of provider rows: the rows
    /// themselves, the divider blocks between them, and the vertical padding
    /// around the row stack.
    ///
    /// The paddings are read from the theme rather than summed here as a literal.
    /// They have to leave room for the footer lines, which are overlaid on the
    /// bottom padding, so the two numbers cannot be changed independently — and a
    /// hardcoded 28 here is exactly how they would have been.
    /// Vertical space every page spends outside its rows: the padding above the
    /// stack, and the footer band the content is not allowed to enter.
    static var pageChrome: CGFloat {
        NotchTheme.rowStackTopPadding + NotchTheme.footerBandHeight
    }

    static func contentHeight(forRows rows: Int) -> CGFloat {
        let n = max(1, rows)
        return CGFloat(n) * NotchTheme.rowHeight + CGFloat(n - 1) * 8 + pageChrome
    }

    /// Content height of the sessions page: denser rows, smaller gaps, the same
    /// chrome as the provider rows so the two pages share a bottom line.
    static func sessionsContentHeight(forRows rows: Int) -> CGFloat {
        let n = max(1, rows)
        return CGFloat(n) * NotchTheme.sessionRowHeight
            + CGFloat(n - 1) * NotchTheme.sessionRowGap + pageChrome
    }

    /// Content height of the forecast page. One fixed-height block per provider
    /// with windows laid out side by side, so unlike the first version this does
    /// not grow with how many windows a provider reports.
    static func forecastContentHeight(providers: Int) -> CGFloat {
        let n = max(1, providers)
        return CGFloat(n) * NotchTheme.forecastBlockHeight + CGFloat(n - 1) * 8 + pageChrome
    }

    static func clipboardContentHeight(forRows rows: Int) -> CGFloat {
        let n = max(1, rows)
        return CGFloat(n) * NotchTheme.clipboardRowHeight
            + CGFloat(n - 1) * NotchTheme.clipboardRowGap + pageChrome
    }

    static var focusPageContentHeight: CGFloat {
        NotchTheme.focusContentHeight + pageChrome
    }

    /// **One height, and it does not depend on the data.**
    ///
    /// It was briefly the tallest page's natural height — which meant five live
    /// sessions or six providers set the size of the whole app, and the panel
    /// hung a long way down the screen to hold a list nobody asked to see all
    /// of. A thing that drops out of the bezel has to be small; the number of
    /// Claude sessions running is not a reason for it to be tall.
    ///
    /// So the container is sized for the *home* page at its typical load — two
    /// providers with room to breathe — and every page scrolls inside it.
    /// Deriving it from `contentHeight(forRows:)` rather than writing a literal
    /// keeps it in step with row heights and the footer band.
    static let baselineRows = 2
    static var standardContentHeight: CGFloat {
        PanelMetrics.maxBelowStrip
    }
    /// Clearance reserved on a screen with no physical notch.
    static let virtualClearance: CGFloat = 12
    static let virtualNotchWidth: CGFloat = 220
    static let fallbackNotchWidth: CGFloat = 200
    /// How far the panel body extends above the top of the screen.
    static let topOverflow: CGFloat = 2
    /// Room below the body so the drop shadow is not clipped.
    /// Zero: the shadow is drawn by the window server (panel.hasShadow), which
    /// contours to the opaque shape. In-view shadows clip at the window edge.
    static let shadowAllowance: CGFloat = 0

    static func panelWidth(forNotchWidth width: CGFloat) -> CGFloat {
        max(width + wingAllowance, minPanelWidth)
    }

    static func panelHeight(forClearance clearance: CGFloat, rows: Int = 2) -> CGFloat {
        clearance + contentHeight(forRows: rows)
    }

    /// One geometry per attached screen, so the panel is reachable wherever the
    /// pointer happens to be.
    ///
    /// This used to return a single geometry and prefer whichever screen
    /// reported a notch, which meant that on a MacBook Pro driving an external
    /// display the external display had no hover target at all — and on a Mac
    /// with no notch anywhere the panel was pinned to the main screen. A screen
    /// without a notch gets a virtual zone in the same place the notch would be,
    /// so the gesture is identical on every display.
    static func geometries(rowCount: Int = 2) -> [NotchGeometry] {
        NSScreen.screens.map { geometry(for: $0, rowCount: rowCount) }
    }

    static func geometry(for screen: NSScreen, rowCount: Int = 2) -> NotchGeometry {
        geometry(for: screen, contentHeight: contentHeight(forRows: rowCount))
    }

    /// The paged panel sizes its window to the tallest page, which is a content
    /// height, not a row count — hence this variant. The rowCount forms above
    /// stay for callers that only ever mean provider rows.
    static func geometry(for screen: NSScreen, contentHeight: CGFloat) -> NotchGeometry {
        let frame = screen.frame

        if screen.safeAreaInsets.top > 0 {
            var width = fallbackNotchWidth
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let candidate = frame.width - left.width - right.width
                if candidate > 40 { width = candidate }
            }
            let height = max(20, screen.safeAreaInsets.top)
            let notch = CGRect(x: frame.midX - width / 2,
                               y: frame.maxY - height,
                               width: width,
                               height: height)
            // On real hardware the reserved strip is exactly the notch, so the
            // panel top and the bezel are the same shape.
            return assemble(screenFrame: frame, notch: notch, clearance: height,
                            contentHeight: contentHeight, isReal: true)
        }

        // No notch on this screen: put a virtual hover zone where one would be.
        // visibleFrame is inset by anything docked at the top, so fall back to a
        // plain menu bar height when the two frames agree.
        let rawMenuBar = frame.maxY - screen.visibleFrame.maxY
        let height = min(40, max(24, rawMenuBar))
        let notch = CGRect(x: frame.midX - virtualNotchWidth / 2,
                           y: frame.maxY - height,
                           width: virtualNotchWidth,
                           height: height)
        // There is no bezel to match here, so reserve only a token strip and
        // give the space back to the content.
        return assemble(screenFrame: frame, notch: notch, clearance: virtualClearance,
                        contentHeight: contentHeight, isReal: false)
    }

    /// Where the settings button goes: the panel's trailing bottom corner, centred
    /// on the footer line, on the same visible margin as everything else.
    ///
    /// Global coordinates with a bottom-left origin, like every other rect here.
    /// It clears the bottom corner fillet comfortably — at `contentInset` in from
    /// the side the corner arc has already met the bottom edge — so the button sits
    /// on opaque body rather than half over the curve.
    /// Frame for the interaction window: the panel below the menu bar strip.
    ///
    /// The strip must keep ignoring the mouse (it spans the menu bar, where a
    /// click belongs to whatever status item sits beneath); everything below it
    /// covers desktop rather than menu bar, and a panel that is visually in
    /// front should receive the clicks aimed at it. The split is what lets the
    /// pages hold real buttons.
    static func contentRect(for geometry: NotchGeometry) -> CGRect {
        let panel = geometry.panelRect
        let height = geometry.bodyHeight - geometry.contentClearance
        return CGRect(x: panel.minX,
                      y: panel.minY + shadowAllowance,
                      width: panel.width,
                      height: max(1, height))
    }

    /// Geometry for the screen containing `point`, or the default screen when the
    /// point is off every screen.
    static func geometry(containing point: CGPoint?, rowCount: Int = 2) -> NotchGeometry? {
        geometry(containing: point, contentHeight: contentHeight(forRows: rowCount))
    }

    static func geometry(containing point: CGPoint?, contentHeight: CGFloat) -> NotchGeometry? {
        if let point, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return geometry(for: screen, contentHeight: contentHeight)
        }
        return resolve(contentHeight: contentHeight)
    }

    /// The screen the panel uses when nothing better is known: a real notch if
    /// one exists, otherwise the main screen.
    static func resolve(rowCount: Int = 2) -> NotchGeometry? {
        resolve(contentHeight: contentHeight(forRows: rowCount))
    }

    static func resolve(contentHeight: CGFloat) -> NotchGeometry? {
        let screens = NSScreen.screens
        let preferred = screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? screens.first
        guard let preferred else { return nil }
        return geometry(for: preferred, contentHeight: contentHeight)
    }

    private static func assemble(screenFrame: CGRect,
                                 notch: CGRect,
                                 clearance: CGFloat,
                                 contentHeight: CGFloat,
                                 isReal: Bool) -> NotchGeometry {
        let width = panelWidth(forNotchWidth: notch.width)
        let body = clearance + contentHeight

        // Window top sits topOverflow above the screen edge so the flare never
        // exposes a hairline of wallpaper, and the bottom carries shadow room.
        let windowHeight = topOverflow + body + shadowAllowance
        let panel = CGRect(x: screenFrame.midX - width / 2,
                           y: screenFrame.maxY + topOverflow - windowHeight,
                           width: width,
                           height: windowHeight)

        return NotchGeometry(screenFrame: screenFrame,
                             notchRect: notch,
                             contentClearance: clearance,
                             panelRect: panel,
                             bodyHeight: body,
                             isRealNotch: isReal)
    }
}

// MARK: - Hover target

/// The panel's hover target: the shape that is actually **drawn**, in global
/// coordinates with a bottom left origin.
///
/// Not the window frame, which is the bug this type exists to close. The window
/// is a plain rectangle; the panel inside it is not. The body's sides sit
/// `NotchTheme.topFlare` inside the frame — that gap *is* the concave corner
/// flare — and the bottom corners carry a 24pt radius. Testing the frame meant
/// those regions counted as "the pointer is still on the panel", so the pointer
/// could leave the visible panel without the hover monitor ever seeing it leave
/// and the panel stayed on screen indefinitely. Measured on a 14" MacBook Pro
/// (500 x 190 window): a 10pt band down each side for the full body height, plus
/// roughly 7pt into each bottom corner.
///
/// The outline is the same `NotchPanelShape` the chrome view fills, built from
/// the same rect, so the shape that is tested and the shape that is drawn cannot
/// drift apart — which is exactly how they drifted apart in the first place.
struct PanelHoverZone {
    /// Bounding box of the drawn shape. Never the window frame: shadow room
    /// below the body, if any is ever reserved again, is not part of the panel.
    var frame: CGRect = .zero
    /// The outline in the shape's own space, which runs top left down the way
    /// SwiftUI draws it.
    var outline: Path?

    func contains(_ point: CGPoint) -> Bool {
        guard frame.contains(point) else { return false }
        guard let outline else { return true }
        return outline.contains(CGPoint(x: point.x - frame.minX,
                                        y: frame.maxY - point.y))
    }
}

// MARK: - Panel

final class NotchPanel: NSPanel {
    /// Whether this panel may take the keyboard.
    ///
    /// Off for the display window, always: it spans the menu bar and must stay
    /// inert. Off for the interaction window too, *except* while the focus page
    /// is showing — that page has a "what are you working on?" field, and a
    /// borderless panel cannot put a caret in it without becoming key.
    ///
    /// Gated rather than simply switched on because a key window receives every
    /// keystroke on the machine. AppKit only makes a window key when it is
    /// clicked, so the gate is belt and braces — but the belt is cheap, and the
    /// failure it prevents (the notch quietly eating what you type into your
    /// editor) is the kind of thing that would get the app deleted.
    var keyable = false

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// Hosting view for the interaction window. The one AppKit override that makes
/// SwiftUI buttons work in a non-activating panel: without it, the click that
/// should press a button is spent asking to activate an app that never
/// activates, and every control needs clicking twice.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Told whenever the SwiftUI content's natural size changes, so a window
    /// that Hotch sizes itself can follow it. Needs `.intrinsicContentSize` in
    /// `sizingOptions` (and only that, or the window resizes itself).
    var onIntrinsicSizeChange: ((CGSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard let onIntrinsicSizeChange else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onIntrinsicSizeChange(self.intrinsicContentSize)
        }
    }

    /// Takes key status on a real click, which is what a caret needs and
    /// `acceptsFirstMouse` does not provide.
    ///
    /// The two are different problems. A button works on the first click
    /// because the click itself is the whole interaction — it is delivered,
    /// pressed, done. A text field needs the *window* to be key before it can
    /// show a caret or receive a keystroke, and a borderless non-activating
    /// panel belonging to an accessory app does not reliably take key status
    /// from the click that lands in the field. The symptom was precise and
    /// misleading: the task field ignored clicks, pills and the gear worked
    /// fine, and after clicking around for a while the field started working —
    /// those other clicks were what eventually made the panel key.
    ///
    /// This stays inside the gate that already exists rather than widening it.
    /// `keyable` is only true while the focus page is showing, so the panel
    /// still cannot take the keyboard on any other page, and it takes it here
    /// only in response to a click someone actually made — never merely because
    /// a page with a text field on it came into view. The failure that gate
    /// exists to prevent, the notch quietly eating what you type into your
    /// editor, needs an unprompted key grab; this is the opposite of one.
    override func mouseDown(with event: NSEvent) {
        if let panel = window as? NotchPanel, panel.keyable, !panel.isKeyWindow {
            panel.makeKey()
        }
        super.mouseDown(with: event)
    }
}

@MainActor
final class NotchWindowController {
    private(set) var geometry: NotchGeometry?
    private let panel: NotchPanel
    private let hostingView: NSHostingView<NotchChromeRootView>
    /// The interaction window: everything below the menu bar strip, accepting
    /// clicks. Its frame follows the **visible** section, so the invisible
    /// part of a tall window below a short section never swallows a click.
    private let contentPanel: NotchPanel
    private let contentHostingView: FirstMouseHostingView<NotchPagesRootView>
    private let model: PanelModel
    private let store: UsageStore
    private let sessionStore: SessionStore
    private let clipboard: ClipboardStore
    private let focus: FocusStore
    private let system: SystemMonitor
    private let backpack: BackpackManager
    let actions = PanelActions()
    private var collapseWorkItem: DispatchWorkItem?
    private var editingTimeout: DispatchWorkItem?
    private var revealTimeout: DispatchWorkItem?
    private var shrinkWorkItem: DispatchWorkItem?
    private var cachedHoverZones: [CGRect]?
    private var hoverZone = PanelHoverZone()

    private static let editingGrace: TimeInterval = 20
    /// How long the section spring takes, for deferring a shrink of the hit
    /// area until the shape has actually finished shrinking.
    private static let sectionSettle: TimeInterval = 0.38

    var onOpenSettings: (() -> Void)? {
        get { actions.openSettings }
        set { actions.openSettings = newValue ?? {} }
    }

    var contentWindow: NSWindow? {
        model.expanded ? contentPanel : nil
    }

    init(store: UsageStore,
         sessionStore: SessionStore,
         clipboard: ClipboardStore,
         focus: FocusStore,
         model: PanelModel,
         system: SystemMonitor,
         backpack: BackpackManager) {
        self.model = model
        self.store = store
        self.sessionStore = sessionStore
        self.clipboard = clipboard
        self.focus = focus
        self.system = system
        self.backpack = backpack

        let nominal = CGRect(x: 0, y: 0,
                             width: NotchGeometryResolver.minPanelWidth,
                             height: NotchGeometryResolver.topOverflow
                                 + NotchGeometryResolver.virtualClearance
                                 + NotchGeometryResolver.standardContentHeight
                                 + NotchGeometryResolver.shadowAllowance)
        panel = NotchPanel(contentRect: nominal,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        hostingView = NSHostingView(rootView: NotchChromeRootView(store: store,
                                                                  sessionStore: sessionStore,
                                                                  focus: focus,
                                                                  model: model,
                                                                  system: system,
                                                                  backpack: backpack))
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        contentPanel = NotchPanel(contentRect: nominal,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: false)
        contentPanel.isFloatingPanel = true
        contentPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        contentPanel.backgroundColor = .clear
        contentPanel.isOpaque = false
        contentPanel.hasShadow = false
        contentPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentPanel.hidesOnDeactivate = false
        contentPanel.appearance = NSAppearance(named: .darkAqua)
        contentPanel.ignoresMouseEvents = false
        contentPanel.isMovable = false
        contentPanel.isReleasedWhenClosed = false
        contentPanel.animationBehavior = .none

        contentHostingView = FirstMouseHostingView(rootView: NotchPagesRootView(store: store,
                                                                                sessionStore: sessionStore,
                                                                                clipboard: clipboard,
                                                                                focus: focus,
                                                                                model: model,
                                                                                actions: actions,
                                                                                system: system,
                                                                                backpack: backpack))
        contentHostingView.autoresizingMask = []
        contentHostingView.clipsToBounds = true
        contentPanel.contentView = contentHostingView

        updatePlacement()

        actions.setEditing = { [weak self] editing in
            guard let self else { return }
            self.model.editingTask = editing
            if !editing { self.finishEditing() }
        }
        actions.setPage = { [weak self] page in self?.setPage(page) }
        actions.setDetail = { [weak self] kind in self?.setDetail(kind) }
        actions.toggleBackpackCard = { [weak self] in self?.toggleBackpackCard() }
    }

    private func finishEditing() {
        editingTimeout?.cancel()
        editingTimeout = nil
        guard model.expanded else { return }
        let point = NSEvent.mouseLocation
        let inside = hoverZone.contains(point) || hoverZones.contains { $0.contains(point) }
        if !inside { collapse() }
    }

    /// Places the windows on the screen containing `point`.
    ///
    /// Both windows are sized for the **tallest** section, once; the shape
    /// inside is as tall as the current section. The interaction window and the
    /// hover zone follow the visible shape rather than the window, through
    /// `applySectionGeometry`.
    @discardableResult
    func updatePlacement(near point: CGPoint? = nil) -> NotchGeometry? {
        guard let geometry = NotchGeometryResolver.geometry(
            containing: point,
            contentHeight: NotchGeometryResolver.standardContentHeight) else { return nil }
        self.geometry = geometry

        model.apply(geometry)
        panel.setFrame(geometry.panelRect, display: false)
        hostingView.frame = CGRect(origin: .zero, size: geometry.panelRect.size)
        applySectionGeometry(deferShrink: false)
        return geometry
    }

    /// Fits the click area and the hover zone to the section now showing.
    ///
    /// Growing is applied at once, so the incoming content is clickable as soon
    /// as it is drawn. Shrinking waits for the shape to finish shrinking:
    /// pulled in early, the pointer could find itself "outside" a panel that is
    /// still visibly under it, and the panel would close on a tab change.
    private func applySectionGeometry(deferShrink: Bool) {
        guard let geometry else { return }
        let window = geometry.panelRect
        let visibleBody = model.visibleBodyHeight
        let belowStrip = max(1, visibleBody - geometry.contentClearance)
        let current = contentPanel.frame.height

        let apply = { [weak self] in
            guard let self else { return }
            let rect = CGRect(x: window.minX,
                              y: window.maxY - NotchGeometryResolver.topOverflow - visibleBody,
                              width: window.width,
                              height: belowStrip)
            self.contentPanel.setFrame(rect, display: false)
            let flare = NotchTheme.topFlare
            self.contentHostingView.frame = CGRect(x: flare, y: 0,
                                                   width: max(0, rect.width - flare * 2),
                                                   height: rect.height)
            self.hoverZone = NotchWindowController.makeHoverZone(window: window, visibleBody: visibleBody)
        }

        shrinkWorkItem?.cancel()
        shrinkWorkItem = nil
        if deferShrink && belowStrip < current - 0.5 && model.expanded {
            let work = DispatchWorkItem {
                MainActor.assumeIsolated { apply() }
            }
            shrinkWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchWindowController.sectionSettle, execute: work)
        } else {
            apply()
        }

        // The window server draws the shaped shadow from the opaque pixels;
        // recompute once the shape has settled at its new height.
        if model.expanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + NotchWindowController.sectionSettle + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.expanded else { return }
                    self.panel.invalidateShadow()
                }
            }
        }
    }

    // MARK: Sections

    /// Swipe delta from the scroll monitor: +1 for the next section, -1 back.
    func changePage(by delta: Int) {
        guard model.expanded else { return }
        guard let target = PanelPage(rawValue: model.page.rawValue + delta) else { return }
        setPage(target)
    }

    func setPage(_ page: PanelPage) {
        guard page != model.page || model.backpackCard || model.macDetail != nil else { return }
        if model.page == .focus && page != .focus { model.editingTask = false }
        Haptics.tap()
        withAnimation(HMotion.section) {
            model.page = page
            model.macDetail = nil
            model.backpackCard = false
        }
        syncKeyability()
        syncSystemDemand()
        applySectionGeometry(deferShrink: true)
    }

    func setDetail(_ kind: SystemDetailKind?) {
        if model.page != .mac {
            setPage(.mac)
        }
        Haptics.tap()
        withAnimation(HMotion.detail) {
            model.macDetail = kind
        }
        syncSystemDemand()
    }

    func toggleBackpackCard() {
        Haptics.tap()
        withAnimation(HMotion.section) {
            model.backpackCard.toggle()
        }
        applySectionGeometry(deferShrink: true)
    }

    private func syncKeyability() {
        contentPanel.keyable = model.expanded && model.page == .focus && !model.backpackCard
        if !contentPanel.keyable && contentPanel.isKeyWindow {
            contentPanel.resignKey()
        }
    }

    /// The sampler runs at panel rate only while something on screen shows it.
    private func syncSystemDemand() {
        guard model.expanded else {
            system.setDemand(.idle, for: "panel")
            return
        }
        system.setDemand(.panel, for: "panel")
    }

    var hoverZones: [CGRect] {
        if let cachedHoverZones { return cachedHoverZones }
        let zones = NotchGeometryResolver.geometries().map(\.notchRect)
        cachedHoverZones = zones
        return zones
    }

    func invalidateHoverZones() {
        cachedHoverZones = nil
    }

    var panelHoverZone: PanelHoverZone { hoverZone }

    /// The drawn shape's place on screen at the current section's height.
    private static func makeHoverZone(window: CGRect, visibleBody: CGFloat) -> PanelHoverZone {
        let height = NotchGeometryResolver.topOverflow + visibleBody
        let frame = CGRect(x: window.minX,
                           y: window.maxY - height,
                           width: window.width,
                           height: height)
        return PanelHoverZone(
            frame: frame,
            outline: NotchPanelShape().path(in: CGRect(origin: .zero, size: frame.size))
        )
    }

    var panelFrame: CGRect { panel.frame }

    var isExpanded: Bool { model.expanded }

    func expand(near point: CGPoint? = nil) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        editingTimeout?.cancel()
        editingTimeout = nil
        guard !model.expanded else { return }
        updatePlacement(near: point)
        panel.orderFrontRegardless()
        contentPanel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.model.expanded = true
                self?.syncKeyability()
                self?.syncSystemDemand()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMotion.shadowSettle) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.expanded else { return }
                self.panel.invalidateShadow()
            }
        }
    }

    func reveal(pinnedFor pin: TimeInterval) {
        setPage(.now)
        expand()
        model.revealHint = (geometry?.isRealNotch ?? false)
            ? "Hotch lives here \u{2014} hover the notch anytime"
            : "Hotch lives up here \u{2014} hover the menu bar anytime"

        revealTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.endReveal()
            }
        }
        revealTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pin + HoverMonitor.collapseDelay,
                                      execute: work)
    }

    private func endReveal() {
        revealTimeout?.cancel()
        revealTimeout = nil
        model.revealHint = nil
    }

    func collapse() {
        guard model.expanded else { return }
        if model.editingTask && contentPanel.isKeyWindow {
            holdOpenForEditing()
            return
        }
        model.expanded = false
        contentPanel.keyable = false
        syncSystemDemand()
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endReveal()
                guard !self.model.expanded else { return }
                self.panel.orderOut(nil)
                self.contentPanel.orderOut(nil)
                // A tile left open is a detour, not a place to come back to:
                // the next hover opens on the section, not on the detail.
                self.model.macDetail = nil
                self.model.backpackCard = false
                self.applySectionGeometry(deferShrink: false)
            }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelMotion.teardownDelay, execute: work)
    }

    private func holdOpenForEditing() {
        guard editingTimeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editingTimeout = nil
                guard self.model.expanded else { return }
                self.model.editingTask = false
                self.collapse()
            }
        }
        editingTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchWindowController.editingGrace,
                                      execute: work)
    }
}

/// A light tick on the trackpad when a section changes, where the hardware
/// supports it. The same feedback macOS gives when something snaps into place.
enum Haptics {
    @MainActor
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
