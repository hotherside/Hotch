import AppKit
import SwiftUI

/// `Hotch --check-welcome --snapshot-welcome <dir>` renders the welcome as it
/// is drawn, in real windows so the AppKit controls draw as themselves: the
/// greeting frame by frame, the letter and setup in light and dark, the
/// letter as a copy run from the disk image sees it, and the note that points
/// at the companion. Scratch defaults only; the user's own are untouched.
@MainActor
enum WelcomeSnapshot {
    static let framesPerSecond = 30.0
    /// The greeting, then a short rest on the finished letter.
    static let frameSpan = WelcomeTimeline.duration + 0.5

    static func run(directory: String) {
        if CommandLine.arguments.contains("--live-spotlight") {
            runLiveSpotlight()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "com.hojaejung.hotch.snapshot"
        let scratch = UserDefaults(suiteName: suite) ?? .standard
        scratch.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: scratch)
        let prefs = HotchPrefs(defaults: scratch)
        let ready: Set<String> = ["claude", "codex"]
        settings.seedEnabled(ready)
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let frames = root.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        let window = OnboardingWindowController.makeWindow(SnapshotWindow.self, delegate: nil)
        window.setContentSize(CGSize(width: WelcomeStyle.width, height: 580))
        // Invisible: the render reads the views, not the screen. A command
        // line process is never the active app, so the default button draws
        // in its inactive grey here; on screen it takes the accent colour.
        window.alphaValue = 0
        window.orderFrontRegardless()

        func view(_ phase: OnboardingView.Phase, at time: TimeInterval = WelcomeTimeline.duration,
                  installed: Bool = true) -> OnboardingView {
            OnboardingView(settings: settings, prefs: prefs, installed: installed,
                           initialPhase: phase, frozenAt: time, readyOverride: ready)
        }

        func capture(_ content: OnboardingView, dark: Bool) -> NSBitmapImageRep? {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // A new host per phase so @State starts where the render asks.
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            let frame = host.superview ?? host
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            return rep
        }

        for dark in [false, true] {
            let tone = dark ? "dark" : "light"
            write(capture(view(.letter), dark: dark), dark: dark, to: root.appendingPathComponent("welcome-letter-\(tone).png"))
            write(capture(view(.setup), dark: dark), dark: dark, to: root.appendingPathComponent("welcome-setup-\(tone).png"))
            write(spotlightScene(dark: dark), dark: dark, framed: false,
                  to: root.appendingPathComponent("welcome-spotlight-\(tone).png"))
        }
        write(capture(view(.letter, installed: false), dark: false), dark: false,
              to: root.appendingPathComponent("welcome-not-installed-light.png"))

        let count = Int((frameSpan * framesPerSecond).rounded())
        for index in 0...count {
            let time = Double(index) / framesPerSecond
            write(capture(view(.letter, at: time), dark: false), dark: false,
                  to: frames.appendingPathComponent(String(format: "letter-%04d.png", index)), quiet: true)
        }
        write(capture(view(.setup), dark: false), dark: false, to: frames.appendingPathComponent("setup.png"), quiet: true)
        print("\(count + 1) greeting frames written to \(frames.path)")
    }

    /// Drawn as the front window, so the default button and the close button
    /// look as they do on screen.
    final class SnapshotWindow: WelcomeWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    /// The real panels on screen for a few seconds, pointing at where a
    /// default right-edge tab rests, so a screen recording can check the
    /// flight, the ring and the note as they really draw.
    private static func runLiveSpotlight() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let prefs = HotchPrefs(defaults: UserDefaults(suiteName: "com.hojaejung.hotch.snapshot") ?? .standard)
        let centre = visible.maxY - CGFloat(prefs.edgeOffset) * visible.height
        let tab = CGRect(x: screen.frame.maxX - RailGeometry.width, y: centre - RailGeometry.height / 2,
                         width: RailGeometry.width, height: RailGeometry.height)
        let origin = CGRect(x: visible.midX - WelcomeStyle.width / 2, y: visible.midY - 290,
                            width: WelcomeStyle.width, height: 580)
        let spotlight = OnboardingSpotlight()
        print("spotlight target \(tab) from \(origin)")
        spotlight.reveal(target: tab, from: origin,
                         message: WelcomeCopy.whereItLives(.edge, side: .right, realNotch: false),
                         shortcut: WelcomeCopy.shortcutHint)
        RunLoop.current.run(until: Date().addingTimeInterval(4.5))
        spotlight.dismiss()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: The note, beside a stand-in edge tab

    private static func spotlightScene(dark: Bool) -> NSBitmapImageRep? {
        let size = CGSize(width: 720, height: 400)
        let tab = CGRect(x: size.width - RailGeometry.width, y: (size.height - RailGeometry.height) / 2,
                         width: RailGeometry.width, height: RailGeometry.height)
        let message = WelcomeCopy.whereItLives(.edge, side: .right, realNotch: false)
        let probe = NSHostingView(rootView: SpotlightNote(message: message, shortcut: WelcomeCopy.shortcutHint,
                                                          side: .left, arrow: 40, onDone: {})).fittingSize
        let pad = SpotlightNote.shadowPad
        let bubble = CGSize(width: probe.width - pad * 2, height: probe.height - pad * 2)
        // The placement works bottom-up, like the screen; the view is top-down.
        let flipped = CGRect(x: tab.minX, y: size.height - tab.maxY, width: tab.width, height: tab.height)
        let bounds = CGRect(origin: .zero, size: size)
        let placed = SpotlightPlacement.note(size: bubble, target: flipped, screen: bounds, visible: bounds)
        let ring = SpotlightPlacement.ring(around: tab)
        let scene = ZStack(alignment: .topLeading) {
            backdrop(dark: dark)
            EdgeTabShape(right: true, taper: RailGeometry.taper)
                .fill(Color.black.opacity(0.9))
                .overlay(VStack(spacing: 18) {
                    ForEach(0..<3) { index in
                        Circle()
                            .trim(from: 0, to: [0.62, 0.35, 0.8][index])
                            .stroke([HP.cpu, WelcomeStyle.signal, HP.ok][index], lineWidth: 2.5)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 22, height: 22)
                    }
                }.offset(x: 2))
                .frame(width: tab.width, height: tab.height)
                .offset(x: tab.minX, y: tab.minY)
            SpotlightRing(radius: ring.radius, glow: 18, breathing: false, settled: true)
                .frame(width: ring.frame.width + 36, height: ring.frame.height + 36)
                .offset(x: ring.frame.minX - 18, y: ring.frame.minY - 18)
            SpotlightNote(message: message, shortcut: WelcomeCopy.shortcutHint, side: placed.side,
                          arrow: placed.arrow, onDone: {})
                .fixedSize()
                .offset(x: placed.frame.minX - pad, y: size.height - placed.frame.maxY - pad)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, dark ? .dark : .light)

        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: scene)
        host.sizingOptions = []
        host.frame = bounds
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return rep
    }

    private static func backdrop(dark: Bool) -> LinearGradient {
        LinearGradient(colors: dark
                       ? [Color(red: 0.11, green: 0.12, blue: 0.16), Color(red: 0.19, green: 0.15, blue: 0.19)]
                       : [Color(red: 0.84, green: 0.88, blue: 0.93), Color(red: 0.96, green: 0.91, blue: 0.87)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: Writing

    /// The window on a calm backdrop, with its rounded corners and shadow, so
    /// the image reads like the screen does.
    private static func write(_ rep: NSBitmapImageRep?, dark: Bool, framed: Bool = true, to url: URL, quiet: Bool = false) {
        guard let rep else { print("FAIL  could not render \(url.lastPathComponent)"); return }
        var output = rep
        if framed {
            let pad: CGFloat = 56
            let scale = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 2
            let canvas = CGSize(width: rep.size.width + pad * 2, height: rep.size.height + pad * 2)
            guard let framedRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale),
                                                   pixelsHigh: Int(canvas.height * scale), bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return }
            // Points, not pixels, before the context is made from it.
            framedRep.size = canvas
            guard let context = NSGraphicsContext(bitmapImageRep: framedRep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let top = dark ? NSColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1)
                : NSColor(red: 0.84, green: 0.88, blue: 0.93, alpha: 1)
            let bottom = dark ? NSColor(red: 0.19, green: 0.15, blue: 0.19, alpha: 1)
                : NSColor(red: 0.96, green: 0.91, blue: 0.87, alpha: 1)
            NSGradient(starting: bottom, ending: top)?.draw(in: CGRect(origin: .zero, size: canvas), angle: 90)
            let rect = CGRect(x: pad, y: pad, width: rep.size.width, height: rep.size.height)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
            shadow.shadowBlurRadius = 34
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor.white).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            rep.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.10).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            output = framedRep
        }
        guard let png = output.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        if !quiet { print("written to \(url.path)") }
    }
}
