import AppKit

/// Turns two-finger horizontal scrolls into page turns, on both surfaces.
///
/// The notch panel cannot take the gesture itself: it sets
/// `ignoresMouseEvents = true` and must keep doing so (it spans the menu bar, so
/// a panel that accepted events would swallow clicks for whatever status item
/// sits underneath). Events over it are therefore delivered to whatever window
/// is *below* the pointer — some other app — which is exactly what a global
/// monitor observes. Global monitors for mouse-class events need no
/// accessibility permission, the same bargain as the `NSEvent.mouseLocation`
/// hover poll; only keyboard monitoring is gated.
///
/// The popover is the opposite case: a normal event-accepting window of this
/// app, which a global monitor never sees. So both monitors are installed and
/// route by where the event landed. Nothing is ever swallowed or altered —
/// scrolls are watched, not taken.
@MainActor
final class PageSwipeMonitor {
    /// How much accumulated horizontal travel makes a page turn. High enough
    /// that a diagonal scroll aimed at a page below does not flip pages, low
    /// enough that a deliberate swipe never feels ignored.
    static let threshold: CGFloat = 60
    /// Legacy scroll-wheel events carry no gesture phases, so runs of them are
    /// grouped by time instead.
    static let legacyGap: TimeInterval = 0.3

    /// The panel's visible rect while expanded, nil otherwise. Covers the
    /// strip, where scrolls still land on other apps' windows.
    var panelTarget: (() -> CGRect?)?
    var onPanelSwipe: ((Int) -> Void)?
    /// The panel's interaction window while expanded, nil otherwise. Scrolls
    /// over the content region arrive here as local events.
    var panelContentWindow: (() -> NSWindow?)?
    /// The popover's window while shown, nil otherwise.
    var popoverWindow: (() -> NSWindow?)?
    var onPopoverSwipe: ((Int) -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var accumulated: CGFloat = 0
    /// One page per gesture: without this, a long swipe would rifle through
    /// every page it had momentum for.
    private var firedThisGesture = false
    private var lastLegacyEvent: TimeInterval = 0

    func start() {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event, isLocal: false)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event, isLocal: true)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent, isLocal: Bool) {
        // Where did this land? Local events route by window identity — the
        // settings window also scrolls, and it must not turn pages. Global
        // events route by pointer position over the expanded panel.
        let action: ((Int) -> Void)?
        if isLocal {
            if let content = panelContentWindow?(), event.window === content {
                action = onPanelSwipe
            } else if let popover = popoverWindow?(), event.window === popover {
                action = onPopoverSwipe
            } else {
                return
            }
        } else {
            guard let rect = panelTarget?(), rect.contains(NSEvent.mouseLocation) else {
                return
            }
            action = onPanelSwipe
        }

        // Momentum is the tail of a gesture that already had its chance to fire.
        guard event.momentumPhase.isEmpty else { return }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            accumulated = 0
            firedThisGesture = false
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            accumulated = 0
            firedThisGesture = false
            return
        }

        let isLegacy = event.phase.isEmpty
        if isLegacy {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLegacyEvent > PageSwipeMonitor.legacyGap {
                accumulated = 0
                firedThisGesture = false
            }
            lastLegacyEvent = now
        }

        // A mostly-vertical tick is someone scrolling a page underneath, not a
        // swipe; contribute nothing rather than drifting toward the threshold.
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
        accumulated += event.scrollingDeltaX

        guard !firedThisGesture, abs(accumulated) >= PageSwipeMonitor.threshold else { return }
        // Natural scrolling: fingers moving left produce negative deltas and
        // should reveal the page on the right, which is the next one.
        action?(accumulated < 0 ? 1 : -1)
        firedThisGesture = !isLegacy
        accumulated = 0
    }
}
