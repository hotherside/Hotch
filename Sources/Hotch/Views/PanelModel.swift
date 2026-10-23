import AppKit
import SwiftUI

/// The panel's sections, in tab and swipe order (Hotch 2).
///
/// **Now** is home: one glance at the AI limits, the agents and the Mac. The
/// others are depth on demand. Usage and forecast became one section (AI), the
/// forecast drawn onto the rings themselves; sessions became Agents; This Mac
/// is new.
enum PanelPage: Int, CaseIterable, Sendable {
    case now
    case ai
    case agents
    case mac
    case focus
    case clipboard

    var title: String {
        switch self {
        case .now: return "Now"
        case .ai: return "AI"
        case .agents: return "Sessions"
        case .mac: return "Mac"
        case .focus: return "Focus"
        case .clipboard: return "Clipboard"
        }
    }

    /// The longer name the left wing uses.
    var wingTitle: String {
        switch self {
        case .now: return "Now"
        case .ai: return "AI usage"
        case .agents: return "Active sessions"
        case .mac: return "This Mac"
        case .focus: return "Focus"
        case .clipboard: return "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .now: return "gauge.with.dots.needle.67percent"
        case .ai: return "sparkles"
        case .agents: return "terminal"
        case .mac: return "cpu"
        case .focus: return "timer"
        case .clipboard: return "list.clipboard"
        }
    }

    /// Height of this section's content in the notch panel, between the tab row
    /// and the footer. **A property of the section, never of the data**: five
    /// sessions or six providers scroll inside it rather than stretching the
    /// panel. Only This Mac is taller, because a grid of six live charts is
    /// worth the room; switching to and from it is the one time the shape's
    /// bottom edge moves, and it moves on the same spring as everything else.
    var panelContentHeight: CGFloat {
        switch self {
        case .now, .ai: return 248
        case .agents: return 262
        case .mac: return 322
        case .focus: return 158
        case .clipboard: return 204
        }
    }

    /// Parses `--snapshot-page` and keeps the old names working.
    init?(argument: String) {
        switch argument {
        case "now", "home": self = .now
        case "ai", "usage", "forecast": self = .ai
        case "agents", "sessions": self = .agents
        case "mac", "system": self = .mac
        case "focus": self = .focus
        case "clipboard", "clip": self = .clipboard
        default: return nil
        }
    }
}

/// True only while `ImageRenderer` is drawing a view for a snapshot.
///
/// The renderer has a short list of things it cannot rasterise, and every one
/// of them has cost this project a blank or garbled PNG: `Material` renders as
/// nothing, `ScrollView` never runs its layout pass, and an editable
/// `TextField` comes out as a yellow bar with a "no entry" sign through it.
/// Where a stand-in reproduces what the live surface looks like before anyone
/// touches it, the render is still worth having — so the affected views ask
/// for this and draw the stand-in instead.
private struct SnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotRendering: Bool {
        get { self[SnapshotRenderingKey.self] }
        set { self[SnapshotRenderingKey.self] = newValue }
    }
}

/// Presentation state shared between the AppKit panel and the SwiftUI content.
@MainActor
final class PanelModel: ObservableObject {
    @Published var expanded: Bool = false
    @Published var notchWidth: CGFloat = NotchGeometryResolver.virtualNotchWidth
    @Published var notchHeight: CGFloat = 32
    @Published var panelWidth: CGFloat = NotchGeometryResolver.minPanelWidth

    /// Width of the panel's **visible body** — the window less the concave
    /// flare on each side.
    ///
    /// `panelWidth` is the window; this is the black shape inside it. The
    /// distinction already existed for padding (`contentMargin`), and treating
    /// it as *only* a padding concern is what let a page draw outside the
    /// panel: the pager was laid out and clipped to the full window width, so
    /// mid-slide the incoming page swept through the 10pt flare margins and
    /// painted over the wallpaper down both edges of the panel.
    ///
    /// The pager is laid out in this width instead, and the interaction
    /// window's hosting view is inset to match — so the escape is impossible at
    /// the AppKit level rather than merely masked at the SwiftUI level. That
    /// last part matters: a SwiftUI `ScrollView` is bridged to a real
    /// `NSScrollView`, and an ancestor `.clipShape` does not mask it at all.
    var bodyWidth: CGFloat { max(0, panelWidth - NotchTheme.topFlare * 2) }
    /// Visible height of the panel body, measured from the top of the screen.
    ///
    /// **One height for every page.** Each page was briefly sized to its own
    /// content, which was wrong twice over: the panel visibly grew and shrank
    /// mid-swipe, and the two pages on screen during a slide disagreed about
    /// where the bottom edge was, so one of them drew its footer across the
    /// other's content. A paged surface has to be one container that the pages
    /// move through — the container cannot resize because of what is inside it.
    /// So this is the tallest page, settled once per placement, and shorter
    /// pages simply have room to spare.
    @Published var panelHeight: CGFloat = NotchGeometryResolver.virtualClearance
        + NotchGeometryResolver.contentHeight
    /// Black strip reserved before content, matching the notch on real hardware
    /// and staying small on a virtual notch.
    @Published var contentClearance: CGFloat = NotchGeometryResolver.virtualClearance

    /// Which page is showing. Sticky across open and close on purpose: someone
    /// keeping an eye on a session re-opens to the page they were watching.
    @Published var page: PanelPage = .now

    /// The This Mac tile opened in place, if any.
    @Published var macDetail: SystemDetailKind?

    /// True while the Backpack mode card is showing in place of the section.
    @Published var backpackCard: Bool = false

    /// Fixed rows of the Hotch 2 panel, measured below the clearance strip.
    nonisolated static var tabRowHeight: CGFloat { PanelMetrics.tabRowHeight }
    nonisolated static var footerHeight: CGFloat { PanelMetrics.footerHeight }

    /// The section the shape is currently sized for.
    var contentHeight: CGFloat {
        backpackCard ? PanelPage.now.panelContentHeight : page.panelContentHeight
    }

    /// Visible body height for the current section, from the top of the screen.
    var visibleBodyHeight: CGFloat {
        contentClearance + PanelModel.tabRowHeight + contentHeight + PanelModel.footerHeight
    }

    /// Visible shape height for the current section, including the overflow.
    var visibleShapeHeight: CGFloat { topOverflow + visibleBodyHeight }

    /// The tallest any section can make the panel; the windows are this tall
    /// and the shape inside them is as tall as the section asks.
    nonisolated static var maxContentHeight: CGFloat { PanelMetrics.maxContentHeight }

    /// True while a text field on the focus page holds the caret.
    ///
    /// The panel is a hover surface: it closes 160ms after the pointer leaves.
    /// That is right for reading and wrong for typing — hands go to the
    /// keyboard and the mouse stays where it was, or drifts. While this is set
    /// the window controller refuses to collapse, so a task name survives being
    /// typed. It is on the model rather than inside the view because the
    /// controller is the thing that has to obey it.
    @Published var editingTask: Bool = false

    /// The one-time first-launch line, present only while the introduction is.
    ///
    /// Nil at every other moment, and that includes every snapshot render: the
    /// window controller is the only thing that sets it, only the app delegate
    /// ever asks it to, and the render modes in `main.swift` exit before an app
    /// delegate exists. So the hint cannot turn up in a PNG that is meant to
    /// show the panel as everyone else sees it.
    @Published var revealHint: String?

    /// The panel body starts this far above the top of the screen so no sliver
    /// of wallpaper can ever show through along the top edge.
    var topOverflow: CGFloat { NotchGeometryResolver.topOverflow }
    /// Empty room below the body for the drop shadow to fall into.
    var shadowAllowance: CGFloat { NotchGeometryResolver.shadowAllowance }

    /// Height of the drawn shape, including the offscreen overflow.
    var shapeHeight: CGFloat { topOverflow + panelHeight }
    /// Height of the whole window, shape plus shadow room.
    var windowHeight: CGFloat { shapeHeight + shadowAllowance }
    /// Where panel content starts: below the offscreen overflow and the clearance.
    var contentTopInset: CGFloat { topOverflow + contentClearance }

    /// Height a page's content may occupy: the body, less the notch clearance
    /// above it and the footer band below. Pages are laid out inside this and
    /// can never reach the footer.
    var pageContentHeight: CGFloat {
        max(0, shapeHeight - contentTopInset - NotchTheme.footerBandHeight)
    }

    func apply(_ geometry: NotchGeometry) {
        notchWidth = geometry.notchRect.width
        notchHeight = geometry.notchRect.height
        contentClearance = geometry.contentClearance
        panelWidth = geometry.panelRect.width
        panelHeight = geometry.bodyHeight
    }
}

/// The fixed rows of the Hotch 2 panel, outside any actor so geometry code can
/// size windows from them.
enum PanelMetrics {
    static let tabRowHeight: CGFloat = 42
    static let footerHeight: CGFloat = 36
    static var maxContentHeight: CGFloat {
        PanelPage.allCases.map(\.panelContentHeight).max() ?? 248
    }
    /// Everything below the clearance strip at the tallest section.
    static var maxBelowStrip: CGFloat { tabRowHeight + maxContentHeight + footerHeight }
    static let panelWidth: CGFloat = 640
}

/// Every duration in the unfold **and the fold**, in one place.
///
/// These were spread across three files and had to agree without saying so. The
/// window teardown delay in particular was a literal `0.36` sitting next to a
/// 0.14s fade — harmless, but shortening the fade would have left the window
/// ordered in for a quarter second of nothing, and lengthening it past 0.36 would
/// have cut the fade off mid-flight. Anything derivable is derived now.
///
/// Tuned for "gone before you think about it" rather than for showing off the
/// animation. The panel is a glance surface: the whole interaction is over in
/// half a second, so a motion that looks elegant in isolation reads as a wait in
/// use.
///
/// Being in one file was not enough on its own. The open and the close each had
/// their own duration, and having their own duration is how they came to differ
/// by 39% and by curve family — one gesture arriving, a different one leaving.
/// So the two directions of a thing now share a *constant*, not a file:
/// `shellDuration` for the shape, `contentDuration` for anything inside it.
/// A future edit to one direction is an edit to both, by construction.
enum PanelMotion {
    // MARK: Shell

    /// How long the shell takes to move — **in both directions**.
    ///
    /// One constant, not two, and the two names below are aliases of it rather
    /// than numbers of their own. Two numbers is what let the reveal and the
    /// dismiss drift apart: the open settled over 0.26s on a spring, the close
    /// finished in 0.16s on an easeOut, and a surface people brush past dozens
    /// of times a day was arriving as one gesture and leaving as a different,
    /// unrelated one. Reported as "it feels like it closes super fast", which is
    /// exactly what a 39% shorter exit on a stiffer curve is. A dismiss is the
    /// reveal run backwards, so there has to be nothing here that can be edited
    /// on one side only.
    ///
    /// `spring(duration:bounce:)` rather than `spring(response:dampingFraction:)`
    /// on purpose: `response` is the period of one oscillation, so the real settle
    /// time is some multiple of it and every timing derived from it needed a fudge
    /// factor. `duration` *is* the settle time, which makes this number mean what
    /// it says and lets `shadowSettle` and `teardownDelay` below be honest.
    ///
    /// There are deliberately no `openDuration` / `closeDuration` aliases beside
    /// it. Two names for one number is one edit away from being two numbers
    /// again, and that is the bug.
    static let shellDuration: Double = 0.26
    /// A little overshoot reads as physical; more than this reads as a wobble on
    /// something opened dozens of times a day. Zero would be correct and lifeless.
    static let openBounce: Double = 0.12

    static var open: Animation { .spring(duration: shellDuration, bounce: openBounce) }
    /// The retraction: the same spring family as the open, and no bounce.
    ///
    /// Same family because the panel is one object, and a thing that arrives on
    /// a spring has to leave on one or it reads as two different objects sharing
    /// a silhouette. Zero bounce because the overshoot is not symmetric in
    /// meaning: on arrival it reads as a physical thing settling into place, and
    /// on departure it reads as indecision — a panel changing its mind halfway
    /// into the bezel.
    ///
    /// **This supersedes the objection recorded here when the close was 0.13s**,
    /// which rejected a bounce-free spring on the grounds that a spring leaves
    /// rest at zero velocity and so sits still for the first frames — the same
    /// charge that still rules out `easeIn` on the shape. It was right about the
    /// physics and wrong about the consequence, and it was wrong because of the
    /// duration it was written against: a gentle start is a large fraction of
    /// eight frames and a small one of sixteen. Sampled frame by frame at 0.26s,
    /// the retraction carries the panel's bottom edge 8.6pt in the first frame
    /// and 26.7pt within two — against 8.8pt and 28.0pt for the open, which is
    /// the whole point. The old easeOut moved 23.0pt in its first frame, and
    /// that is the snap this replaces. `easeIn` stays rejected: its slow start
    /// is a *proportion of the whole* rather than one frame of ease, so it holds
    /// the panel at full size and then throws it away.
    static var close: Animation { .spring(duration: shellDuration, bounce: 0) }
    /// The fade, deliberately on the opposite curve to the retraction.
    ///
    /// Both used to run on `close`. An easeOut fade spends most of its alpha in
    /// the first few frames, so the panel was already transparent while the shape
    /// was still most of the way open: what you saw was a blink, and the retract
    /// into the notch — the whole point of scaling from the notch's own
    /// dimensions — happened to something you could no longer see. easeIn holds
    /// the panel visible through the shrink and takes the last of it exactly as
    /// the shape reaches the notch, where near-black on the bezel means there is
    /// nothing left to disappear. That reasoning is unchanged; only the number
    /// it runs against is.
    ///
    /// Same duration as the retraction, so `teardownDelay` still has one number
    /// to derive from — and so the alpha reaches zero exactly at `shellDuration`,
    /// which is what makes "the panel is gone" a time anyone can compute.
    static var closeFade: Animation { .easeIn(duration: shellDuration) }

    // MARK: Content

    /// How long one element takes to arrive **or** leave. One number, for the
    /// reason `shellDuration` is one number.
    ///
    /// The exit was 0.09 against a 0.16 entrance and carried no stagger at all,
    /// so the rows did not leave the way they arrived — they blinked out
    /// together, well before the shell that was still retracting behind them.
    /// Two layers each exiting faster than they entered, on unrelated curves, is
    /// the whole of "it closes super fast".
    static let contentDuration: Double = 0.16
    /// Per-row offset for the cascade. Small on purpose: at the old 35ms the
    /// sixth provider's row did not begin arriving until 215ms in, so the more
    /// providers someone enabled the slower the panel felt.
    static let rowStagger: Double = 0.018
    static let rowLead: Double = 0.02
    /// Inner elements, staggered behind their row.
    static let brandLead: Double = 0.03
    static let statLead: Double = 0.05
    static let footerLead: Double = 0.08
    /// The ring's draw-in. The signature motion, so it keeps the longest
    /// duration of anything here — but 0.40s meant the number beside it had
    /// settled long before the arc caught up.
    static let ringSweep: Double = 0.28

    static func rowIn(_ index: Int) -> Animation {
        .easeOut(duration: contentDuration).delay(rowLead + Double(index) * rowStagger)
    }

    /// The exit cascade: the entrance wave, read from the other end.
    ///
    /// Same leads and the same duration, so the two directions span the same
    /// time — but the last row leaves first and the first row leaves last,
    /// because the shell is not symmetric. It grows *downward* out of the notch
    /// and retracts *upward* into it, so the entrance cascade chases the bottom
    /// edge on its way down and the exit has to chase it on its way back up.
    ///
    /// That is not only a nicety. Content lives in its own window and is never
    /// scaled — it only fades — so as the shell retracts it uncovers the rows
    /// from the bottom up, and for a few frames a row can be sitting over the
    /// desktop rather than over the panel. Leaving in entrance order maximises
    /// that: the top row, still covered, goes first while the bottom row, about
    /// to be uncovered, is at full alpha. Reversed, the rows that get uncovered
    /// first are the rows that have already faded.
    ///
    /// `count` rather than a fixed depth because the reversal needs to know
    /// where the end is; every page already has it to hand.
    static func rowOut(_ index: Int, of count: Int) -> Animation {
        .easeOut(duration: contentDuration)
            .delay(rowLead + Double(max(0, count - 1 - index)) * rowStagger)
    }

    /// The wings, level with the notch, are the last thing to go: they are
    /// already standing where the shape is headed.
    static var wingsOut: Animation { .easeOut(duration: contentDuration).delay(footerLead) }
    /// The footer, furthest from the notch, is the first: same rule as the rows,
    /// applied to the one strip that is not one.
    static var footerOut: Animation { .easeOut(duration: contentDuration) }

    static func contentIn(after delay: Double) -> Animation {
        .easeOut(duration: contentDuration).delay(delay)
    }

    // MARK: Pages

    /// The slide between pages. A spring for the same reason the unfold is one:
    /// the panel reads as a physical thing, and a page swipe is the one gesture
    /// where the hand expects the surface to carry its momentum. Slightly
    /// quicker than the unfold — the panel is already open, so there is less to
    /// believe in.
    static let pageDuration: Double = 0.24
    static var pageChange: Animation { .spring(duration: pageDuration, bounce: 0.10) }

    // MARK: Window lifecycle

    /// When the window may be ordered out after a collapse. Derived, so it can
    /// never fall short of the animation it is waiting for — and `close` and
    /// `closeFade` share `shellDuration` precisely so that there is still a
    /// single animation for it to be derived from.
    ///
    /// The slack covers the content as well as the shell. The exit cascade ends
    /// at `rowLead + (rows - 1) * rowStagger + contentDuration`, which is 198ms
    /// for the two-row home page and 270ms for six providers — inside this even
    /// at the wide end, so no row is ever cut off by the window going away
    /// underneath it. A collapsed panel still leaves nothing on screen: the fade
    /// reaches zero at `shellDuration` and the order-out only makes it official.
    static var teardownDelay: Double { shellDuration + 0.06 }
    /// When to recompute the shaped shadow after opening. The window server
    /// derives it from the opaque pixels, which keep moving until the unfold has
    /// settled, plus a frame for the overshoot to come back.
    static var shadowSettle: Double { shellDuration + 0.05 }
}

/// The notch panel is an opaque near black slab whose top strip stays pure black
/// so it melts into the physical bezel. This is the one place in the app that
/// ignores light and dark theming.
enum NotchTheme {
    /// Lifted across the board.
    ///
    /// The first pass tuned every secondary tone down until the panel was
    /// tasteful and, on a bezel-black surface at a glance, flat — captions at
    /// 35% white are legible in a screenshot and vanish in peripheral vision,
    /// which is the only way this thing is ever read. Everything below the
    /// headline moved up roughly ten points, and the tracks with them so the
    /// unfilled part of a gauge still reads as a track.
    static let primaryText = Color.white
    static let unitText = Color.white.opacity(0.68)
    static let captionText = Color.white.opacity(0.52)
    static let subText = Color.white.opacity(0.58)
    static let mutedText = Color.white.opacity(0.48)
    static let footerText = Color.white.opacity(0.52)
    static let ringTrack = Color.white.opacity(0.16)
    static let ringTrackDim = Color.white.opacity(0.11)
    static let divider = Color.white.opacity(0.10)

    static let rowHeight: CGFloat = 56
    static let ringSize: CGFloat = 38
    static let ringLineWidth: CGFloat = 3.5
    static let leadingColumnWidth: CGFloat = 118

    /// Session rows are denser than provider rows — two lines of text, a
    /// context gauge and a status — so they earn a shorter slot.
    static let sessionRowHeight: CGFloat = 44
    static let sessionRowGap: CGFloat = 4

    /// The per-session context ring. Roughly half the usage ring: it is the
    /// same instrument reporting a smaller thing, and drawing it at full size
    /// would put five of them on one page competing with the two that measure
    /// the subscription.
    static let contextRingSize: CGFloat = 20
    static let contextRingLineWidth: CGFloat = 2.5
    /// Width reserved for the ring and its two lines of figures, so the column
    /// lines up down the page whether a row reads "8%" or "100%".
    ///
    /// Sized off the widest caption the column can hold — "178.4k used" — not
    /// off the percentage above it. At 78 the ring and the percentage fit
    /// comfortably and every token line in the page rendered as "178.4k…",
    /// which is the one part of the caption that carries no information.
    static let contextColumnWidth: CGFloat = 98

    /// Width reserved for the status word and its age.
    ///
    /// Fixed for the same reason the context column is, and it is the half that
    /// was actually broken: the status block is right-aligned against the
    /// margin, so with an intrinsic width every row set its own left edge —
    /// "needs input" is far wider than "ended", and the gauge beside it moved
    /// forty points between one row and the next. Two columns of instruments
    /// that do not line up down the page read as a list that has come loose,
    /// which is exactly what it looked like. Sized for "needs input", the
    /// longest state there is.
    static let sessionStatusColumnWidth: CGFloat = 82

    /// One provider's block on the forecast page: a single row carrying every
    /// window side by side, then the verdict beneath it.
    ///
    /// The windows were stacked vertically at first, which made a two-window
    /// provider 68pt tall and the whole page taller than the usage page it sits
    /// beside — and since every page now shares one height, the forecast page
    /// was setting the height of all three. Side by side is also the layout the
    /// usage page already uses for its two gauges, so the two pages read as the
    /// same information rather than two different documents.
    static let forecastWindowRowHeight: CGFloat = 26
    static let forecastCaptionGap: CGFloat = 3
    static let forecastCaptionHeight: CGFloat = 15
    static var forecastBlockHeight: CGFloat {
        forecastWindowRowHeight + forecastCaptionGap + forecastCaptionHeight
    }

    /// Reserved strip along the bottom of every page for the footer line: the
    /// page dots, the status stamp and the settings gear.
    ///
    /// Explicit, and subtracted from the content area rather than overlaid on
    /// its padding. Overlaying is what put the forecast page's last caption
    /// underneath the "updated 32s ago" stamp: the content believed it owned
    /// the full body and the footer drew on top of it anyway.
    static let footerBandHeight: CGFloat = 26

    /// The needs-input accent, shared by the sessions page and the menu bar
    /// dot. Amber, not the warning red: a session waiting on a keystroke is a
    /// nudge, and red is reserved for a window that is nearly spent.
    ///
    /// Dynamic, because the same amber that glows on near-black is nearly
    /// unreadable on white — the light side takes a deep amber instead.
    static let attention = Dynamic.color(dark: Dynamic.rgb(1.0, 0.72, 0.30),
                                         light: Dynamic.rgb(0.68, 0.40, 0.02))

    /// Page indicator dots. Sized to be clicked, not merely seen — these are
    /// the only page navigation for anyone not swiping, and 4.5pt in a 14pt
    /// slot was a target you had to aim at.
    static let pageDotSize: CGFloat = 7
    /// Hit slot per dot. The visible gap comes from the slot being wider than
    /// the dot, so the targets touch and there is nowhere between them to miss.
    static let pageDotSlot: CGFloat = 20
    static let pageDotGap: CGFloat = 0
    /// Half the dot cluster plus breathing room, which is the space either
    /// footer caption has to keep clear of the centre.
    static var footerCentreClearance: CGFloat {
        CGFloat(PanelPage.allCases.count) * pageDotSlot / 2 + 14
    }

    /// Below this the reserved top strip is a seam-hider, not a shelf, and the
    /// wings stay empty. Real notch hardware reserves its own height (32pt on a
    /// 14" MacBook Pro); a screen without one keeps a 12pt token strip.
    static let wingMinimumHeight: CGFloat = 24

    /// Clipboard rows: a one-line preview and an age, denser than sessions.
    static let clipboardRowHeight: CGFloat = 34
    static let clipboardRowGap: CGFloat = 3

    /// The focus page: a donut with the clock in its centre, the task name as
    /// the headline beside it, plus the log line. The donut is sized for a
    /// number to live inside it; the height is the content block alone, and
    /// page chrome is added where every other page adds it.
    static let focusRingSize: CGFloat = 68
    static let focusContentHeight: CGFloat = 86

    /// Horizontal margin, measured from the panel's **visible** edge.
    ///
    /// Load-bearing distinction. The body's sides sit `topFlare` inside the window
    /// frame — that gap is what the concave corner flare is — so padding applied to
    /// the content lands 10pt further out than the number suggests. Rows were at 20
    /// and the two footer lines at 22, which on screen was 10 and 12: barely a
    /// margin, unequal, and the reason the brand column read as shoved against the
    /// left wall.
    static let contentInset: CGFloat = 22
    /// What to actually pass to `.padding(.horizontal:)`, so every element lines up
    /// on the same visible margin whatever the flare is set to.
    static var contentMargin: CGFloat { topFlare + contentInset }

    /// Padding above the row stack. There is no matching bottom value any more:
    /// the space under the content is `footerBandHeight`, which the content is
    /// laid out to exclude rather than to share.
    static let rowStackTopPadding: CGFloat = 10
    /// Centre of the footer line above the panel's bottom edge.
    static var footerCentre: CGFloat { footerBandHeight / 2 }
    /// At or above this much consumed, a meter abandons its brand colour for the
    /// system warning red. The complement of the 15%-left threshold this replaced.
    static let highConsumedThreshold: Double = 85

    /// Opaque near black body, in the NotchNook idiom. No translucency: the
    /// panel has to read as an extension of the bezel, not as a floating window.
    static let bodyTop = Color(red: 0x07 / 255, green: 0x07 / 255, blue: 0x07 / 255)
    static let bodyBottom = Color(red: 0x04 / 255, green: 0x04 / 255, blue: 0x04 / 255)

    /// Outward flare where the panel meets the top edge of the screen.
    static let topFlare: CGFloat = 10
    static let bottomCornerRadius: CGFloat = 24
}

// MARK: - Reading a window in the user's chosen direction

/// Resolving a window for display, kept here rather than on `UsageWindow` so the
/// provider layer stays free of presentation concerns — the same reason
/// staleness is derived in the views.
extension UsageWindow {
    /// The number to print, in whichever direction the user chose.
    func percent(_ mode: UsageDisplayMode) -> Double? {
        guard let consumedPercent else { return nil }
        return mode == .used ? consumedPercent : 100 - consumedPercent
    }

    /// The share of the ring or bar to paint. Derived from `percent` and never
    /// computed separately, so the arc and the number cannot end up describing
    /// opposite things.
    func fillShare(_ mode: UsageDisplayMode) -> Double? {
        percent(mode).map { min(1, max(0, $0 / 100)) }
    }

    /// Past the warning line.
    ///
    /// Deliberately keyed to consumption in both modes: 8% remaining and 92% used
    /// are the same window in the same trouble. Thresholding the *displayed*
    /// number instead would turn the warning off in Remaining mode exactly when it
    /// mattered, and on when it did not.
    var isCritical: Bool {
        guard let consumedPercent else { return false }
        return consumedPercent >= NotchTheme.highConsumedThreshold
    }
}

/// A session's context window, read exactly the way a plan window is.
///
/// Deliberately the same four members as the `UsageWindow` extension above, and
/// deliberately not shared with it: a `UsageWindow` is a percentage a vendor
/// reports, this is a pair of token counts, and forcing one into the other's
/// shape would mean inventing a label and a reset time for something that has
/// neither. What has to match is the *reading* — same direction preference,
/// same warning threshold — and that is what these four lines guarantee.
extension AgentSession {
    /// Share of the window consumed, 0...100. Clamped, because a vendor's own
    /// accounting can momentarily exceed its stated ceiling and a ring past
    /// full says nothing a full ring does not.
    var contextConsumedPercent: Double? {
        guard let contextTokens, let contextLimit, contextLimit > 0 else { return nil }
        return min(100, max(0, Double(contextTokens) / Double(contextLimit) * 100))
    }

    /// The number to print, in whichever direction the user chose.
    func contextPercent(_ mode: UsageDisplayMode) -> Double? {
        guard let contextConsumedPercent else { return nil }
        return mode == .used ? contextConsumedPercent : 100 - contextConsumedPercent
    }

    /// The share of the ring to paint, derived from `contextPercent` so the arc
    /// and the number cannot describe opposite things.
    func contextFillShare(_ mode: UsageDisplayMode) -> Double? {
        contextPercent(mode).map { min(1, max(0, $0 / 100)) }
    }

    /// The token count under the percentage, in the same direction: "78k used"
    /// against "122k left". The percentage says how much of the window is gone;
    /// this says how much window that actually is, which is the difference
    /// between a 200k session and a 1M one reading identically.
    func contextTokenCaption(_ mode: UsageDisplayMode) -> String? {
        guard let contextTokens, let contextLimit, contextLimit > 0 else { return nil }
        let shown = mode == .used ? contextTokens : max(0, contextLimit - contextTokens)
        return "\(Fmt.tokens(shown)) \(mode.unit)"
    }

    /// Past the warning line — keyed to consumption in both modes, for the same
    /// reason `UsageWindow.isCritical` is: a window this full is in the same
    /// trouble however the user has asked to read it. Here it also has a
    /// concrete meaning, since a session near its ceiling is about to compact.
    var contextIsCritical: Bool {
        guard let contextConsumedPercent else { return false }
        return contextConsumedPercent >= NotchTheme.highConsumedThreshold
    }
}

/// The display mode, handed down the view tree rather than threaded through every
/// initialiser. The two view roots read `AppSettings` and publish it here, so a
/// change in settings re-renders both surfaces with no plumbing in between.
private struct UsageDisplayModeKey: EnvironmentKey {
    static let defaultValue: UsageDisplayMode = .used
}

extension EnvironmentValues {
    var usageDisplayMode: UsageDisplayMode {
        get { self[UsageDisplayModeKey.self] }
        set { self[UsageDisplayModeKey.self] = newValue }
    }
}

/// A colour that resolves against the *view's* appearance rather than a value
/// threaded through every initialiser.
///
/// Needed once the popover started following the system: the panel forces
/// `darkAqua` on its own windows, so it keeps the canonical brand colours,
/// while the same view code in a light popover needs darker ones. An
/// `NSColor(name:dynamicProvider:)` answers per appearance, so one definition
/// covers both surfaces and nothing has to know which it is drawing into.
enum Dynamic {
    static func color(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// Relative luminance, for deciding whether a brand colour would vanish
    /// against white.
    static func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

/// Brand identity lives on the UI side, keyed by provider id, so the provider
/// protocol stays free of presentation concerns.
struct ProviderIdentity {
    var red: Double
    var green: Double
    var blue: Double
    var mark: BrandMarkKind

    /// Optional explicit far end for gradients. Defaults to a lighter accent.
    var highlightOverride: (red: Double, green: Double, blue: Double)?

    /// What to use where the background is light.
    ///
    /// Load-bearing for the monochrome brands. xAI and Moonshot both brand in
    /// black and white, which on the near-black panel means *white* — and white
    /// on a light popover is nothing at all. Without an override those two rows
    /// would render as blank space with a percentage floating beside them.
    /// Brands that already carry enough colour (Anthropic clay, DeepSeek blue)
    /// keep their canonical value in both.
    var lightOverride: (red: Double, green: Double, blue: Double)?

    /// The light-side colour: the explicit override, or the brand darkened
    /// enough to read when it is too pale to survive on white.
    private var lightRGB: (red: Double, green: Double, blue: Double) {
        if let lightOverride { return lightOverride }
        guard Dynamic.luminance(red, green, blue) > 0.62 else { return (red, green, blue) }
        let factor = 0.22
        return (red * factor, green * factor, blue * factor)
    }

    var accent: Color {
        Dynamic.color(dark: Dynamic.rgb(red, green, blue),
                      light: Dynamic.rgb(lightRGB.red, lightRGB.green, lightRGB.blue))
    }

    /// The far end of meter gradients, roughly 20 percent lighter unless the
    /// brand specifies its own tint. On the light side the gradient runs the
    /// other way — toward a deeper tone — since "lighter" there means "closer
    /// to the background".
    var highlight: Color {
        let darkEnd: (Double, Double, Double) = highlightOverride.map { ($0.red, $0.green, $0.blue) }
            ?? (min(1, red + 0.2), min(1, green + 0.2), min(1, blue + 0.2))
        let base = lightRGB
        let lightEnd = (base.red * 0.72, base.green * 0.72, base.blue * 0.72)
        return Dynamic.color(dark: Dynamic.rgb(darkEnd.0, darkEnd.1, darkEnd.2),
                             light: Dynamic.rgb(lightEnd.0, lightEnd.1, lightEnd.2))
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [accent, highlight], startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    static func identity(for providerID: String) -> ProviderIdentity {
        switch providerID {
        case "claude":
            // Anthropic clay, lifted from #D97757 to #F0865F. The canonical
            // swatch is tuned for white paper; on a near-black panel the same
            // value sits back into the surface instead of coming off it, so
            // every brand here is brightened a step for the dark side while
            // the light side keeps the value the vendor publishes.
            return ProviderIdentity(red: 0xF0 / 255, green: 0x86 / 255, blue: 0x5F / 255,
                                    mark: .claude,
                                    lightOverride: (0xC9 / 255, 0x62 / 255, 0x42 / 255))
        case "codex":
            // Indigo periwinkle, lifted from #7A7DFF to #969AFF for the dark
            // side; deepened on light backgrounds, where the periwinkle is
            // legible but thin.
            return ProviderIdentity(red: 0x96 / 255, green: 0x9A / 255, blue: 0xFF / 255,
                                    mark: .openAI,
                                    highlightOverride: (0xBF / 255, 0xC1 / 255, 0xFF / 255),
                                    lightOverride: (0x4B / 255, 0x4E / 255, 0xD6 / 255))
        case "gemini":
            // simple-icons Gemini violet #8E75B2, lifted toward the blue end
            return ProviderIdentity(red: 0xAC / 255, green: 0x92 / 255, blue: 0xD8 / 255,
                                    mark: .gemini,
                                    highlightOverride: (0xC9 / 255, 0xB6 / 255, 0xF2 / 255),
                                    lightOverride: (0x74 / 255, 0x5B / 255, 0x9C / 255))
        case "grok":
            // xAI brands in black and white; on this panel that means white,
            // and on a light popover it means black. Both are the brand.
            return ProviderIdentity(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255,
                                    mark: .grok,
                                    lightOverride: (0x1A / 255, 0x1A / 255, 0x1A / 255))
        case "kimi":
            // Moonshot also brands monochrome; the warm cast is what keeps it
            // apart from Grok, so it is carried into the dark light-side tone
            // rather than collapsing both to the same near-black.
            return ProviderIdentity(red: 0xF2 / 255, green: 0xEE / 255, blue: 0xE3 / 255,
                                    mark: .kimi,
                                    lightOverride: (0x33 / 255, 0x2C / 255, 0x1E / 255))
        case "deepseek":
            // DeepSeek whale blue, #5786FE
            return ProviderIdentity(red: 0x74 / 255, green: 0x9C / 255, blue: 0xFF / 255,
                                    mark: .deepseek,
                                    lightOverride: (0x3D / 255, 0x6B / 255, 0xE0 / 255))
        default:
            return ProviderIdentity(red: 0.78, green: 0.78, blue: 0.80, mark: .generic)
        }
    }

    /// Warning identity: system red with the same gradient treatment.
    static let warning = ProviderIdentity(red: 1.0, green: 0.27, blue: 0.23, mark: .generic)
}
