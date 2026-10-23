import AppKit

/// Polls the global mouse location and drives the expand / collapse state
/// machine. NSEvent.mouseLocation needs no accessibility permissions.
///
/// Every screen contributes a hover target, including screens with no physical
/// notch, so the same gesture at the top center of any display opens the panel.
@MainActor
final class HoverMonitor {
    /// Pointer must dwell in the notch this long before the panel opens. Kept
    /// just long enough to reject a pointer sweeping across the notch on its way
    /// to a menu bar item.
    static let expandDelay: TimeInterval = 0.040
    /// Pointer must be outside the notch and the panel this long before it closes.
    ///
    /// This was 0.35s, and it was the single biggest reason dismissing felt slow:
    /// a third of a second of nothing happening *before* any animation started,
    /// which no amount of tuning the fade could have fixed. The hysteresis only
    /// has to cover a pointer clipping a corner while travelling between the notch
    /// and the panel body, and those two zones are contiguous.
    static let collapseDelay: TimeInterval = 0.160
    /// A tick is a handful of rect containment tests against a cached array, so a
    /// faster rate costs almost nothing and buys a direct win: at 0.05 the pointer
    /// could sit in the notch for a full 50ms before anything noticed, and that
    /// was added to every open on top of the dwell.
    static let pollInterval: TimeInterval = 0.020

    /// Carries the pointer location, which decides the screen to open on.
    var onExpand: ((CGPoint) -> Void)?
    var onCollapse: (() -> Void)?

    /// Supplies one hover target per screen plus the panel's live hover zone.
    ///
    /// The panel's zone is the shape on screen, not the window around it. It was
    /// the window frame, and the difference is not academic: nothing is drawn in
    /// the 10pt flare band down either side, so a pointer resting there had left
    /// the panel by eye and was still inside it by arithmetic, and the panel
    /// stayed up until something else moved the mouse.
    var hotZones: (() -> (notches: [CGRect], panel: PanelHoverZone)?)?

    private var timer: Timer?
    private var popoverObserver: NSObjectProtocol?
    private var expanded = false
    private var insideSince: Date?
    private var outsideSince: Date?

    /// Until when the panel is held open with nobody hovering it.
    ///
    /// The first-launch reveal opens the panel without a gesture, and the poll
    /// below would take it away 160ms later — the pointer is wherever the user
    /// left it, which is not the notch. A deadline the collapse path consults is
    /// how that is bought, rather than stretching `collapseDelay`: the
    /// hysteresis is what every dismissal *feels* like, and a one-off
    /// introduction has no business being paid for out of it.
    private var pinnedUntil: Date?

    func start() {
        stop()
        let timer = Timer(timeInterval: HoverMonitor.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // The status item's popover is the same information on a surface the
        // user asked for by clicking, and it opens *under* the hover panel —
        // which floats above the menu bar level a popover gets. So the panel is
        // drawn over it, the pointer travelling to it is inside the panel, and
        // the panel has no reason to ever close: a screenshot of the popover
        // with the panel sitting on top of it is how this was reported.
        //
        // A pulse, not a latch. The panel is dismissed once, here, and normal
        // hover rules take over again immediately — so a missed close
        // notification can never leave the panel unable to open.
        popoverObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceCollapse()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let popoverObserver {
            NotificationCenter.default.removeObserver(popoverObserver)
        }
        popoverObserver = nil
    }

    /// Dismisses the panel without waiting for the pointer, and leaves the state
    /// machine believing what is true: closed, and free to re-open on the next
    /// deliberate hover of the notch.
    func forceCollapse() {
        guard expanded else { return }
        noteExpanded(false)
        onCollapse?()
    }

    /// Lets the status item force the panel state back in sync.
    func noteExpanded(_ value: Bool) {
        expanded = value
        insideSince = nil
        outsideSince = nil
        // A pin only ever describes the opening it was set alongside, so any
        // re-sync retires it — including the popover's forced dismissal, which
        // is a person asking for this panel to go away.
        pinnedUntil = nil
    }

    /// Marks the panel open without a hover having opened it, and refuses to
    /// collapse it for `duration`.
    ///
    /// Both halves are needed. Without the first the monitor believes the panel
    /// is closed, so nothing is watching for the pointer to leave and the panel
    /// has no way back down; without the second the very next poll closes it.
    func pinExpanded(for duration: TimeInterval) {
        noteExpanded(true)
        pinnedUntil = Date().addingTimeInterval(duration)
    }

    private func tick() {
        guard let zones = hotZones?() else { return }
        let point = NSEvent.mouseLocation
        let now = Date()

        if expanded {
            // The forgiveness lives in `collapseDelay`, not in a fattened zone:
            // the pointer may leave the shape for up to 160ms and come back
            // without the panel so much as beginning to close.
            let inside = zones.panel.contains(point) || zones.notches.contains { $0.contains(point) }
            if inside {
                outsideSince = nil
                // A real hover outranks the pin. Once the pointer is on the
                // panel there is an actual gesture to obey, and the ordinary
                // rules answer better than any deadline could: it stays while
                // hovered, and it leaves when the pointer does.
                pinnedUntil = nil
            } else if let pinned = pinnedUntil, now < pinned {
                // Held open on purpose. Nothing accumulates while pinned, so the
                // hysteresis starts from the deadline rather than from the
                // moment the panel opened — the pin ends and the panel then
                // leaves on the same 160ms every other dismissal takes.
                outsideSince = nil
            } else {
                if let since = outsideSince {
                    if now.timeIntervalSince(since) >= HoverMonitor.collapseDelay {
                        expanded = false
                        outsideSince = nil
                        insideSince = nil
                        onCollapse?()
                    }
                } else {
                    outsideSince = now
                }
            }
        } else {
            if zones.notches.contains(where: { $0.contains(point) }) {
                if let since = insideSince {
                    if now.timeIntervalSince(since) >= HoverMonitor.expandDelay {
                        expanded = true
                        insideSince = nil
                        outsideSince = nil
                        onExpand?(point)
                    }
                } else {
                    insideSince = now
                }
            } else {
                insideSince = nil
            }
        }
    }
}
