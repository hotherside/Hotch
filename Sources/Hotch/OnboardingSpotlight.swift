import AppKit
import SwiftUI

/// Shows where Hotch lives once welcome is done. The warm signal from the
/// welcome mark travels to the companion, a soft ring settles around it, and
/// a short note says how to open it. It clears itself once the companion is
/// opened, or on Got It, Esc, or after a while untouched.
@MainActor
final class OnboardingSpotlight {
    /// The companion has been opened, so the point has been made.
    var isOpen: () -> Bool = { false }

    private var ring: NSPanel?
    private var note: SpotlightPanel?
    private var spark: NSPanel?
    private var sparkTimer: Timer?
    private var watch: Timer?
    private var shownAt = Date()
    private var pulseWork: DispatchWorkItem?
    private static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// Long enough to read twice; it stays while the pointer rests on it or
    /// VoiceOver is running.
    private static let linger: TimeInterval = 25

    /// Points at `target` from `origin`, with a note saying how to open it.
    /// Without a target (a menu bar icon macOS has hidden) only the note
    /// shows, under the menu bar on the main display.
    func reveal(target: CGRect?, from origin: CGRect, message: String, shortcut: String?) {
        dismiss(animated: false)
        let land = { [weak self] in
            guard let self else { return }
            if let target { self.showRing(around: target, breathing: true) }
            self.showNote(target: target, message: message, shortcut: shortcut)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(WelcomeCopy.spotlightTitle). \(message)",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        if let target, !origin.isEmpty, !HMotion.reduceMotion {
            fly(from: CGPoint(x: origin.midX, y: origin.midY + origin.height * 0.28),
                to: CGPoint(x: target.midX, y: target.midY), then: land)
        } else {
            land()
        }
    }

    /// A brief ring while placement is being chosen, so the eye finds it.
    func pulse(around target: CGRect) {
        guard note == nil else { return }
        pulseWork?.cancel()
        showRing(around: target, breathing: false)
        let shown = ring
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.fadeOut(shown) { if self?.ring === shown { self?.ring = nil } }
            }
        }
        pulseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func dismiss(animated: Bool = true) {
        watch?.invalidate()
        watch = nil
        sparkTimer?.invalidate()
        sparkTimer = nil
        pulseWork?.cancel()
        spark?.orderOut(nil)
        spark = nil
        let ring = self.ring, note = self.note
        self.ring = nil
        self.note = nil
        if animated {
            fadeOut(ring) {}
            fadeOut(note) {}
        } else {
            ring?.orderOut(nil)
            note?.orderOut(nil)
        }
    }

    // MARK: Pieces

    private func fly(from start: CGPoint, to end: CGPoint, then land: @escaping () -> Void) {
        let side: CGFloat = 22
        let panel = Self.panel(size: CGSize(width: side, height: side), keyable: false)
        panel.ignoresMouseEvents = true
        panel.contentView = Self.host(SparkView())
        panel.setFrame(CGRect(x: start.x - side / 2, y: start.y - side / 2, width: side, height: side), display: false)
        panel.orderFrontRegardless()
        spark = panel
        // A gentle arc, bowed away from the straight line, eased at both ends.
        let distance = hypot(end.x - start.x, end.y - start.y)
        let duration = min(0.95, max(0.55, Double(distance) / 1400))
        let normal = distance > 0 ? CGPoint(x: -(end.y - start.y) / distance, y: (end.x - start.x) / distance) : .zero
        let bow = min(120, distance * 0.18)
        let control = CGPoint(x: (start.x + end.x) / 2 + normal.x * bow, y: (start.y + end.y) / 2 + normal.y * bow)
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let spark = self.spark else { timer.invalidate(); return }
                let raw = min(1, Date().timeIntervalSince(began) / duration)
                let t = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
                let u = 1 - t
                let x = u * u * start.x + 2 * u * t * control.x + t * t * end.x
                let y = u * u * start.y + 2 * u * t * control.y + t * t * end.y
                spark.setFrameOrigin(NSPoint(x: x - side / 2, y: y - side / 2))
                guard raw >= 1 else { return }
                timer.invalidate()
                self.sparkTimer = nil
                land()
                self.fadeOut(spark) { if self.spark === spark { self.spark = nil } }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sparkTimer = timer
    }

    private func showRing(around target: CGRect, breathing: Bool) {
        ring?.orderOut(nil)
        let shape = SpotlightPlacement.ring(around: target)
        let glow: CGFloat = 18
        let panel = Self.panel(size: shape.frame.size, keyable: false)
        panel.ignoresMouseEvents = true
        panel.contentView = Self.host(SpotlightRing(radius: shape.radius, glow: glow, breathing: breathing))
        panel.setFrame(shape.frame.insetBy(dx: -glow, dy: -glow), display: false)
        panel.orderFrontRegardless()
        ring = panel
    }

    private func showNote(target: CGRect?, message: String, shortcut: String?) {
        let pad = SpotlightNote.shadowPad
        let point = target ?? fallbackTarget
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: point.midX, y: point.midY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        // The arrow adds depth across or down, so measure both ways, choose
        // the side, then use the size that matches it.
        func bubble(_ side: SpotlightSide) -> CGSize {
            let size = NSHostingView(rootView: SpotlightNote(message: message, shortcut: shortcut, side: side,
                                                             arrow: 40, onDone: {})).fittingSize
            return CGSize(width: size.width - pad * 2, height: size.height - pad * 2)
        }
        let visible = screen.visibleFrame
        let first = SpotlightPlacement.note(size: bubble(.below), target: point, screen: screen.frame, visible: visible)
        let placed = first.side == .below || first.side == .above ? first
            : SpotlightPlacement.note(size: bubble(first.side), target: point, screen: screen.frame, visible: visible)
        let panel = Self.panel(size: placed.frame.size, keyable: true)
        panel.onCancel = { [weak self] in self?.dismiss() }
        let host = FirstMouseHostingView(rootView: SpotlightNote(
            message: message, shortcut: shortcut, side: placed.side, arrow: target == nil ? -1 : placed.arrow,
            onDone: { [weak self] in self?.dismiss() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(placed.frame.insetBy(dx: -pad, dy: -pad), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HMotion.reduceMotion ? 0.12 : 0.3
            panel.animator().alphaValue = 1
        }
        note = panel
        shownAt = Date()
        startWatching()
    }

    /// Under the menu bar at the right of the main display, where a status
    /// item would be.
    private var fallbackTarget: CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let top = screen?.visibleFrame.maxY ?? frame.maxY - 24
        return CGRect(x: frame.maxX - 140, y: top, width: 24, height: frame.maxY - top)
    }

    private func startWatching() {
        watch?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isOpen() { self.dismiss(); return }
                let resting = self.note.map { $0.frame.contains(NSEvent.mouseLocation) } ?? false
                if resting { self.shownAt = Date() }
                if !NSWorkspace.shared.isVoiceOverEnabled,
                   Date().timeIntervalSince(self.shownAt) > Self.linger {
                    self.dismiss()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func fadeOut(_ window: NSWindow?, then done: @escaping () -> Void) {
        guard let window else { done(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HMotion.reduceMotion ? 0.1 : 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                done()
            }
        })
    }

    /// Hotch sizes these windows itself; the content never resizes them.
    private static func host<V: View>(_ view: V) -> NSView {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        return host
    }

    private static func panel(size: CGSize, keyable: Bool) -> SpotlightPanel {
        let panel = SpotlightPanel(contentRect: CGRect(origin: .zero, size: size),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.keyable = keyable
        panel.isFloatingPanel = true
        panel.level = level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.title = WelcomeCopy.spotlightTitle
        return panel
    }
}

/// Takes the keyboard only for the note, so Return and Esc answer it.
final class SpotlightPanel: NSPanel {
    var keyable = false
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

// MARK: - Views

/// The welcome mark's warm signal, in flight.
struct SparkView: View {
    var body: some View {
        Circle()
            .fill(WelcomeStyle.signal)
            .frame(width: 10, height: 10)
            .shadow(color: WelcomeStyle.signal.opacity(0.9), radius: 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// A soft warm outline that blooms in around the companion, breathing a few
/// times when it marks the final spot.
struct SpotlightRing: View {
    var radius: CGFloat
    var glow: CGFloat
    var breathing: Bool
    /// Drawn already in place, for rendered docs.
    var settled = false
    @State private var shown = false
    @State private var inhale = false

    var body: some View {
        let visible = shown || settled
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(WelcomeStyle.signal, lineWidth: 2.5)
            .shadow(color: WelcomeStyle.signal.opacity(0.75), radius: 9)
            .scaleEffect(visible ? (inhale ? 1.05 : 1) : (HMotion.reduceMotion ? 1 : 1.35))
            .opacity(visible ? 1 : 0)
            .padding(glow)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(HMotion.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.2)) {
                    shown = true
                }
                guard breathing, !HMotion.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatCount(6, autoreverses: true).delay(0.55)) {
                    inhale = true
                }
            }
    }
}

/// "Hotch lives here", with an arrow towards the companion.
struct SpotlightNote: View {
    static let shadowPad: CGFloat = 18
    static let arrowDepth: CGFloat = 8

    var message: String
    var shortcut: String?
    /// Which side of the companion the note sits on.
    var side: SpotlightSide
    /// Where the arrow meets the bubble edge, from its top or leading end.
    /// Negative hides the arrow.
    var arrow: CGFloat
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(WelcomeStyle.signal).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(WelcomeCopy.spotlightTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Got It", action: onDone)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 3)
        }
        .padding(14)
        .frame(width: 268, alignment: .leading)
        .padding(edge, Self.arrowDepth)
        .background(NoteShape(side: side, arrow: arrow, depth: Self.arrowDepth)
            .fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 4))
        .overlay(NoteShape(side: side, arrow: arrow, depth: Self.arrowDepth)
            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
        .padding(Self.shadowPad)
        .accessibilityElement(children: .contain)
    }

    /// The bubble edge that faces the companion, where the arrow is.
    private var edge: Edge.Set {
        switch side {
        case .left: return .trailing
        case .right: return .leading
        case .above: return .bottom
        case .below: return .top
        }
    }
}

/// A rounded bubble with an arrow on the edge facing what it points at.
struct NoteShape: Shape {
    var side: SpotlightSide
    var arrow: CGFloat
    var depth: CGFloat
    var radius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var body = rect
        switch side {
        case .left: body.size.width -= depth
        case .right: body.origin.x += depth; body.size.width -= depth
        case .above: body.size.height -= depth
        case .below: body.origin.y += depth; body.size.height -= depth
        }
        var path = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        guard arrow >= 0 else { return path }
        let half: CGFloat = 8
        var triangle = Path()
        switch side {
        case .left:
            triangle.move(to: CGPoint(x: body.maxX - 1, y: arrow - half))
            triangle.addLine(to: CGPoint(x: rect.maxX, y: arrow))
            triangle.addLine(to: CGPoint(x: body.maxX - 1, y: arrow + half))
        case .right:
            triangle.move(to: CGPoint(x: body.minX + 1, y: arrow - half))
            triangle.addLine(to: CGPoint(x: rect.minX, y: arrow))
            triangle.addLine(to: CGPoint(x: body.minX + 1, y: arrow + half))
        case .above:
            triangle.move(to: CGPoint(x: arrow - half, y: body.maxY - 1))
            triangle.addLine(to: CGPoint(x: arrow, y: rect.maxY))
            triangle.addLine(to: CGPoint(x: arrow + half, y: body.maxY - 1))
        case .below:
            triangle.move(to: CGPoint(x: arrow - half, y: body.minY + 1))
            triangle.addLine(to: CGPoint(x: arrow, y: rect.minY))
            triangle.addLine(to: CGPoint(x: arrow + half, y: body.minY + 1))
        }
        triangle.closeSubpath()
        path.addPath(triangle)
        return path
    }
}
