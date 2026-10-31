import AppKit
import SwiftUI

/// `--check-card-motion`: runs the real card window on the demo fixture and
/// watches it move between pages, frame by frame.
///
/// A still render cannot see motion, and the card's tab switch went wrong in
/// motion twice: two pages faded across each other at the taller one's
/// height and then snapped to the new one, and the window was once shrunk
/// before the card had. This samples what the window actually draws while
/// the page changes, then checks each switch eased in one move, never cut
/// the card off, kept the card pinned to its anchor and settled at the
/// height the window was given.
///
/// The windows are real but unseen (`NotchPanel.unseen`): drawn, laid out
/// and animated as usual, never shown or clickable. `--check-card-motion
/// <directory>` also writes a filmstrip of each switch there.
@MainActor
enum CardMotionCheck {
    /// What one sampled frame of the card window shows.
    struct Frame {
        var t: TimeInterval
        var window: CGRect
        /// The card's drawn extent, in points from the window's top.
        var top: CGFloat
        var bottom: CGFloat
        var height: CGFloat { bottom - top }
        /// The drawn card meets a window edge with its corners missing.
        var cutBottom: Bool
        var cutTop: Bool
        /// Dark pixels between the header and the footer: the page's text and
        /// marks. A switch that blanks the page shows as a dip.
        var ink: Int
        var image: CGImage?
    }

    nonisolated(unsafe) private static var failures = 0

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("  ok    \(name)")
        } else {
            failures += 1
            let suffix = detail().isEmpty ? "" : " \u{2014} \(detail())"
            print("  FAIL  \(name)\(suffix)")
        }
    }

    static func runBlockingAndExit(directory: String?) -> Never {
        NotchPanel.unseen = true
        Haptics.muted = true
        let suite = "com.hojaejung.hotch.card-motion"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        HotchPrefs.defaultsOverride = UserDefaults(suiteName: suite)
        let history = UsageHistoryStore(persists: false)
        Snapshot.seedDemoHistory(into: history)
        UsageHistoryStore.sharedOverride = history
        AppSettings.displayModeOverride = .used

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .aqua)
        app.finishLaunching()

        let deps = demoDeps()
        let card = CardPanelController(deps: deps)
        guard let screen = NSScreen.main else {
            print("no display to lay the card out on")
            exit(1)
        }
        let visible = screen.visibleFrame
        print("reduce motion: \(HMotion.reduceMotion ? "on" : "off")")

        // Hung from its top right, as the right-hand edge tab hangs it.
        let anchor = CGPoint(x: visible.maxX - 40, y: visible.maxY - 60)
        let hung: (CGSize) -> CGRect = { size in
            CGRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height)
        }
        card.show(origin: .topTrailing, alignment: .topTrailing, showsTabs: true, placement: hung)
        _ = spin(card, for: 0.8)

        print("each page to every other page, hung from the top")
        var strips: [(String, [Frame])] = []
        for (name, frames) in everySwitch(card: card, deps: deps, hungFromTop: true, images: directory != nil) {
            strips.append((name, frames))
        }

        print("Mac detail and Backpack")
        detours(card: card, deps: deps)

        print("rapid switching")
        rapid(card: card, deps: deps, hungFromTop: true)

        print("live data")
        live(card: card, deps: deps)

        card.hide()
        _ = spin(card, for: 0.4)

        // Standing on its bottom edge, as the tab along the bottom of the
        // screen holds it: it grows and shrinks upward.
        let floor = CGPoint(x: visible.midX, y: visible.minY + 60)
        let docked: (CGSize) -> CGRect = { size in
            CGRect(x: floor.x - size.width / 2, y: floor.y, width: size.width, height: size.height)
        }
        deps.pages.select(.home)
        card.show(origin: .bottom, alignment: .bottom, showsTabs: true, placement: docked)
        _ = spin(card, for: 0.8)
        print("each page to every other page, standing on the bottom")
        for (name, frames) in everySwitch(card: card, deps: deps, hungFromTop: false, images: directory != nil) {
            strips.append(("bottom " + name, frames))
        }
        print("rapid switching, standing on the bottom")
        rapid(card: card, deps: deps, hungFromTop: false)

        card.hide()
        _ = spin(card, for: 0.4)
        if let directory {
            writeStrips(strips, to: directory)
        }

        print("edge tab: hover, click to keep, click to close")
        edgeTab(deps: deps)

        print("notch: each page to every other page")
        notch(deps: deps)

        UserDefaults.standard.removePersistentDomain(forName: suite)
        print(failures == 0 ? "card motion: all checks passed" : "card motion: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Scenarios

    private static func everySwitch(card: CardPanelController, deps: CardDeps, hungFromTop: Bool,
                                    images: Bool) -> [(String, [Frame])] {
        var all: [(String, [Frame])] = []
        for from in PanelPage.allCases {
            for to in PanelPage.allCases where to != from {
                deps.pages.select(from)
                _ = spin(card, for: 0.6)
                let before = sample(card, at: 0, keepImage: false)
                deps.pages.select(to)
                let frames = spin(card, for: 0.55, sampling: true, images: images)
                let name = "\(from.title) \u{2192} \(to.title)"
                judgeSwitch(name, card: card, before: before, frames: frames, hungFromTop: hungFromTop)
                all.append((name, frames))
            }
        }
        return all
    }

    /// The two places a page opens something in place of itself.
    private static func detours(card: CardPanelController, deps: CardDeps) {
        let pages = deps.pages
        let moves: [(String, PanelPage, () -> Void)] = [
            ("Mac \u{2192} CPU detail", .mac, { withAnimation(HMotion.detail) { pages.macDetail = .cpu } }),
            ("CPU detail \u{2192} Mac", .mac, { withAnimation(HMotion.detail) { pages.macDetail = nil } }),
            ("Desk \u{2192} Backpack", .desk, { withAnimation(HMotion.section) { pages.backpackCard = true } }),
            ("Backpack \u{2192} Hotch", .desk, { pages.select(.home) }),
        ]
        for (name, page, move) in moves {
            if pages.page != page || (name.hasPrefix("Mac") && pages.macDetail != nil) {
                pages.select(page)
            }
            if name.hasPrefix("CPU") { withAnimation(nil) { pages.macDetail = .cpu } }
            if name.hasPrefix("Backpack") { withAnimation(nil) { pages.backpackCard = true } }
            _ = spin(card, for: 0.6)
            let before = sample(card, at: 0, keepImage: false)
            move()
            let frames = spin(card, for: 0.55, sampling: true)
            judgeSwitch(name, card: card, before: before, frames: frames, hungFromTop: true)
        }
    }

    /// Clicking through the tabs faster than the motion: every switch lands
    /// on top of one still moving.
    private static func rapid(card: CardPanelController, deps: CardDeps, hungFromTop: Bool) {
        let sequence: [(PanelPage, TimeInterval)] = [
            (.ai, 0.03), (.mac, 0.05), (.home, 0.07), (.desk, 0.04), (.mac, 0.06), (.ai, 0.035),
            (.home, 0.08), (.mac, 0.045), (.desk, 0.03), (.ai, 0.065), (.mac, 0.02), (.home, 0.05),
            (.mac, 0.0),
        ]
        deps.pages.select(.desk)
        _ = spin(card, for: 0.6)
        let before = sample(card, at: 0, keepImage: false)
        let clock = Date()
        var frames: [Frame] = []
        for (page, gap) in sequence {
            deps.pages.select(page)
            frames += spin(card, for: gap, sampling: true, clock: clock)
        }
        let lastClick = Date().timeIntervalSince(clock)
        frames += spin(card, for: 0.6, sampling: true, clock: clock)
        guard let last = frames.last else { return check("rapid switching", false, "no frames") }
        let expected = card.contentSize.height
        let cut = frames.filter { $0.cutBottom || $0.cutTop }
        let drift = frames.map { abs(anchoredEdge($0, hungFromTop) - anchoredEdge(before, hungFromTop)) }.max() ?? 0
        // The first frame from which the card stays at its settled height.
        let reached = frames.lastIndex { abs($0.height - expected) >= 1 }
            .map { $0 + 1 < frames.count ? frames[$0 + 1].t : .infinity } ?? lastClick
        let floor = frames.map(\.ink).min() ?? 0
        print(String(format: "  %d clicks in %.0fms, settled %.0fms after the last, ink floor %d",
                     sequence.count, lastClick * 1000, (reached - lastClick) * 1000, floor))
        check("ends on the last page clicked", deps.pages.page == .mac)
        check("settles at the card's own height", abs(last.height - expected) < 1.5,
              "drawn \(last.height), laid out \(expected)")
        check("the window fits the settled card", abs(last.window.height - expected) < 1.5,
              "window \(last.window.height), card \(expected)")
        check("settles within the section motion of the last click", reached - lastClick < 0.4,
              "\(Int((reached - lastClick) * 1000))ms")
        check("never cut off by its window", cut.isEmpty,
              "\(cut.count) frames, first at \(Int((cut.first?.t ?? 0) * 1000))ms")
        check("stays on its anchor", drift < 1.5, "moved \(drift)pt")
        check("never blanks", floor > 2000, "page ink fell to \(floor)")
    }

    /// Readings that arrive while the card is open: most change no height and
    /// must move nothing; a session starting or finishing changes the home
    /// page's height at once, without the switch's easing.
    private static func live(card: CardPanelController, deps: CardDeps) {
        let sessions = deps.sessionStore
        let asking = sessions.sessions
        var answered = asking
        for index in answered.indices where answered[index].activity == .needsInput {
            answered[index].activity = .working
            answered[index].waitingFor = nil
        }

        deps.pages.select(.home)
        _ = spin(card, for: 0.6)
        var before = sample(card, at: 0, keepImage: false)
        var usages = deps.store.usages
        for index in usages.indices {
            usages[index].windows = usages[index].windows.map { window in
                var next = window
                next.usedPercent = window.usedPercent.map { min(100, $0 + 3) }
                return next
            }
        }
        deps.store.usages = usages
        deps.system.applyDemo(SystemDemo.make())
        var frames = spin(card, for: 0.5, sampling: true)
        let still = frames.allSatisfy { abs($0.height - before.height) < 0.5 && $0.window == before.window }
        check("new usage and system readings move nothing", still,
              "height \(before.height) became \(frames.map(\.height).min() ?? 0)\u{2013}\(frames.map(\.height).max() ?? 0)")

        func change(_ name: String, to list: [AgentSession]) {
            before = sample(card, at: 0, keepImage: false)
            sessions.sessions = list
            frames = spin(card, for: 0.6, sampling: true)
            guard let last = frames.last else { return check(name, false, "no frames") }
            let expected = card.contentSize.height
            let arrived = frames.first { abs($0.height - last.height) < 1 }?.t ?? .infinity
            let cut = frames.filter { $0.cutBottom || $0.cutTop }
            let drift = frames.map { abs(anchoredEdge($0, true) - anchoredEdge(before, true)) }.max() ?? 0
            print(String(format: "  %@: %.0f\u{2192}%.0f, drawn in %.0fms", name, before.height, last.height,
                         arrived * 1000))
            check("\(name): changes the height", abs(last.height - before.height) > 4)
            check("\(name): without the switch's easing", arrived < 0.06, "\(Int(arrived * 1000))ms")
            check("\(name): settles at the card's own height", abs(last.height - expected) < 1.5)
            check("\(name): the window fits the settled card", abs(last.window.height - expected) < 1.5,
                  "window \(last.window.height), card \(expected)")
            check("\(name): never cut off by its window", cut.isEmpty,
                  "\(cut.count) frames, first at \(Int((cut.first?.t ?? 0) * 1000))ms")
            check("\(name): stays on its anchor", drift < 1.5, "moved \(drift)pt")
        }
        change("a session stops waiting on you", to: answered)
        change("a session asks for input", to: asking)

        // A session finishing while the card is still moving to Hotch.
        deps.pages.select(.mac)
        _ = spin(card, for: 0.6)
        before = sample(card, at: 0, keepImage: false)
        deps.pages.select(.home)
        frames = spin(card, for: 0.07, sampling: true)
        let clock = Date().addingTimeInterval(-0.07)
        sessions.sessions = answered
        frames += spin(card, for: 0.6, sampling: true, clock: clock)
        if let last = frames.last {
            let expected = card.contentSize.height
            let cut = frames.filter { $0.cutBottom || $0.cutTop }
            check("a reading mid-switch: settles at the card's own height", abs(last.height - expected) < 1.5,
                  "drawn \(last.height), laid out \(expected)")
            check("a reading mid-switch: the window fits", abs(last.window.height - expected) < 1.5)
            check("a reading mid-switch: never cut off", cut.isEmpty, "\(cut.count) frames")
        }
        sessions.sessions = asking
        _ = spin(card, for: 0.6)
    }

    /// The pointer as the edge tab sees it, moved by the script.
    private final class Script {
        var point = CGPoint(x: -10_000, y: -10_000)
        var click: (() -> Void)?
    }

    /// The real edge tab and its card, with a scripted pointer: the tint,
    /// the dwell before opening, the delay before closing, a click keeping
    /// the card, a second click closing it for good, a click elsewhere, and
    /// an alert label that must not open the card.
    private static func edgeTab(deps: CardDeps) {
        let script = Script()
        let card = CardPanelController(deps: deps)
        let rail = RailController(card: card)
        rail.pointer = PointerSource(location: { script.point }, buttons: { 0 },
                                     watchClicks: { handler in script.click = handler; return nil })
        deps.pages.select(.home)
        rail.start()
        let tab = rail.restingFrame
        let face = CGPoint(x: tab.midX, y: tab.midY)
        let away = CGPoint(x: tab.minX - 600, y: tab.midY)
        let wait = { (seconds: TimeInterval) in _ = spin(card, for: seconds) }
        var open: Bool { rail.state.phase == .expanded && card.isShown }

        script.point = away
        wait(0.3)
        check("resting: closed and untinted", !open && !rail.state.hovering)

        script.point = face
        wait(0.1)
        check("hover: the whole tab tints at once", rail.state.hovering && rail.state.phase == .collapsed)
        wait(0.35)
        check("hover: a short rest opens the card, not kept", open && !card.pinned)
        check("hover: the tint gives way to the open card", !rail.state.hovering)

        script.point = CGPoint(x: card.frame.midX, y: card.frame.midY)
        wait(0.6)
        check("hover: moving onto the card keeps it open", open)

        script.point = away
        wait(0.12)
        check("leaving: the card waits a moment", open)
        wait(0.45)
        check("leaving: then closes", !open && rail.state.phase == .collapsed)

        guard let screen = rail.screen else { return check("edge tab: a display", false) }
        script.point = CGPoint(x: screen.frame.maxX - 2, y: tab.midY)
        wait(0.4)
        check("pushing against the screen edge beside the tab opens it", open)
        script.point = away
        wait(0.6)
        check("and leaving closes it", !open)

        script.point = face
        rail.tapped()
        wait(0.05)
        check("click: opens at once and keeps the card", open && card.pinned)
        script.point = away
        wait(0.8)
        check("click: a kept card stays when the pointer leaves", open)
        script.point = CGPoint(x: card.frame.midX, y: card.frame.midY)
        script.click?()
        wait(0.1)
        check("click: clicking inside the card keeps it", open)
        script.point = away
        script.click?()
        wait(0.4)
        check("click: clicking elsewhere closes it", !open)

        script.point = face
        wait(0.45)
        check("click after hover: hover opened it", open && !card.pinned)
        rail.tapped()
        script.point = away
        wait(0.8)
        check("click after hover: the click keeps it", open && card.pinned)

        // A kept card, its tab switched while hung from the rail.
        deps.pages.select(.mac)
        wait(0.6)
        let before = sample(card, at: 0, keepImage: false)
        deps.pages.select(.ai)
        judgeSwitch("on the tab, Mac \u{2192} AI", card: card, before: before,
                    frames: spin(card, for: 0.55, sampling: true), hungFromTop: true)
        let back = sample(card, at: 0, keepImage: false)
        deps.pages.select(.mac)
        judgeSwitch("on the tab, AI \u{2192} Mac", card: card, before: back,
                    frames: spin(card, for: 0.55, sampling: true), hungFromTop: true)

        script.point = face
        wait(0.1)
        rail.tapped()
        wait(0.1)
        check("second click: closes a kept card", !open)
        wait(0.8)
        check("second click: resting on the tab does not reopen it", !open)
        check("second click: the tab still tints under the pointer", rail.state.hovering)
        script.point = away
        wait(0.15)
        check("second click: the tint leaves with the pointer", !rail.state.hovering)
        script.point = face
        wait(0.45)
        check("second click: once left, hovering opens it again", open && !card.pinned)
        script.point = away
        wait(0.6)

        var alert = LiveActivity(icon: .brand("codex"), leading: "Refactor upload\u{2026}", trailing: "needs approval",
                                 tint: .white, trailingTint: HP.amber, dot: true, key: "need-check")
        alert.hold = 2
        rail.present(alert) {}
        wait(0.4)
        let label = rail.alertLabelFrame
        check("alert: a label beside the tab", rail.state.phase == .alert && label.width > 40
              && (label.maxX <= tab.minX + 1 || label.minX >= tab.maxX - 1), "label \(label), tab \(tab)")
        script.point = CGPoint(x: label.midX, y: label.midY)
        wait(0.6)
        check("alert: resting on the label neither tints nor opens", !open && !rail.state.hovering)
        script.point = away
        wait(2.2)
        check("alert: folds back to the tab", rail.state.phase == .collapsed)
        rail.stop()
        wait(0.3)
    }

    /// The original notch panel, opened and kept open on a stand-in notch:
    /// its shape and its click area follow each page's fixed height. Its
    /// pages cross-fade inside that fixed height, as they always have, so
    /// overlap is reported here rather than judged.
    private static func notch(deps: CardDeps) {
        NotchGeometryResolver.simulatedNotch = CGSize(width: Snapshot.sampleNotchWidth,
                                                     height: Snapshot.sampleNotchClearance)
        defer { NotchGeometryResolver.simulatedNotch = nil }
        let model = PanelModel()
        let n = NotchWindowController(store: deps.store, sessionStore: deps.sessionStore, clipboard: deps.clipboard,
                                      focus: deps.focus, model: model, system: deps.system, backpack: deps.backpack)
        n.pinned = true
        n.expand()
        let wait = { (seconds: TimeInterval) in _ = spin(Probe(window: { nil }), for: seconds) }
        wait(0.2)
        // The notch's click window takes clicks by design; unseen, it must not.
        for window in NSApp.windows { window.ignoresMouseEvents = true }
        guard let content = n.contentWindow,
              let chrome = NSApp.windows.first(where: { $0 !== content && $0.frame == n.panelFrame }) else {
            return check("notch: opens its windows", false)
        }
        let shape = Probe(window: { chrome })
        let page = Probe(window: { content }, lightInk: true,
                         header: PanelModel.tabRowHeight, footer: PanelModel.footerHeight)
        wait(0.8)

        for from in PanelPage.allCases {
            for to in PanelPage.allCases where to != from {
                n.setPage(from)
                wait(0.7)
                let before = sample(shape, at: 0, keepImage: false)
                let pageBefore = sample(page, at: 0, keepImage: false)
                n.setPage(to)
                var shapes: [Frame] = [], pages: [Frame] = []
                let clock = Date()
                while Date().timeIntervalSince(clock) < 1.4 {
                    shapes += spin(shape, for: 0, sampling: true, clock: clock)
                    pages.append(sample(page, at: Date().timeIntervalSince(clock), keepImage: false))
                }
                guard let last = shapes.last, let lastPage = pages.last else { continue }
                let name = "notch \(from.title) \u{2192} \(to.title)"
                if ProcessInfo.processInfo.environment["HOTCH_MOTION_TRACE"] != nil {
                    print("    model page \(model.page.title) detail \(String(describing: model.macDetail)) "
                          + "backpack \(model.backpackCard) expanded \(model.expanded) content \(content.frame)")
                    for (f, p) in zip([before] + shapes, [pageBefore] + pages) where Int(f.t * 1000) % 3 == 0 {
                        print(String(format: "      %4.0fms shape %5.1f..%6.1f  page ink %5d  content h %5.1f",
                                     f.t * 1000, f.top, f.bottom, p.ink, p.window.height))
                    }
                }
                let expected = model.visibleShapeHeight
                let heights = [before.bottom] + shapes.map(\.bottom)
                let delta = last.bottom - before.bottom
                let steps = zip(heights.dropFirst(), heights).map { $0 - $1 }
                let backwards = steps.filter { delta >= 0 ? $0 < -1.5 : $0 > 1.5 }.map(abs).max() ?? 0
                let body = model.visibleBodyHeight - model.contentClearance
                let early = pages.filter { $0.t < 0.35 }.map(\.ink)
                let floor = Double(early.min() ?? 0) / Double(max(1, min(pageBefore.ink, lastPage.ink)))
                let peak = Double(early.max() ?? 0) / Double(max(1, max(pageBefore.ink, lastPage.ink)))
                let times = shapes.map(\.t)
                let stall = zip(times.dropFirst(), times).map { $0 - $1 }.max() ?? 0
                print(String(format: "  %@ shape %.0f\u{2192}%.0f (expected %.0f), page ink %.0f%%\u{2013}%.0f%%, longest frame gap %.0fms",
                             name.padding(toLength: 22, withPad: " ", startingAt: 0),
                             before.bottom, last.bottom, expected, floor * 100, peak * 100, stall * 1000))
                check("\(name): the shape settles at the page's height", abs(last.bottom - expected) < 1.5,
                      "drawn \(last.bottom)")
                check("\(name): the shape moves one way", backwards < 1.5, "reversed by \(backwards)pt")
                check("\(name): the click area fits the page", abs(content.frame.height - body) < 1.5,
                      "window \(content.frame.height), page \(body)")
                check("\(name): the page is drawn", lastPage.ink > 500, "ink \(lastPage.ink)")
            }
        }
        n.collapse(force: true)
        wait(0.5)
        check("notch: closes when told", !n.isExpanded && n.contentWindow == nil)
        n.stop()
    }

    // MARK: Judging

    /// One switch, from the frame before it to the frames after.
    private static func judgeSwitch(_ name: String, card: CardPanelController, before: Frame, frames: [Frame],
                                    hungFromTop: Bool) {
        guard let last = frames.last else {
            check(name, false, "no frames were drawn")
            return
        }
        let start = before.height, end = last.height
        let delta = end - start
        let heights = [start] + frames.map(\.height)
        let steps = zip(heights.dropFirst(), heights).map { $0 - $1 }
        let biggest = steps.map(abs).max() ?? 0
        let backwards = steps.filter { delta >= 0 ? $0 < -1.5 : $0 > 1.5 }.map(abs).max() ?? 0
        let reached = frames.firstIndex { abs($0.height - end) < 1 }.map { frames[$0].t } ?? 0
        let cut = frames.filter { $0.cutBottom || $0.cutTop }
        let anchorDrift = frames.map { abs(anchoredEdge($0, hungFromTop) - anchoredEdge(before, hungFromTop)) }
            .max() ?? 0
        let early = frames.filter { $0.t < 0.35 }
        let inkFloor = early.map(\.ink).min() ?? 0
        let inkPeak = early.map(\.ink).max() ?? 0
        let dip = Double(inkFloor) / Double(max(1, min(before.ink, last.ink)))
        let stack = Double(inkPeak) / Double(max(1, max(before.ink, last.ink)))
        let expected = card.contentSize.height

        let summary = String(format: "%4.0f\u{2192}%-4.0f biggest step %3.0fpt, settled %3.0fms, ink %3.0f%%\u{2013}%3.0f%%",
                             start, end, biggest, reached * 1000, dip * 100, stack * 100)
        print("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(summary)")
        if ProcessInfo.processInfo.environment["HOTCH_MOTION_TRACE"] != nil {
            for f in [before] + frames {
                print(String(format: "      %4.0fms window y%6.1f h%6.1f  card %5.1f..%6.1f  ink %5d%@",
                             f.t * 1000, f.window.minY, f.window.height, f.top, f.bottom, f.ink,
                             f.cutBottom || f.cutTop ? "  CUT" : ""))
            }
        }
        check("\(name): settles at the card's own height", abs(last.height - expected) < 1.5,
              "drawn \(last.height), laid out \(expected)")
        check("\(name): the window fits the settled card",
              abs(last.window.height - expected) < 1.5, "window \(last.window.height), card \(expected)")
        check("\(name): never cut off by its window", cut.isEmpty,
              "\(cut.count) frames, first at \(Int((cut.first?.t ?? 0) * 1000))ms")
        check("\(name): stays on its anchor", anchorDrift < 1.5, "moved \(anchorDrift)pt")
        check("\(name): height moves one way", backwards < 1.5, "reversed by \(backwards)pt")
        check("\(name): the page never blanks", dip > 0.6, "page ink fell to \(Int(dip * 100))%")
        check("\(name): two pages never stack", stack < 1.25, "page ink rose to \(Int(stack * 100))%")
        if abs(delta) > 24 {
            check("\(name): height eases rather than snapping", biggest <= max(16, abs(delta) * 0.4),
                  "one frame moved \(Int(biggest)) of \(Int(abs(delta)))pt")
            check("\(name): eases within the section motion", reached > 0.06 && reached < 0.4,
                  "reached the new height at \(Int(reached * 1000))ms")
        }
    }

    /// Where the drawn card's anchored edge is on screen.
    private static func anchoredEdge(_ frame: Frame, _ hungFromTop: Bool) -> CGFloat {
        hungFromTop ? frame.window.maxY - frame.top : frame.window.maxY - frame.bottom
    }

    // MARK: Sampling

    /// Turns the run loop for a while, as the app would, sampling what the
    /// card window draws whenever it gets a turn.
    private static func spin(_ card: CardPanelController, for duration: TimeInterval, sampling: Bool = false,
                             images: Bool = false, clock: Date? = nil) -> [Frame] {
        spin(Probe(window: { card.panel }), for: duration, sampling: sampling, images: images, clock: clock)
    }

    private static func sample(_ card: CardPanelController, at t: TimeInterval, keepImage: Bool) -> Frame {
        sample(Probe(window: { card.panel }), at: t, keepImage: keepImage)
    }

    /// What to sample: a window, and how its page is told from its chrome.
    private struct Probe {
        var window: () -> NSWindow?
        /// Light marks on a dark surface (the notch), not dark on light.
        var lightInk = false
        /// Bands at the top and bottom that are chrome rather than page.
        var header: CGFloat = 58
        var footer: CGFloat = 34
    }

    private static func spin(_ probe: Probe, for duration: TimeInterval, sampling: Bool = false,
                             images: Bool = false, clock: Date? = nil) -> [Frame] {
        let start = Date()
        var frames: [Frame] = []
        repeat {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004))
            if sampling {
                frames.append(sample(probe, at: Date().timeIntervalSince(clock ?? start), keepImage: images))
            }
        } while Date().timeIntervalSince(start) < duration
        return frames
    }

    private static func sample(_ probe: Probe, at t: TimeInterval, keepImage: Bool) -> Frame {
        let empty = Frame(t: t, window: probe.window()?.frame ?? .zero, top: 0, bottom: 0,
                          cutBottom: false, cutTop: false, ink: 0)
        guard let panel = probe.window(), let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return empty }
        let window = panel.frame
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return empty }
        let w = image.width, h = image.height
        let scale = CGFloat(w) / max(1, view.bounds.width)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * w + x) * 4 + 3] }
        let solid: UInt8 = 40

        // The card is one rounded shape: scan three columns for its extent.
        var top = h, bottom = -1
        for x in [w / 4, w / 2, w * 3 / 4] {
            if let first = (0..<h).first(where: { alpha(x, $0) > solid }) { top = min(top, first) }
            if let last = (0..<h).last(where: { alpha(x, $0) > solid }) { bottom = max(bottom, last) }
        }
        guard bottom >= top else {
            return Frame(t: t, window: window, top: 0, bottom: 0, cutBottom: false, cutTop: false, ink: 0,
                         image: keepImage ? image : nil)
        }
        func span(_ y: Int) -> Int {
            guard y >= 0, y < h,
                  let left = (0..<w).first(where: { alpha($0, y) > solid }),
                  let right = (0..<w).last(where: { alpha($0, y) > solid }) else { return 0 }
            return right - left + 1
        }
        // Two points in from a rounded edge the shape is still well inside its
        // corners; a shape running square into the window's edge is cut off.
        let inset = Int(2 * scale), full = w - Int(4 * scale)
        let cutBottom = bottom >= h - 1 && span(bottom - inset) >= full
        let cutTop = top <= 0 && span(top + inset) >= full

        var ink = 0
        let from = top + Int(probe.header * scale), to = bottom - Int(probe.footer * scale)
        if to > from {
            for y in stride(from: from, to: to, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let i = (y * w + x) * 4
                    let a = Int(pixels[i + 3])
                    guard a > 160 else { continue }
                    let luma = (Int(pixels[i]) * 54 + Int(pixels[i + 1]) * 183 + Int(pixels[i + 2]) * 19) / a
                    if probe.lightInk ? luma > 150 : luma < 115 { ink += 1 }
                }
            }
        }
        return Frame(t: t, window: window, top: CGFloat(top) / scale, bottom: CGFloat(bottom + 1) / scale,
                     cutBottom: cutBottom, cutTop: cutTop, ink: ink, image: keepImage ? image : nil)
    }

    // MARK: Evidence

    /// Each switch as a row of frames at fixed times, so a reviewer can see
    /// the motion the numbers describe.
    private static func writeStrips(_ strips: [(String, [Frame])], to directory: String) {
        let times: [TimeInterval] = [0, 0.03, 0.06, 0.09, 0.12, 0.16, 0.22, 0.3, 0.5]
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, frames) in strips {
            let picked = times.compactMap { t in frames.min { abs($0.t - t) < abs($1.t - t) } }
            let images = picked.compactMap(\.image)
            guard let first = images.first else { continue }
            let cellW = first.width, cellH = images.map(\.height).max() ?? first.height
            let gap = 12
            let width = images.count * cellW + (images.count - 1) * gap
            guard let context = CGContext(data: nil, width: width, height: cellH, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(CGColor(gray: 0.55, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: cellH))
            for (index, image) in images.enumerated() {
                let x = index * (cellW + gap)
                // Hung from the top, as on screen.
                context.draw(image, in: CGRect(x: x, y: cellH - image.height, width: image.width, height: image.height))
            }
            guard let strip = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: strip).representation(using: .png, properties: [:]) else { continue }
            let file = name.replacingOccurrences(of: " \u{2192} ", with: "-to-").lowercased() + ".png"
            try? png.write(to: url.appendingPathComponent(file))
        }
        print("filmstrips written to \(directory) (frames at \(times.map { "\(Int($0 * 1000))" }.joined(separator: ", "))ms)")
    }

    // MARK: Fixture

    private static func demoDeps() -> CardDeps {
        let store = UsageStore(providers: [ClaudeProvider(allowRemote: false), CodexProvider(allowRemote: false)])
        store.usages = Snapshot.demoUsages()
        store.lastRefresh = Date().addingTimeInterval(-32)
        let sessions = SessionStore()
        sessions.sessions = Snapshot.demoSessions()
        sessions.lastScan = Date().addingTimeInterval(-4)
        let clipboard = ClipboardStore()
        clipboard.items = Snapshot.demoClipboardItems()
        let focus = FocusStore(persists: false)
        Snapshot.seedDemoFocus(into: focus)
        let system = SystemMonitor.shared
        system.applyDemo(SystemDemo.make())
        return CardDeps(store: store, sessionStore: sessions, clipboard: clipboard, focus: focus, system: system,
                        backpack: BackpackManager.shared, pages: PopoverPageModel())
    }
}
