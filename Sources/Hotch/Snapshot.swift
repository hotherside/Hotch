import AppKit
import SwiftUI

/// Renders the expanded panel straight to a PNG without touching the screen.
/// Used to verify the UI where screen capture is unavailable.
///
/// Two modes share the whole render path and differ only in their data:
/// `--snapshot` uses real local providers (no Keychain, no network) and
/// `--snapshot-demo` uses mocked rich data so every chart state is visible.
enum Snapshot {
    /// Margin of simulated desktop around the panel. It sits inside the same
    /// hosting view, so the glass and material actually sample it.
    static let margin: CGFloat = 26

    // MARK: - Entry points

    /// Stand-in notch hardware for `--snapshot-notch`, measured off a 14"
    /// MacBook Pro (`--diag` reports `185x32`).
    ///
    /// Worth a mode of its own: every other render resolves a *virtual* notch,
    /// whose 12pt strip is below `wingMinimumHeight`, so nothing in the normal
    /// verification set draws the wings at all. The one part of the panel that
    /// only exists on real hardware would otherwise be the one part never
    /// checked before shipping.
    static let sampleNotchWidth: CGFloat = 185
    static let sampleNotchClearance: CGFloat = 32

    @MainActor
    /// `focusIdle` renders the focus page's *start row* rather than a running
    /// timer. The popover mode has had it since the focus page shipped; the
    /// panel mode had not, which meant the panel's hand-rolled Start button —
    /// the one control on that page that AppKit does not style — could not be
    /// rendered at all. Its disabled state was invisible for exactly that long.
    static func runBlockingAndExit(demo: Bool,
                                   path: String,
                                   page: PanelPage = .now,
                                   detail: SystemDetailKind? = nil,
                                   backpackCard: Bool = false,
                                   realNotch: Bool = false,
                                   focusIdle: Bool = false,
                                   clearBackground: Bool = false) -> Never {
        _ = NSApplication.shared

        // Demo mode never fetches — the usages below are injected — but the
        // store is still built from the full catalog so a render exercises the
        // same construction the live app does.
        let store = UsageStore(providers: demo ? [
            ClaudeProvider(allowRemote: false),
            CodexProvider(allowRemote: false),
            GrokProvider(),
            KimiProvider(),
            DeepSeekProvider(),
        ] : [
            ClaudeProvider(allowRemote: false),
            CodexProvider(allowRemote: false),
        ])

        let sessionStore = SessionStore()
        let clipboard = ClipboardStore()
        // Injected in demo mode, so it must not be able to write; the live mode
        // renders the real log and only ever reads it.
        let focus = FocusStore(persists: !demo)
        let history: UsageHistoryStore

        if demo {
            store.usages = demoUsages()
            store.lastRefresh = Date().addingTimeInterval(-32)
            sessionStore.sessions = demoSessions()
            sessionStore.lastScan = Date().addingTimeInterval(-4)
            clipboard.items = demoClipboardItems()
            seedDemoFocus(into: focus, idle: focusIdle)
            // A throwaway store: the fixture must never leak into the real
            // history file, and the real history must not leak into the render.
            history = UsageHistoryStore(persists: false)
            seedDemoHistory(into: history)
        } else {
            history = .shared
            var finished = false
            Task { @MainActor in
                await store.refresh()
                finished = true
            }
            while !finished {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            // Same local scan the live app runs; there is no network in it.
            sessionStore.sessions = SessionScanner.scan()
            sessionStore.lastScan = Date()
        }

        let system = SystemMonitor.shared
        if demo {
            system.applyDemo(SystemDemo.make())
            applyDemoFixture(store: store, sessions: sessionStore, clipboard: clipboard, focus: focus, system: system)
        } else {
            system.setDemand(.panel, for: "snapshot")
            let until = Date().addingTimeInterval(3.2)
            while Date() < until {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }
        let backpack = BackpackManager.shared

        let model = PanelModel()
        model.mounted = true
        model.expanded = true
        model.page = page
        model.macDetail = detail
        model.backpackCard = backpackCard
        // The same fixed height the live window uses, so a render of a long page
        // shows what the real panel shows: the top of a list that scrolls,
        // rather than the whole list in a panel stretched to fit it.
        if realNotch {
            model.contentClearance = sampleNotchClearance
            model.notchWidth = sampleNotchWidth
            model.notchHeight = sampleNotchClearance
        }
        model.panelWidth = NotchGeometryResolver.minPanelWidth
        model.panelHeight = model.contentClearance
            + NotchGeometryResolver.standardContentHeight

        guard let png = renderPNG(store: store, sessionStore: sessionStore,
                                  clipboard: clipboard, focus: focus,
                                  history: history, model: model,
                                  system: system, backpack: backpack,
                                  clearBackground: clearBackground) else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(1)
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("snapshot: write failed: \(error)\n".utf8))
            exit(1)
        }

        print("snapshot written to \(path) "
              + "(panel \(Int(model.panelWidth))x\(Int(model.visibleBodyHeight)), "
              + "page: \(page.title.lowercased()), "
              + "providers: \(store.usages.count), mode: \(demo ? "demo" : "live"))")
        exit(0)
    }

    /// Renders the status bar item on a light and a dark strip.
    ///
    /// The readout is one template image, which means the menu bar supplies the
    /// colour and only the alpha channel is ours. That is easy to get wrong in a
    /// way no other verification mode would catch — a meter track drawn as a
    /// colour instead of partial alpha looks fine on one menu bar and disappears
    /// on the other — so both tints are rendered side by side here.
    @MainActor
    static func runStatusBarAndExit(path: String) -> Never {
        _ = NSApplication.shared

        // The readout is one glyph and one number, so the states worth
        // rendering are the ones that change the *text*: past the warning
        // threshold, ordinary, needing input, and nothing connected.
        //
        // The mini meters this mode used to draw are gone from the app, and
        // the fixtures went with them — a verification mode that renders a
        // component the product no longer ships is worse than no mode at all,
        // because it keeps passing.
        let cases: [(label: String, percent: String, needsInput: Bool)] = [
            ("92% used \u{2014} past the warning line", "92%", false),
            ("63% used", "63%", false),
            ("63% used, a session needs input", "63%", true),
            ("nothing connected", "\u{2013}", false),
            // A running focus timer takes the slot from the percentage, so the
            // longest string the menu bar ever shows is a clock, not a number.
            ("focus countdown running", "24:12", false),
            ("focus stopwatch past an hour", "1:04:37", false),
            ("focus timer paused", "\u{23F8} 24:12", false),
        ]

        let rowHeight: CGFloat = 30
        let labelWidth: CGFloat = 190
        let stripWidth: CGFloat = 150
        let size = NSSize(width: labelWidth + stripWidth * 2,
                          height: rowHeight * CGFloat(cases.count) + rowHeight)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            FileHandle.standardError.write(Data("snapshot-statusbar: context failed\n".utf8))
            exit(1)
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The backing store is 2x the point size, and a bitmap context does not
        // pick that up from rep.size, so everything below would land in the
        // bottom-left quarter without this.
        context.cgContext.scaleBy(x: 2, y: 2)

        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        // Header.
        drawLabel("state", at: NSPoint(x: 10, y: size.height - 21), color: .white)
        drawLabel("light menu bar", at: NSPoint(x: labelWidth + 10, y: size.height - 21), color: .white)
        drawLabel("dark menu bar", at: NSPoint(x: labelWidth + stripWidth + 10, y: size.height - 21),
                  color: .white)

        for (index, item) in cases.enumerated() {
            let y = size.height - rowHeight * CGFloat(index + 2)
            drawLabel(item.label, at: NSPoint(x: 10, y: y + 9), color: .white)

            let image = HotchIcon.statusBarImage()

            for (offset, light) in [(CGFloat(0), true), (stripWidth, false)] {
                let strip = NSRect(x: labelWidth + offset, y: y, width: stripWidth, height: rowHeight)
                (light ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                strip.fill()

                let tint: NSColor = light ? .black : .white
                let origin = NSPoint(x: strip.minX + 12, y: strip.midY - image.size.height / 2)
                draw(template: image, at: origin, tint: tint)

                var x = origin.x + image.size.width + 5
                // The needs-input dot and the red percentage are the two parts
                // of the readout a template image cannot express, so both have
                // to be reproduced here or the snapshot would not be checking
                // the whole surface.
                if item.needsInput {
                    NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.30, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: strip.midY - 2.5,
                                                width: 5, height: 5)).fill()
                    x += 9
                }
                let isHigh = item.percent.hasPrefix("92")
                drawLabel(item.percent,
                          at: NSPoint(x: x, y: strip.midY - 6),
                          color: isHigh ? .systemRed : tint)
            }
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-statusbar: encode failed\n".utf8))
            exit(1)
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("snapshot-statusbar: write failed: \(error)\n".utf8))
            exit(1)
        }

        print("status bar snapshot written to \(path) (\(cases.count) states, both tints)")
        exit(0)
    }

    /// Applies a tint the way the menu bar does with a template image: the image
    /// contributes only its alpha, the colour comes from outside.
    ///
    /// The `sourceIn` pass has to happen in its own transparent image. Done
    /// directly on the destination it fills the whole bounding box, because the
    /// strip underneath has already made every pixel opaque.
    private static func draw(template image: NSImage, at origin: NSPoint, tint: NSColor) {
        let bounds = NSRect(origin: .zero, size: image.size)
        let tintedImage = NSImage(size: image.size)
        tintedImage.lockFocus()
        image.draw(in: bounds)
        tint.set()
        bounds.fill(using: .sourceIn)
        tintedImage.unlockFocus()
        tintedImage.draw(in: NSRect(origin: origin, size: image.size))
    }

    private static func drawLabel(_ text: String, at point: NSPoint, color: NSColor) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: color
        ]).draw(at: point)
    }

    /// Renders the menu bar popover to a PNG. Same demo data as
    /// `--snapshot-demo`, so the two surfaces can be compared side by side.
    @MainActor
    static func runPopoverAndExit(demo: Bool, path: String, page: PanelPage = .now,
                                  detail: SystemDetailKind? = nil,
                                  backpackCard: Bool = false,
                                  dark: Bool = false,
                                  focusIdle: Bool = false,
                                  focusFull: Bool = false) -> Never {
        _ = NSApplication.shared
        // `--snapshot-dark`: the popover follows the system appearance, and the
        // marketing renders need both faces. Forcing the app-wide appearance is
        // what flips the semantic NSColors; the colorScheme environment below
        // flips the SwiftUI side.
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }

        let store = UsageStore(providers: [
            ClaudeProvider(allowRemote: false),
            CodexProvider(allowRemote: false),
            GrokProvider(),
            KimiProvider(),
            DeepSeekProvider(),
        ])

        let sessionStore = SessionStore()
        let clipboard = ClipboardStore()
        // The demo store never persists: its fixture is injected, and a render
        // must not be able to write over a real day's focus log. The live one
        // reads the real log, which is the whole point of `--snapshot-popover`.
        let focus = FocusStore(persists: !demo)
        let history: UsageHistoryStore

        if demo {
            store.usages = demoUsages()
            store.lastRefresh = Date().addingTimeInterval(-32)
            sessionStore.sessions = demoSessions()
            clipboard.items = demoClipboardItems()
            seedDemoFocus(into: focus, idle: focusIdle, deep: focusFull)
            history = UsageHistoryStore(persists: false)
            seedDemoHistory(into: history)
        } else {
            history = .shared
            var finished = false
            Task { @MainActor in
                await store.refresh()
                finished = true
            }
            while !finished {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            sessionStore.sessions = SessionScanner.scan()
        }

        let system = SystemMonitor.shared
        if demo {
            system.applyDemo(SystemDemo.make())
            applyDemoFixture(store: store, sessions: sessionStore, clipboard: clipboard, focus: focus, system: system)
        } else {
            system.setDemand(.panel, for: "snapshot")
            let until = Date().addingTimeInterval(3.2)
            while Date() < until {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }

        let pages = PopoverPageModel()
        pages.page = page
        pages.macDetail = detail
        pages.backpackCard = backpackCard

        let content = CompactCard(store: store, sessionStore: sessionStore, clipboard: clipboard,
                                  focus: focus, pages: pages, system: system,
                                  backpack: BackpackManager.shared, now: Date(), history: history,
                                  showsTabs: true, showsAppButtons: true, scrollable: false)
            .background(GlassBackground(radius: CardMetrics.radius))
            .clipShape(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous))
        // The same injection the live view roots do, so a render cannot show a
        // different direction than the app.
        let renderer = ImageRenderer(content: content
            .environment(\.usageDisplayMode, AppSettings.shared.displayMode)
            .environment(\.snapshotRendering, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(margin)
            .background(backdrop))
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-popover: render failed\n".utf8))
            exit(1)
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("snapshot-popover: write failed: \(error)\n".utf8))
            exit(1)
        }

        print("popover snapshot written to \(path) "
              + "(providers: \(store.usages.count), mode: \(demo ? "demo" : "live")"
              + (focusIdle ? ", focus idle" : "")
              + (focusFull ? ", full focus log" : "") + ")")
        exit(0)
    }

    /// The Temperatures tile's parts, read from this Mac's own sensors, so a
    /// sensor change can be checked without opening the card.
    static func runThermalProbeAndExit() -> Never {
        guard let sensors = SensorsReader() else {
            print("no SMC sensors on this Mac")
            exit(1)
        }
        _ = sensors.read(onAC: true)
        Thread.sleep(forTimeInterval: 1)
        let values = sensors.read(onAC: true)
        for c in values.components {
            print("\(c.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%5.1f", c.tempC))°C")
        }
        let fans = values.fans.map { "\(Int($0.rpm)) rpm" }
        print("fans       \(fans.isEmpty ? "none read" : fans.joined(separator: ", "))")
        exit(0)
    }

    /// The card laid out by a real hosting view, section by section, with and
    /// without its scroll container. Prints each height so a change to how
    /// sections are contained can be checked without clicking through them.
    @MainActor
    static func runCardProbeAndExit() -> Never {
        _ = NSApplication.shared
        let store = UsageStore(providers: [ClaudeProvider(allowRemote: false), CodexProvider(allowRemote: false)])
        store.usages = demoUsages()
        store.lastRefresh = Date().addingTimeInterval(-32)
        let sessions = SessionStore()
        sessions.sessions = demoSessions()
        let history = UsageHistoryStore(persists: false)
        seedDemoHistory(into: history)
        let system = SystemMonitor.shared
        system.applyDemo(SystemDemo.make())
        applyDemoFixture(store: store, sessions: sessions, system: system)
        let pages = PopoverPageModel()
        for page in PanelPage.allCases {
            pages.page = page
            var heights: [String] = []
            for scrollable in [true, false] {
                let card = CompactCard(store: store, sessionStore: sessions, clipboard: ClipboardStore(),
                                       focus: FocusStore(persists: false), pages: pages, system: system,
                                       backpack: BackpackManager.shared, now: Date(), history: history,
                                       showsTabs: false, scrollable: scrollable)
                    .fixedSize()
                    .environment(\.usageDisplayMode, AppSettings.shared.displayMode)
                let host = NSHostingView(rootView: card)
                host.sizingOptions = [.intrinsicContentSize]
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 400),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let size = host.intrinsicContentSize
                heights.append("\(scrollable ? "contained" : "flat"): \(Int(size.width))x\(Int(size.height))")
            }
            print("\(page.title.padding(toLength: 10, withPad: " ", startingAt: 0)) \(heights.joined(separator: "   "))")
        }
        exit(0)
    }

    /// The anchors on a strip of desktop: the edge tab collapsed, speaking an
    /// alert, and opened with the card beside it; the floating pill and orb,
    /// and the pill speaking an alert.
    @MainActor
    static func runAnchorsAndExit(path: String, dark: Bool) -> Never {
        _ = NSApplication.shared
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let store = UsageStore(providers: [ClaudeProvider(allowRemote: false), CodexProvider(allowRemote: false)])
        store.usages = demoUsages()
        store.lastRefresh = Date().addingTimeInterval(-32)
        let sessions = SessionStore()
        sessions.sessions = demoSessions()
        let history = UsageHistoryStore(persists: false)
        seedDemoHistory(into: history)
        let system = SystemMonitor.shared
        system.applyDemo(SystemDemo.make())
        applyDemoFixture(store: store, sessions: sessions, system: system)
        let pages = PopoverPageModel()
        let focus = FocusStore(persists: false)
        seedDemoFocus(into: focus)
        let alert = LiveActivity(icon: .brand("codex"), leading: "Refactor upload…", trailing: "needs approval",
                                 tint: .white, trailingTint: HP.amber, dot: true, key: "need-demo")

        func rail(_ phase: RailState.Phase, side: HotchPrefs.EdgeSide = .right) -> some View {
            let state = RailState()
            state.phase = phase
            state.side = side
            if phase == .alert { state.alert = alert }
            return RailView(state: state, pages: pages, store: store, sessionStore: sessions, system: system, focus: focus,
                            onSelect: { _ in }, onDrag: { _ in })
        }
        func float(_ style: FloatState.Style, alerting: Bool = false) -> some View {
            let state = FloatState()
            state.style = style
            if alerting { state.alert = alert }
            return FloatView(state: state, store: store, sessionStore: sessions, system: system, focus: focus,
                             onSize: { _ in }, onDrag: { _ in }, onTap: {})
        }
        func caption(_ text: String) -> some View {
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
        }

        let scene = HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .trailing, spacing: 14) {
                caption("Edge tab")
                rail(.collapsed).frame(width: RailController.tabSize.width, height: RailController.tabSize.height)
                caption("Edge tab speaking")
                rail(.alert).frame(width: RailController.alertSize.width, height: RailController.alertSize.height)
                caption("Pill")
                float(.pill).frame(height: 34)
                caption("Pill speaking")
                float(.pill, alerting: true).frame(height: 64)
                caption("Orb")
                float(.orb).frame(height: 50)
                caption("Orb speaking")
                float(.orb, alerting: true).frame(height: 50)
            }
            .frame(width: 320, alignment: .trailing)
            VStack(alignment: .leading, spacing: 14) {
                caption("Open from the edge: card beside the section icons")
                HStack(alignment: .top, spacing: 8) {
                    CompactCard(store: store, sessionStore: sessions, clipboard: ClipboardStore(),
                                focus: FocusStore(persists: false), pages: pages, system: system,
                                backpack: BackpackManager.shared, now: Date(), history: history,
                                showsTabs: false, scrollable: false)
                        .background(GlassBackground(radius: CardMetrics.radius))
                        .clipShape(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous))
                    rail(.expanded).frame(width: RailController.columnSize.width, height: RailController.columnSize.height)
                }
                caption("Bottom, beside the Dock: resting, open, speaking (label above)")
                VStack(alignment: .leading, spacing: 14) {
                    rail(.collapsed, side: .bottom).frame(width: RailController.barSize.width, height: RailController.barSize.height)
                    rail(.expanded, side: .bottom).frame(width: RailController.barOpenSize.width, height: RailController.barOpenSize.height)
                    VStack(spacing: 6) {
                        DockLabelView(state: {
                            let label = DockLabelState()
                            label.alert = alert
                            label.visible = true
                            return label
                        }())
                        rail(.alert, side: .bottom).frame(width: RailController.barSize.width, height: RailController.barSize.height)
                    }
                }
            }
        }
        .padding(28)
        .background(backdrop)
        .environment(\.usageDisplayMode, AppSettings.shared.displayMode)
        .environment(\.snapshotRendering, true)
        .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-anchors: render failed\n".utf8))
            exit(1)
        }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
        } catch { exit(1) }
        print("anchors snapshot written to \(path)")
        exit(0)
    }

    /// Each anchor and card on its own, on transparency, one PNG per piece, for
    /// laying out on a page. The same demo fixture as the anchors scene.
    @MainActor
    static func runPartsAndExit(directory: String, dark: Bool) -> Never {
        _ = NSApplication.shared
        if dark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let store = UsageStore(providers: [ClaudeProvider(allowRemote: false), CodexProvider(allowRemote: false)])
        store.usages = demoUsages()
        store.lastRefresh = Date().addingTimeInterval(-32)
        let sessions = SessionStore()
        sessions.sessions = demoSessions()
        let history = UsageHistoryStore(persists: false)
        seedDemoHistory(into: history)
        let system = SystemMonitor.shared
        system.applyDemo(SystemDemo.make())
        let clipboard = ClipboardStore()
        clipboard.items = demoClipboardItems()
        let focus = FocusStore(persists: false)
        seedDemoFocus(into: focus)
        applyDemoFixture(store: store, sessions: sessions, clipboard: clipboard, focus: focus, system: system)
        let alert = LiveActivity(icon: .brand("codex"), leading: "Refactor upload…", trailing: "needs approval",
                                 tint: .white, trailingTint: HP.amber, dot: true, key: "need-demo")

        func pages(_ page: PanelPage) -> PopoverPageModel {
            let model = PopoverPageModel()
            model.page = page
            return model
        }
        func rail(_ phase: RailState.Phase, side: HotchPrefs.EdgeSide = .right,
                  page: PanelPage = .now) -> some View {
            let state = RailState()
            state.phase = phase
            state.side = side
            if phase == .alert { state.alert = alert }
            return RailView(state: state, pages: pages(page), store: store, sessionStore: sessions, system: system, focus: focus,
                            onSelect: { _ in }, onDrag: { _ in })
        }
        func float(_ style: FloatState.Style, alerting: Bool = false) -> some View {
            let state = FloatState()
            state.style = style
            if alerting { state.alert = alert }
            return FloatView(state: state, store: store, sessionStore: sessions, system: system, focus: focus,
                             onSize: { _ in }, onDrag: { _ in }, onTap: {})
        }
        func card(_ page: PanelPage, menuBar: Bool = false) -> some View {
            CompactCard(store: store, sessionStore: sessions, clipboard: clipboard, focus: focus,
                        pages: pages(page), system: system, backpack: BackpackManager.shared, now: Date(),
                        history: history, showsTabs: menuBar, showsAppButtons: menuBar, scrollable: false)
                .background(GlassBackground(radius: CardMetrics.radius))
                .clipShape(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous))
        }
        func open(_ page: PanelPage) -> some View {
            HStack(alignment: .top, spacing: 8) {
                card(page)
                rail(.expanded, page: page).frame(width: RailController.columnSize.width, height: RailController.columnSize.height)
            }
        }
        func write<V: View>(_ name: String, _ view: V) {
            let renderer = ImageRenderer(content: view
                .environment(\.usageDisplayMode, AppSettings.shared.displayMode)
                .environment(\.snapshotRendering, true)
                .environment(\.colorScheme, dark ? .dark : .light))
            renderer.scale = 2
            renderer.isOpaque = false
            let path = (directory as NSString).appendingPathComponent("\(name).png")
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
                FileHandle.standardError.write(Data("snapshot-parts: \(name) failed\n".utf8))
                exit(1)
            }
        }

        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        write("tab", rail(.collapsed).frame(width: RailController.tabSize.width, height: RailController.tabSize.height))
        write("tab-alert", rail(.alert).frame(width: RailController.alertSize.width, height: RailController.alertSize.height))
        write("open-now", open(.now))
        write("open-ai", open(.ai))
        write("open-sessions", open(.agents))
        write("open-mac", open(.mac))
        write("open-focus", open(.focus))
        write("open-clipboard", open(.clipboard))
        write("tab-left", rail(.collapsed, side: .left).frame(width: RailController.tabSize.width, height: RailController.tabSize.height))
        write("open-left", HStack(alignment: .top, spacing: RailGeometry.cardGap) {
            rail(.expanded, side: .left).frame(width: RailController.columnSize.width, height: RailController.columnSize.height)
            card(.now)
        })
        // Card and rail apart, so a film can resize the card against a fixed rail.
        for (name, page) in [("now", PanelPage.now), ("ai", .ai), ("sessions", .agents), ("mac", .mac), ("focus", .focus), ("clipboard", .clipboard)] {
            write("card-\(name)", card(page))
            write("rail-\(name)", rail(.expanded, page: page).frame(width: RailController.columnSize.width, height: RailController.columnSize.height))
        }
        write("menubar-card", card(.now, menuBar: true))
        write("bottom", rail(.collapsed, side: .bottom).frame(width: RailController.barSize.width, height: RailController.barSize.height))
        write("bottom-open", rail(.expanded, side: .bottom).frame(width: RailController.barOpenSize.width, height: RailController.barOpenSize.height))
        write("bottom-alert", VStack(spacing: 6) {
            DockLabelView(state: {
                let label = DockLabelState()
                label.alert = alert
                label.visible = true
                return label
            }())
            rail(.alert, side: .bottom).frame(width: RailController.barSize.width, height: RailController.barSize.height)
        })
        write("pill", float(.pill).frame(height: 34))
        write("pill-alert", float(.pill, alerting: true).frame(height: 64))
        write("orb", float(.orb).frame(height: 50))
        write("orb-alert", float(.orb, alerting: true).frame(height: 50))
        print("parts written to \(directory)")
        exit(0)
    }

    /// A compact README/social capture with the real 360pt card beside its
    /// rail. The desktop is fictional; no screen pixels or user content enter
    /// this render. Card and rail keep these coordinates across every page.
    @MainActor
    static func runOverviewAndExit(path: String, dark: Bool, page: PanelPage = .now) -> Never {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let fixture = DemoScene()
        fixture.pages.page = page
        writeNative(desktopScene(fixture, phase: .expanded), size: desktopSize, path: path, dark: dark)
        print("overview written to \(path) (fixture: \(demoFixture.rawValue), page: \(page.title))")
        exit(0)
    }

    /// Native, consistently registered frames for a product loop. The PNGs
    /// share a canvas, card attachment and fixed target centers, so a video
    /// encoder can hold or crossfade frames without fabricating UI movement.
    @MainActor
    static func runStoryAndExit(directory: String, dark: Bool) -> Never {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let fixture = DemoScene()
        func write(_ name: String, phase: RailState.Phase) {
            let path = (directory as NSString).appendingPathComponent(name + ".png")
            writeNative(desktopScene(fixture, phase: phase), size: desktopSize, path: path, dark: dark)
        }
        write("00-resting", phase: .collapsed)
        let pages: [(String, PanelPage)] = [("01-now", .now), ("02-ai", .ai), ("03-sessions", .agents),
                                          ("04-mac", .mac), ("05-focus", .focus), ("06-clipboard", .clipboard)]
        for (name, page) in pages {
            fixture.pages.page = page
            write(name, phase: .expanded)
        }
        write("07-alert", phase: .alert)
        print("story frames written to \(directory) (fixture: \(demoFixture.rawValue))")
        exit(0)
    }

    private static let desktopSize = CGSize(width: 740, height: 560)

    @MainActor
    private final class DemoScene {
        let store = UsageStore(providers: [])
        let sessions = SessionStore()
        let clipboard = ClipboardStore()
        let focus = FocusStore(persists: false)
        let history = UsageHistoryStore(persists: false)
        let system = SystemMonitor.shared
        let pages = PopoverPageModel()
        let now = Date()

        init() {
            store.usages = demoUsages(now: now)
            store.lastRefresh = now.addingTimeInterval(-32)
            sessions.sessions = demoSessions(now: now)
            sessions.lastScan = now.addingTimeInterval(-4)
            clipboard.items = demoClipboardItems(now: now)
            seedDemoFocus(into: focus, now: now)
            seedDemoHistory(into: history, now: now)
            system.applyDemo(SystemDemo.make(now: now))
            applyDemoFixture(store: store, sessions: sessions, clipboard: clipboard, focus: focus, system: system, now: now)
        }
    }

    @MainActor
    private static func desktopScene(_ fixture: DemoScene, phase: RailState.Phase) -> some View {
        let state = RailState()
        state.phase = phase
        state.side = .right
        state.alert = phase == .alert ? LiveActivity(icon: .brand("codex"), leading: "Refactor upload…",
                                                    trailing: "needs approval", tint: .white,
                                                    trailingTint: HP.amber, dot: true, key: "need-demo") : nil
        let visible = CGRect(origin: .zero, size: desktopSize)
        let rail = CGRect(x: visible.maxX - RailGeometry.width, y: 108,
                          width: RailGeometry.width, height: RailGeometry.height)
        let attachment = RailGeometry.cardAttachment(rail: rail, visible: visible, side: .right,
                                                     maximumHeight: CardMetrics.maxSectionHeight + 76)
        return ZStack(alignment: .topLeading) {
            backdrop
            VStack(alignment: .leading, spacing: 9) {
                Text("Hotch").font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("AI usage. Sessions. This Mac.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .foregroundStyle(.white)
            .padding(.leading, 28)
            .padding(.top, 48)
            if phase == .expanded {
                CompactCard(store: fixture.store, sessionStore: fixture.sessions, clipboard: fixture.clipboard,
                            focus: fixture.focus, pages: fixture.pages, system: fixture.system,
                            backpack: BackpackManager.shared, now: fixture.now, history: fixture.history,
                            showsTabs: false, scrollable: true)
                    .fixedSize()
                    .background(GlassBackground(radius: CardMetrics.radius))
                    .clipShape(RoundedRectangle(cornerRadius: CardMetrics.radius, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
                    .offset(x: rail.minX - RailGeometry.cardGap - CardMetrics.width,
                            y: visible.height - attachment)
            }
            RailView(state: state, pages: fixture.pages, store: fixture.store, sessionStore: fixture.sessions,
                     system: fixture.system, focus: fixture.focus, onSelect: { _ in }, onDrag: { _ in })
                .frame(width: RailController.size(for: phase, side: .right).width, height: RailGeometry.height)
                .offset(x: visible.maxX - RailController.size(for: phase, side: .right).width,
                        y: visible.height - rail.maxY)
            Text("Demo data")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 28)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)
        }
        .frame(width: desktopSize.width, height: desktopSize.height, alignment: .topLeading)
        .clipped()
    }

    /// Capture an actual AppKit hosting view, including the real viewport of
    /// scroll containers. The transparent offscreen window never takes focus.
    @MainActor
    private static func writeNative<V: View>(_ content: V, size: CGSize, path: String, dark: Bool) {
        let host = NSHostingView(rootView: content
            .environment(\.usageDisplayMode, AppSettings.shared.displayMode)
            .environment(\.snapshotRendering, true)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("snapshot-native: bitmap failed\n".utf8)); exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-native: encode failed\n".utf8)); exit(1)
        }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("snapshot-native: write failed: \(error)\n".utf8)); exit(1)
        }
    }

    private enum DemoFixture: String, CaseIterable {
        case rich, empty, stale, disconnected, highpressure, needsinput
    }

    private static var demoFixture: DemoFixture {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot-fixture") else { return .rich }
        guard args.indices.contains(index + 1), let fixture = DemoFixture(rawValue: args[index + 1]) else {
            FileHandle.standardError.write(Data("--snapshot-fixture must be rich, empty, stale, disconnected, highpressure or needsinput\n".utf8))
            exit(2)
        }
        return fixture
    }

    /// Overrides only injected demo state. Live snapshot paths never call it.
    @MainActor
    private static func applyDemoFixture(store: UsageStore, sessions: SessionStore,
                                         clipboard: ClipboardStore? = nil, focus: FocusStore? = nil,
                                         system: SystemMonitor, now: Date = Date()) {
        switch demoFixture {
        case .rich: break
        case .empty:
            store.usages = []
            store.lastRefresh = now
            sessions.sessions = []
            sessions.lastScan = now
            clipboard?.items = []
            focus?.inject(state: .idle, entries: [], memory: FocusMemory())
        case .stale:
            store.usages = store.usages.map { usage in
                var stale = usage
                stale.asOf = now.addingTimeInterval(-2 * 3600)
                return stale
            }
            store.lastRefresh = now.addingTimeInterval(-2 * 3600)
        case .disconnected:
            store.usages = ["claude", "codex"].map {
                ProviderUsage(providerID: $0, displayName: $0 == "claude" ? "Claude" : "Codex", windows: [],
                              asOf: now, detail: "Connect in Settings", needsSetup: true)
            }
            store.lastRefresh = nil
            sessions.sessions = []
            sessions.lastScan = now
        case .highpressure:
            var demo = SystemDemo.make(now: now)
            let total = demo.snapshot.memory.totalBytes
            demo.snapshot.memory.usedBytes = UInt64(Double(total) * 0.94)
            demo.snapshot.memory.appBytes = UInt64(Double(total) * 0.54)
            demo.snapshot.memory.wiredBytes = UInt64(Double(total) * 0.15)
            demo.snapshot.memory.compressedBytes = UInt64(Double(total) * 0.25)
            demo.snapshot.memory.cachedBytes = UInt64(Double(total) * 0.02)
            demo.snapshot.memory.freeBytes = UInt64(Double(total) * 0.01)
            demo.snapshot.memory.pressure = .critical
            demo.snapshot.memory.pressurePercent = 94
            demo.snapshot.memory.swapUsedBytes = 4_294_967_296
            demo.snapshot.memory.swapTotalBytes = 6_442_450_944
            demo.memory = SystemDemo.series(seed: 31, base: 94, spread: 2, floor: 90)
            system.applyDemo(demo)
        case .needsinput:
            sessions.sessions = [AgentSession(id: "demo-approval", providerID: "codex", name: "Refactor upload pipeline",
                                              projectName: "photo-sync", activity: .needsInput,
                                              lastEventAt: now.addingTimeInterval(-45), startedAt: now.addingTimeInterval(-23 * 60),
                                              contextTokens: 41_235, contextLimit: 258_400)]
            sessions.lastScan = now
        }
    }

    /// Renders the settings window content to a PNG, for verifying the config
    /// UI without a GUI session.
    ///
    /// Deliberately backed by a throwaway defaults suite rather than the real
    /// one: SwiftUI writes through Toggle and Picker bindings while laying the
    /// view out, so rendering against AppSettings.shared silently rewrote the
    /// user's actual preferences.
    @MainActor
    static func runSettingsAndExit(path: String) -> Never {
        _ = NSApplication.shared

        let scratch = UserDefaults(suiteName: "com.hojaejung.hotch.snapshot")
            ?? .standard
        scratch.removePersistentDomain(forName: "com.hojaejung.hotch.snapshot")

        let settings = AppSettings(defaults: scratch)
        let view = SettingsView(settings: settings)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true

        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot-settings: render failed\n".utf8))
            exit(1)
        }

        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            FileHandle.standardError.write(Data("snapshot-settings: write failed: \(error)\n".utf8))
            exit(1)
        }

        print("settings snapshot written to \(path)")
        exit(0)
    }

    /// The settings window as AppKit actually builds it, not as `ImageRenderer`
    /// approximates it.
    ///
    /// Worth having as well as `runSettingsAndExit`, for two reasons. It is the
    /// only way to see the *viewport* — the renderer deliberately lays the whole
    /// column out flat, so it can never show what is above or below the fold, or
    /// whether the fold cuts a section in half. And a real window hosts real
    /// AppKit controls, so the pickers and fields draw as themselves instead of
    /// the yellow placeholder bars `ImageRenderer` leaves behind — which is
    /// exactly where the last two settings bugs lived.
    ///
    /// Prints the measurements it took, so a run is useful even without opening
    /// the PNG.
    @MainActor
    static func runSettingsWindowAndExit(path: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let scratch = UserDefaults(suiteName: "com.hojaejung.hotch.snapshot")
            ?? .standard
        scratch.removePersistentDomain(forName: "com.hojaejung.hotch.snapshot")

        let settings = AppSettings(defaults: scratch)
        let view = SettingsView(settings: settings,
                                viewportHeight: SettingsView.viewportHeight)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Hotch Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: SettingsView.columnWidth,
                                     height: SettingsView.viewportHeight))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        // One turn of the loop: SwiftUI resolves its layout on the next pass, so
        // measuring immediately reports the pre-layout size of the scroll view.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let content = window.contentView?.frame.size ?? .zero
        print("window content: \(Int(content.width)) x \(Int(content.height)) pt")
        print("window frame:   \(Int(window.frame.width)) x \(Int(window.frame.height)) pt "
              + "(title bar included)")

        // Walk to the NSScrollView SwiftUI made, and ask it what it is hiding.
        func scroller(in view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            for sub in view.subviews {
                if let found = scroller(in: sub) { return found }
            }
            return nil
        }

        if let scroll = scroller(in: window.contentView ?? NSView()) {
            let documentHeight = scroll.documentView?.frame.height ?? 0
            let visible = scroll.contentView.bounds.height
            print("column height:  \(Int(documentHeight)) pt")
            print("visible:        \(Int(visible)) pt")
            print("scrollable by:  \(Int(max(0, documentHeight - visible))) pt")
            print("scrollers:      \(scroll.scrollerStyle == .overlay ? "overlay" : "legacy")")
            print("content width:  \(Int(scroll.contentView.bounds.width)) pt")
            if documentHeight <= visible {
                print("NOTE: everything fits; nothing is below the fold.")
            }
        } else {
            print("NOTE: no NSScrollView found — the column is not scrollable.")
        }

        func capture(to path: String) {
            guard let content = window.contentView,
                  let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url)
            print("written to \(path)")
        }

        capture(to: path)

        // The bottom of the column is the half the user could not reach before,
        // so it is the half most worth looking at. Written beside the first as
        // `-bottom`.
        if let scroll = scroller(in: window.contentView ?? NSView()),
           let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0,
                                                  y: document.frame.height
                                                     - scroll.contentView.bounds.height))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            let url = URL(fileURLWithPath: path)
            capture(to: url.deletingPathExtension().path + "-bottom."
                    + (url.pathExtension.isEmpty ? "png" : url.pathExtension))
        }
        exit(0)
    }

    // MARK: - Rendering

    /// `clearBackground` renders the panel alone on transparency — no demo
    /// wallpaper, no margins baked in. It exists for compositing: a marketing
    /// image that places the panel on its own desktop needs the panel's true
    /// rounded outline as alpha, not a rectangle of somebody's gradient. The
    /// dev renders keep the backdrop, because there the gradient is the point —
    /// it is what makes the edge and corner radii legible.
    @MainActor
    static func renderPNG(store: UsageStore,
                          sessionStore: SessionStore,
                          clipboard: ClipboardStore,
                          focus: FocusStore,
                          history: UsageHistoryStore,
                          model: PanelModel,
                          system: SystemMonitor,
                          backpack: BackpackManager,
                          clearBackground: Bool = false) -> Data? {
        let pad = clearBackground ? 0 : margin
        let size = CGSize(width: model.panelWidth + pad * 2,
                          height: model.visibleShapeHeight + pad * 2)

        // The panel body normally starts topOverflow above the screen edge, so
        // shift it up by that much and the simulated screen edge lands at the
        // top margin line.
        let scene = ZStack(alignment: .top) {
            if !clearBackground { backdrop }
            NotchPanelContent(store: store, sessionStore: sessionStore,
                              clipboard: clipboard, focus: focus,
                              model: model, system: system, backpack: backpack,
                              now: Date(), history: history)
                .padding(.top, pad - model.topOverflow)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.usageDisplayMode, AppSettings.shared.displayMode)
        .environment(\.snapshotRendering, true)

        // The panel is fully opaque now, so ImageRenderer reproduces it exactly.
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        renderer.isOpaque = !clearBackground

        guard let image = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Stand-in for the desktop wallpaper so the panel edge, the corner radii and
    /// the translucency are all legible in the PNG.
    private static var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.16, blue: 0.26),
                         Color(red: 0.32, green: 0.20, blue: 0.24),
                         Color(red: 0.10, green: 0.13, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Soft blobs give the blur something to chew on.
            Circle()
                .fill(Color(red: 0.95, green: 0.55, blue: 0.30).opacity(0.35))
                .frame(width: 210, height: 210)
                .offset(x: -150, y: 40)
                .blur(radius: 30)
            Circle()
                .fill(Color(red: 0.25, green: 0.75, blue: 0.85).opacity(0.30))
                .frame(width: 190, height: 190)
                .offset(x: 170, y: -10)
                .blur(radius: 30)
        }
    }

    // MARK: - Demo data

    /// Fictional usage for a Claude Team seat with a session, a weekly and a
    /// model-scoped weekly window; Codex on Pro lite, which
    /// meters a single weekly window. The Codex week is set to run out before
    /// its reset so the amber forecast renders, and the Claude session sits at
    /// 63% so a healthy ring renders beside it.
    static func demoUsages(now: Date = Date()) -> [ProviderUsage] {
        let claude = ProviderUsage(
            providerID: "claude",
            displayName: "Claude",
            windows: [
                UsageWindow(label: "Session",
                            usedPercent: 63,
                            resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60),
                            windowMinutes: 300),
                UsageWindow(label: "Weekly",
                            usedPercent: 41,
                            resetsAt: now.addingTimeInterval(3 * 86400 + 2 * 3600),
                            windowMinutes: 10080),
                UsageWindow(label: "Fable week",
                            usedPercent: 22,
                            resetsAt: now.addingTimeInterval(3 * 86400 + 2 * 3600))
            ],
            asOf: now,
            detail: "Team plan"
        )

        let codex = ProviderUsage(
            providerID: "codex",
            displayName: "Codex",
            windows: [
                UsageWindow(label: "Weekly",
                            usedPercent: 58,
                            resetsAt: now.addingTimeInterval(4 * 86400 + 3600),
                            windowMinutes: 10080)
            ],
            asOf: now,
            detail: "Pro lite"
        )

        return [claude, codex]
    }

    /// One session in every state the page can draw, so a single render
    /// exercises the whole vocabulary: the amber needs-input row (which also
    /// drives the menu bar dot), both brands working, a finished turn, and a
    /// session that has ended.
    ///
    /// The context gauges spread the same way on purpose — a nearly-full window
    /// in the warning red, a couple mid-range, a 1M-window session (which is the
    /// only way to see the token caption disagree with the percentage), and one
    /// row with no reading at all, which is what a Codex thread looks like
    /// before it has reported a turn.
    static func demoSessions(now: Date = Date()) -> [AgentSession] {
        [
            AgentSession(id: "demo-1", providerID: "claude",
                         name: "Add a dark mode toggle",
                         projectName: "weather-app", activity: .needsInput,
                         lastEventAt: now.addingTimeInterval(-3 * 60),
                         startedAt: now.addingTimeInterval(-52 * 60),
                         contextTokens: 178_400, contextLimit: 200_000),
            AgentSession(id: "demo-2", providerID: "claude",
                         name: "Fix the checkout test",
                         projectName: "storefront", activity: .working,
                         lastEventAt: now.addingTimeInterval(-6),
                         startedAt: now.addingTimeInterval(-14 * 60),
                         contextTokens: 94_100, contextLimit: 200_000),
            AgentSession(id: "demo-3", providerID: "codex", name: "Refactor upload pipeline",
                         projectName: "photo-sync", activity: .working,
                         lastEventAt: now.addingTimeInterval(-3),
                         startedAt: nil,
                         contextTokens: 41_235, contextLimit: 258_400),
            AgentSession(id: "demo-4", providerID: "claude",
                         name: "Write the release notes",
                         projectName: "demo-project", activity: .waiting,
                         lastEventAt: now.addingTimeInterval(-11 * 60),
                         startedAt: nil,
                         contextTokens: 312_000, contextLimit: 1_000_000),
            AgentSession(id: "demo-5", providerID: "codex", name: "Review the documentation",
                         projectName: "Documents", activity: .ended,
                         lastEventAt: now.addingTimeInterval(-156 * 60),
                         startedAt: nil),
        ]
    }

    /// Clipboard fixtures: a command, a URL, a sentence, a path, a token-ish
    /// string — the shapes people actually copy, each truncating differently.
    static func demoClipboardItems(now: Date = Date()) -> [ClipboardItem] {
        let fixtures: [(String, TimeInterval)] = [
            ("make dmg NOTARY_PROFILE=hotch", 40),
            ("https://example.com/design-notes", 4 * 60),
            ("A small interface should keep its place while the work changes around it.", 11 * 60),
            ("~/Library/Application Support/Hotch/usage-history.json", 26 * 60),
            ("df1f8ac2-4c11-4f2e-9d7a-note-not-a-real-token", 48 * 60),
        ]
        return fixtures.enumerated().map { index, fixture in
            ClipboardItem(id: index + 1,
                          text: fixture.0,
                          preview: ClipboardStore.preview(of: fixture.0),
                          copiedAt: now.addingTimeInterval(-fixture.1))
        }
    }

    /// A named timer mid-run with three runs already banked, so one render shows
    /// the ring, the task name, the tally marks and the log at once. One banked
    /// entry is deliberately unnamed: runs started from the menu bar have no
    /// name, and the log has to look right without one.
    ///
    /// The running timer carries its **live log line**, because that is what the
    /// store does now — a run is a row from the moment it starts. Keeping the
    /// fixture in step with the model is the whole point of a fixture: a render
    /// of a state the app can no longer produce keeps passing while the product
    /// changes underneath it.
    ///
    /// Three finished lines, not four, and their durations are unchanged. The
    /// notch panel's tally column is drawn from exactly this list, and it is a
    /// glance surface whose job is to be identical from one release to the
    /// next — so the third line's *sync* state carries the new case instead of
    /// a fourth line being added for it.
    ///
    /// `idle` renders the other half of the page: the start row, with the
    /// length the memory pre-selected and the project chip beside it. It needs
    /// its own render because the two halves cannot be on screen at once — the
    /// start row *is* what the running readout replaces — and the chip is the
    /// part of this feature a render is most worth having, since it is the one
    /// element carrying a name this app did not write.
    @MainActor
    static func seedDemoFocus(into focus: FocusStore, now: Date = Date(),
                              idle: Bool = false, deep: Bool = false) {
        let runStart = now.addingTimeInterval(-14 * 60)
        let live = UUID()
        if idle {
            focus.inject(state: .idle,
                         entries: demoFocusEntries(now: now, deep: deep),
                         // A name already in the field, and one this Mac has
                         // been told about before. That is what the chip's
                         // second line is *made of*: the pair comes from the
                         // name's own memory, not from a setting, so a render
                         // with an empty field could only ever show a project.
                         draft: demoRememberedTitle,
                         memory: demoFocusMemory(now: now, runStart: runStart))
            return
        }
        focus.inject(
            // segmentStart set: a Run built without one is paused, and the demo
            // should show the live state.
            state: .running(FocusStore.Run(entryID: live,
                                           startedAt: runStart,
                                           length: 30 * 60,
                                           title: "Rewriting the forecast page",
                                           segmentStart: runStart)),
            entries: demoFocusEntries(now: now, deep: deep) + [
                // The run in progress, as its own row: filled dot, ticking
                // duration, Pause and Stop on the row itself.
                FocusEntry(id: live,
                           startedAt: runStart,
                           duration: 14 * 60,
                           title: "Rewriting the forecast page",
                           length: 30 * 60,
                           isRunning: true),
            ],
            memory: demoFocusMemory(now: now, runStart: runStart)
        )
    }

    /// The finished half of the day, shared by both faces of the fixture.
    ///
    /// One finished countdown (resume = start again), one cut short (resume =
    /// continue), one unnamed open-ended, so the log renders every resume
    /// flavour at once.
    static func demoFocusEntries(now: Date, deep: Bool = false) -> [FocusEntry] {
        deepFocusEntries(now: now, count: deep ? deepFocusCount : 0)
        + [
            FocusEntry(startedAt: now.addingTimeInterval(-3.4 * 3600),
                       duration: 45 * 60,
                       title: "Inbox and reviews",
                       length: 45 * 60),
            FocusEntry(startedAt: now.addingTimeInterval(-2.2 * 3600),
                       duration: 12 * 60,
                       title: "Sketching the pages",
                       length: 30 * 60),
            FocusEntry(startedAt: now.addingTimeInterval(-1.6 * 3600),
                       duration: 25 * 60),
        ]
    }

    /// Enough earlier runs that the log's cap has to bite and the overflow
    /// count has to say so. Ten kept plus this many is the state that decides
    /// the tallest the focus page can ever be, so it gets a render of its own
    /// rather than an estimate.
    static let deepFocusCount = 11

    /// Filler for the morning of a very busy day. Deliberately awkward: one
    /// name far longer than the row, so the deep render also checks that the
    /// name is still the element that truncates when a row runs out of width.
    static func deepFocusEntries(now: Date, count: Int) -> [FocusEntry] {
        guard count > 0 else { return [] }
        let names = [
            "Standup",
            "Triage: notarisation ticket backlog and the release checklist",
            "Pairing on the sync queue",
            "Code review",
            "Writing the release notes",
            "Reading the crash reports",
        ]
        return (0..<count).map { index in
            let hoursAgo: Double = 9.5 - Double(index) * 0.5
            let duration: TimeInterval = Double(10 + (index % 5) * 7) * 60
            let length: TimeInterval = Double(15 + (index % 4) * 15) * 60
            return FocusEntry(startedAt: now.addingTimeInterval(-hoursAgo * 3600),
                              duration: duration,
                              title: names[index % names.count],
                              length: length)
        }
    }

    /// The name sitting in the field for the idle render, and the one the
    /// memory below remembers a length for.
    static let demoRememberedTitle = "Sketch the settings screen"

    /// What this Mac has been told about these task names. The idle render is
    /// checking exactly this: the 30m pill is selected because a previous run
    /// selected it, not because anything defaults to 30 minutes.
    static func demoFocusMemory(now: Date, runStart: Date) -> FocusMemory {
        FocusMemory(habits: [
            FocusMemory.Habit(title: "Inbox and reviews",
                              length: .minutes(45),
                              at: now.addingTimeInterval(-3.4 * 3600)),
            FocusMemory.Habit(title: "Rewriting the forecast page",
                              length: .minutes(30),
                              at: runStart),
            FocusMemory.Habit(title: demoRememberedTitle,
                              // Still 30, so the pill the idle render has always
                              // shown selected is still the one it shows.
                              length: .minutes(30),
                              at: now.addingTimeInterval(-0.7 * 3600)),
        ],
        lastLength: .minutes(30))
    }

    /// History that exercises every forecast verdict against `demoUsages`:
    /// Claude's session window climbs fast enough to hit the cap *before* its
    /// reset (the amber line the page exists for), Codex's session window is
    /// flat (no burn), and the weekly windows drift up slowly. Values end where
    /// the demo usages stand so the two pages agree with each other.
    static func seedDemoHistory(into history: UsageHistoryStore, now: Date = Date()) {
        func ramp(hours: Double, step: TimeInterval, from: Double, to: Double,
                  wobble: Double = 0.6) -> [UsageSample] {
            let start = now.addingTimeInterval(-hours * 3600)
            var out: [UsageSample] = []
            var t = start
            var index = 0.0
            let total = hours * 3600 / step
            while t <= now {
                let progress = index / max(1, total)
                let value = from + (to - from) * progress
                    + wobble * sin(index * 1.7)
                out.append(UsageSample(time: t, consumedPercent: min(100, max(0, value))))
                t = t.addingTimeInterval(step)
                index += 1
            }
            return out
        }

        // Claude session: a steady ~4%/hr that lands well inside the reset.
        history.seed(providerID: "claude", windowLabel: "5h",
                     samples: ramp(hours: 1.5, step: 120, from: 57, to: 63, wobble: 0.3))
        history.seed(providerID: "claude", windowLabel: "7d",
                     samples: ramp(hours: 1.5, step: 120, from: 40.2, to: 41, wobble: 0.1))
        // Codex week: a heavy afternoon, ~1.2%/hr over four days runs out first.
        history.seed(providerID: "codex", windowLabel: "7d",
                     samples: ramp(hours: 1.5, step: 120, from: 56.2, to: 58, wobble: 0.1))
    }
}
