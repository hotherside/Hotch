import SwiftUI

/// The focus page: what you are working on, how long for, and today's total.
///
/// **The task is the headline; the clock follows it.** While a timer runs, the
/// biggest thing on the page is the name of the work — the clock lives in the
/// centre of the donut, where a progress number belongs. An earlier version led
/// with the clock and printed the task underneath in caption grey, which had
/// the hierarchy exactly backwards: the name is why the timer exists.
///
/// **Starting is a button, not a side effect.** Length pills used to start the
/// timer the moment one was tapped, which meant the page had no visible verb —
/// nothing said *go*. Now the pills select and a solid Start commits, the same
/// select-then-confirm shape as every timer people already know. Return in the
/// task field also starts, with whatever length is selected — and with nothing
/// selected it deliberately does not, which happens exactly once per install
/// (see `FocusMemory`).
///
/// **The run appears in the log the moment it starts.** The popover's list
/// leads with the live row, ticking, carrying Pause and Stop; the donut keeps
/// the clock. The notch panel keeps its tally column and shows only runs that
/// have ended — the one in progress is already the whole left half of that
/// page, and counting it twice on an 86pt surface would read as two runs.
enum FocusDisplay {
    /// Focus wears its own white identity rather than a vendor's clay or
    /// indigo: this is the user's time, not a provider's.
    static let identity = ProviderIdentity(red: 0.96, green: 0.96, blue: 0.96, mark: .generic)

    /// "24:12", or "1:24:12" once it needs an hour column — a clock face, not a
    /// duration phrase. This number is watched, and "24m 12s" flickers its
    /// width as it counts.
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// The donut's centre: "24:12" under an hour, "1h 24m" over it. Seconds
    /// stop mattering past an hour, and "1:24" alone is ambiguous between a
    /// minute and an hour.
    static func donutClock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        if total >= 3600 {
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The running readout: the number, and the words that say what it is
    /// counting. Without them "12:47" is ambiguous between time served and time
    /// left, which is exactly the confusion this page had. Still used by the
    /// menu bar title, which has no donut to disambiguate for it.
    @MainActor
    static func readout(_ focus: FocusStore, now: Date) -> (value: String, caption: String)? {
        if let remaining = focus.remaining(now: now) {
            let total = focus.targetDuration.map { " of \(Int($0 / 60))m" } ?? ""
            return (clock(remaining), "left\(total)")
        }
        if focus.isOpenEnded, let elapsed = focus.elapsed(now: now) {
            return (clock(elapsed), "so far")
        }
        return nil
    }

    /// One word inside the donut, under the number. A paused clock says so —
    /// a frozen number with a live-sounding caption reads as a hung app.
    @MainActor
    static func donut(_ focus: FocusStore, now: Date) -> (value: String, caption: String)? {
        if let remaining = focus.remaining(now: now) {
            return (donutClock(remaining), focus.isPaused ? "paused" : "left")
        }
        if focus.isOpenEnded, let elapsed = focus.elapsed(now: now) {
            return (donutClock(elapsed), focus.isPaused ? "paused" : "so far")
        }
        return nil
    }

    /// The menu bar's slot: the clock, with a pause mark while frozen so a
    /// static number up there reads as paused rather than stuck.
    @MainActor
    static func menuTitle(_ focus: FocusStore, now: Date) -> String? {
        guard let readout = readout(focus, now: now) else { return nil }
        return focus.isPaused ? "\u{23F8} \(readout.value)" : readout.value
    }

    /// The line under the running task name, naming the deal that was struck.
    @MainActor
    static func runCaption(_ focus: FocusStore) -> String? {
        guard focus.isRunning else { return nil }
        if let target = focus.targetDuration { return "\(Int(target / 60))m timer" }
        return "runs until you stop it"
    }

    static let taskPlaceholder = "What are you working on?"
    static let emptyLogText = "No focus time logged today"
    /// Plain words for a run with no set length. Not "count up", which
    /// describes the arithmetic rather than the deal being struck.
    static let openEndedTitle = "Until I stop"
    static let customTitle = "Custom"
    static let lengthPrompt = "FOR HOW LONG"
    /// Shown once, ever: the state of a store that has never been told a
    /// length. Quiet, because it is an instruction rather than an error.
    static let lengthHint = "pick a length"
    static let startTitle = "Start"
    /// **Not "Stop & log".** The line is written when the run starts now, so
    /// there is nothing left for the verb to promise: the row is already on
    /// screen, ticking, above this button. A control that says it will log
    /// something that is already logged is describing an older version of the
    /// app.
    static let stopTitle = "Stop"
    static let pauseTitle = "Pause"
    static let resumeTitle = "Resume"
}

// MARK: - The donut

/// Progress ring with the number in the middle — the shape people already read
/// as "a timer". Anti-clockwise, like every other gauge in the app. A run with
/// no set length gets the bare track around its clock: no target means no
/// denominator, and a fill without one would be decoration pretending to be a
/// reading — the same rule the prepaid-credit rows follow on the usage page.
private struct FocusDonut: View {
    /// Elapsed share, 0...1. Nil draws the bare track.
    let progress: Double?
    let value: String
    let caption: String
    var size: CGFloat
    var track: Color
    var fill: Color
    var valueColour: Color
    var captionColour: Color

    private var lineWidth: CGFloat { max(4, size * 0.075) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: lineWidth)

            if let progress {
                Circle()
                    // Trim the tail of the path: the arc ends at twelve o'clock
                    // and grows backwards — anti-clockwise — matching RingGauge.
                    .trim(from: 1 - min(1, max(0, progress)), to: 1)
                    .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: size * 0.21, weight: .semibold, design: .rounded)
                        .monospacedDigit())
                    .foregroundStyle(valueColour)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.system(size: size * 0.115, weight: .medium))
                    .foregroundStyle(captionColour)
            }
            .frame(width: size - lineWidth * 4)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Shared control styling

private struct FocusPillStyle {
    var accent: Color
    var fill: Color
    var stroke: Color
    /// Panel pills stay compact; popover pills follow the popover's larger
    /// type scale, because the popover is a widget, not a bezel.
    var fontSize: CGFloat = 10.5
    var hPad: CGFloat = 8
    var vPad: CGFloat = 4

    static let panel = FocusPillStyle(accent: NotchTheme.primaryText,
                                      fill: Color.white.opacity(0.10),
                                      stroke: Color.white.opacity(0.16))
    static let panelSelected = FocusPillStyle(accent: NotchTheme.primaryText,
                                              fill: Color.white.opacity(0.26),
                                              stroke: Color.white.opacity(0.6))
    static let popover = FocusPillStyle(accent: PopoverTheme.primaryText,
                                        fill: PopoverTheme.selection,
                                        stroke: Color.primary.opacity(0.12),
                                        fontSize: PopoverTheme.bodySize,
                                        hPad: 10, vPad: 5)
    static let popoverSelected = FocusPillStyle(accent: PopoverTheme.primaryText,
                                                fill: Color.accentColor.opacity(0.22),
                                                stroke: Color.accentColor.opacity(0.7),
                                                fontSize: PopoverTheme.bodySize,
                                                hPad: 10, vPad: 5)

    func accented(_ colour: Color) -> FocusPillStyle {
        var copy = self
        copy.accent = colour
        return copy
    }
}

private struct FocusPill: View {
    let title: String
    var style: FocusPillStyle
    var bold: Bool = false
    /// True for pills carrying a task name: the text truncates when the caller
    /// caps the width from outside, instead of pushing the layout. The
    /// fixed-vocabulary length pills stay `fixedSize`.
    var truncates: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: style.fontSize, weight: bold ? .bold : .semibold))
                .foregroundStyle(style.accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(PillWidth(truncates: truncates))
                .padding(.horizontal, style.hPad)
                .padding(.vertical, style.vPad)
                .background(
                    Capsule(style: .continuous)
                        .fill(style.fill)
                        .overlay(Capsule(style: .continuous).strokeBorder(style.stroke, lineWidth: 0.75))
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private struct PillWidth: ViewModifier {
        var truncates: Bool

        func body(content: Content) -> some View {
            if truncates {
                content
            } else {
                content.fixedSize()
            }
        }
    }
}

/// The task field, or a picture of it.
///
/// `ImageRenderer` cannot draw an editable field, so a snapshot of this page
/// would otherwise be a yellow bar. The stand-in is the same box with the same
/// text in it, which is exactly what the live field shows before it is typed
/// into — the state a render is checking anyway.
private struct TaskField: View {
    @Binding var text: String
    /// Passed in rather than owned. `.focused` only binds when it is applied to
    /// the field itself — put on a wrapper it is silently ignored, which leaves
    /// the caret working and every *reaction* to the caret dead: no highlight,
    /// and nothing telling the window controller to stay open.
    var focus: FocusState<Bool>.Binding
    var textColour: Color
    var placeholderColour: Color
    var fill: Color
    var stroke: Color
    var verticalPadding: CGFloat
    var fontSize: CGFloat = 12.5
    var onSubmit: () -> Void

    @Environment(\.snapshotRendering) private var snapshotting

    var body: some View {
        Group {
            if snapshotting {
                Text(text.isEmpty ? FocusDisplay.taskPlaceholder : text)
                    .foregroundStyle(text.isEmpty ? placeholderColour : textColour)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(FocusDisplay.taskPlaceholder, text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(textColour)
                    .focused(focus)
                    .onSubmit(onSubmit)
            }
        }
        .font(.system(size: fontSize, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 0.75)
                )
        )
    }
}

/// The typed custom length. A field rather than a stepper: someone who wants
/// 90 minutes wants to type 90, not press a button six times.
private struct MinutesField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var fieldFill: Color
    var fieldStroke: Color
    var textColour: Color
    var captionColour: Color
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("30", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(textColour)
                .focused(focus)
                .frame(width: 38)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fieldFill)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(fieldStroke, lineWidth: 0.75))
                )
                .onSubmit(onSubmit)
                // Digits only, filtered as it is typed rather than rejected
                // afterwards with an error nobody asked for.
                .onChange(of: text) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(3))
                    if digits != new { text = digits }
                }
                .onAppear { focus.wrappedValue = true }

            Text("minutes")
                .font(.system(size: 9.5))
                .foregroundStyle(captionColour)
        }
    }
}

// MARK: - Panel page

struct FocusPageContent: View {
    @ObservedObject var focus: FocusStore
    let now: Date
    let active: Bool
    /// Reported to the window controller: a panel with a caret in it must not
    /// close because the pointer wandered off on the way to the keyboard.
    var onEditingChanged: (Bool) -> Void = { _ in }

    @FocusState private var taskFocused: Bool
    @FocusState private var customFocused: Bool
    /// **Nil is a real state, and it is the honest one on a fresh install.**
    /// This used to be `= .openEnded`, which pre-selected "Until I stop" on
    /// every launch and re-selected it on every rebuild of the view. See
    /// `FocusMemory` for why a remembered choice is not the same thing as a
    /// default: the value here comes from what this Mac has been told, and when
    /// it has been told nothing it stays empty rather than answering for
    /// somebody.
    @State private var length: LengthChoice?
    @State private var customText = ""
    /// The task name the selection above was resolved for, so typing does not
    /// re-resolve — and therefore cannot overwrite — a length chosen by hand.
    @State private var resolvedFor: String?
    /// Set when Start or Return was pressed with nothing selected. The hint is
    /// already on screen; this is what makes it the loudest thing on the page
    /// for the one moment it matters.
    @State private var nudge = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if focus.isRunning {
                runningBody
            } else {
                idleBody
            }

            Spacer(minLength: 8)

            todayColumn
        }
        .frame(height: NotchTheme.focusContentHeight)
        // Either caret counts as editing; the custom field takes it the moment
        // it appears.
        .onChange(of: taskFocused) { _, _ in reportEditing() }
        .onChange(of: customFocused) { _, _ in reportEditing() }
        .onAppear { resolveLength(initial: true) }
        .onChange(of: focus.draftTitle) { _, _ in resolveLength(initial: false) }
        // Escape backs out, which is the one keyboard gesture people try
        // without being told.
        .onExitCommand {
            taskFocused = false
            customFocused = false
        }
        .opacity(active ? 1 : 0)
        .offset(y: active ? 0 : -4)
        .animation(active ? PanelMotion.rowIn(0) : PanelMotion.rowOut(0, of: 1),
                   value: active)
    }

    private func reportEditing() {
        onEditingChanged(taskFocused || customFocused)
    }

    /// Per task name first, then the last length used at all, then nothing.
    private func resolveLength(initial: Bool) {
        let key = FocusStore.clean(focus.draftTitle)
        guard initial || key != resolvedFor else { return }
        resolvedFor = key
        if let remembered = focus.memory.habit(for: key)?.length {
            apply(remembered)
        } else if length == nil, let last = focus.memory.lastLength {
            apply(last)
        }
    }

    private func apply(_ memory: LengthMemory) {
        length = memory.choice
        if let text = memory.customText { customText = text }
        nudge = false
    }

    // MARK: Idle

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                TaskField(text: $focus.draftTitle,
                          focus: $taskFocused,
                          textColour: NotchTheme.primaryText,
                          placeholderColour: NotchTheme.mutedText,
                          fill: Color.white.opacity(0.08),
                          stroke: taskFocused ? FocusDisplay.identity.accent.opacity(0.55)
                                              : Color.white.opacity(0.14),
                          verticalPadding: 5,
                          onSubmit: startNow)
                startButton
            }
            lengthRow
            if length == .custom {
                MinutesField(text: $customText,
                             focus: $customFocused,
                             fieldFill: Color.white.opacity(0.10),
                             fieldStroke: Color.white.opacity(0.22),
                             textColour: NotchTheme.primaryText,
                             captionColour: NotchTheme.mutedText,
                             onSubmit: startNow)
            } else if length == nil {
                // The one-per-install state. It shares the optional third row
                // with the custom field and the resume pill because a store
                // with no remembered length has no runs to resume either.
                Text(FocusDisplay.lengthHint)
                    .font(.system(size: 10))
                    .foregroundStyle(nudge ? NotchTheme.attention : NotchTheme.mutedText)
                    .lineLimit(1)
            } else if let last = focus.finishedEntries.last {
                // The most recent *finished* task, one tap from continuing. It
                // shares the custom field's row: both are the optional third
                // line, and the page never needs both at once. The verb lives
                // inside the pill — a caption beside a width-capped frame
                // floats away from a short title, because `frame(maxWidth:)` is
                // greedy.
                FocusPill(title: last.isContinuable
                              ? "\u{21BB} Resume \u{00B7} \(last.displayTitle)"
                              : "\u{21BB} Again \u{00B7} \(last.displayTitle)",
                          style: .panel,
                          truncates: true) {
                    focus.resume(last, now: now)
                }
                .frame(maxWidth: 280, alignment: .leading)
            }
        }
    }

    /// The one solid control on the page: the verb. Everything else selects.
    ///
    /// **The disabled state changes colours rather than fading the button.** It
    /// used to be `.opacity(0.35)` over the whole control, which is fine for a
    /// single-layer button and wrong for this one: the label is black on a white
    /// capsule, so fading the composite pulled the white down toward the panel's
    /// near-black *and* the black label up toward it, meeting in the middle. The
    /// result read as an empty pill — a button with no word on it, which is a
    /// worse thing to show than a dim one, because the user cannot tell whether
    /// it is disabled or broken. Disabled is now a ghost capsule with a legible
    /// muted label: still obviously not the live control, still obviously
    /// "Start".
    private var startButton: some View {
        Button(action: startNow) {
            Text(FocusDisplay.startTitle)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(startDisabled ? NotchTheme.mutedText
                                               : Color.black.opacity(0.85))
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(startDisabled ? Color.white.opacity(0.08)
                                            : Color.white.opacity(0.92))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(startDisabled ? Color.white.opacity(0.16) : .clear,
                                      lineWidth: 0.75)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(startDisabled)
    }

    private var startDisabled: Bool {
        FocusStore.decide(length: length, custom: customText) == .refuse
    }

    private var lengthRow: some View {
        HStack(spacing: 5) {
            ForEach(FocusStore.lengthChoices, id: \.self) { minutes in
                choicePill("\(minutes)m", .minutes(minutes))
            }
            choicePill(FocusDisplay.customTitle, .custom)
            // A hair of air before the answer with no number in it.
            Color.clear.frame(width: 3, height: 1)
            choicePill(FocusDisplay.openEndedTitle, .openEnded)
        }
        .fixedSize()
    }

    private func choicePill(_ title: String, _ choice: LengthChoice) -> some View {
        FocusPill(title: title,
                  style: length == choice ? .panelSelected : .panel) {
            length = choice
            nudge = false
        }
    }

    // MARK: Running

    private var runningBody: some View {
        HStack(alignment: .center, spacing: 14) {
            if let donut = FocusDisplay.donut(focus, now: now) {
                FocusDonut(progress: focus.progress(now: now),
                           value: donut.value,
                           caption: donut.caption,
                           size: NotchTheme.focusRingSize,
                           track: focus.isOpenEnded ? NotchTheme.ringTrackDim
                                                    : NotchTheme.ringTrack,
                           fill: FocusDisplay.identity.accent,
                           valueColour: NotchTheme.primaryText,
                           captionColour: NotchTheme.mutedText)
            }

            VStack(alignment: .leading, spacing: 6) {
                // The task is the headline. The clock is in the donut, where a
                // progress number belongs.
                Text(focus.runningLabel ?? FocusEntry.untitled)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(NotchTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let caption = FocusDisplay.runCaption(focus) {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.captionText)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    // Pause first: it is the reversible one, and the one a
                    // ringing phone reaches for. Resume gets the brighter
                    // treatment because a paused page's job is to be resumed.
                    if focus.isPaused {
                        FocusPill(title: FocusDisplay.resumeTitle,
                                  style: .panelSelected,
                                  bold: true) {
                            focus.resumeRun(now: now)
                        }
                    } else {
                        FocusPill(title: FocusDisplay.pauseTitle, style: .panel) {
                            focus.pause(now: now)
                        }
                    }
                    FocusPill(title: FocusDisplay.stopTitle,
                              style: FocusPillStyle.panel.accented(NotchTheme.attention),
                              bold: true) {
                        focus.stop(now: now)
                    }
                }
            }
        }
    }

    private func startNow() {
        guard case let .start(minutes) = FocusStore.decide(length: length, custom: customText) else {
            // Nothing selected. The panel has no room for a sentence, so the
            // hint on the third row goes bright instead.
            nudge = true
            return
        }
        focus.start(minutes: minutes, now: now)
        taskFocused = false
        customFocused = false
    }

    /// Today's finished runs as tick marks, newest last — a tally, not a table.
    /// The names live in the popover's list, which has the width for them.
    ///
    /// Deliberately the *finished* ones. The run in progress is the donut, the
    /// clock and the headline filling the rest of this page; giving it a tally
    /// mark here as well would put the same run on the surface twice, and the
    /// mark would grow while the reader watched, which reads as a second run
    /// appearing. The popover's list does show it — there the live row is the
    /// run, and there is nothing else on the page claiming to be.
    private var todayColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("TODAY")
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(NotchTheme.mutedText)
            HStack(spacing: 4) {
                if focus.finishedEntries.isEmpty {
                    Rectangle()
                        .fill(NotchTheme.ringTrackDim)
                        .frame(width: 14, height: 3)
                }
                ForEach(Array(focus.finishedEntries.suffix(6).enumerated()), id: \.offset) { _, entry in
                    // Width scales with length, so a 50m block reads as twice
                    // a 25m one without an axis.
                    Capsule()
                        .fill(FocusDisplay.identity.accent.opacity(0.75))
                        .frame(width: max(6, min(34, CGFloat(entry.duration / 60) * 0.5)),
                               height: 3)
                }
            }
            // An em dash, not "0s". Zero seconds is a measurement; nothing
            // logged yet is an absence, and printing a number for it invites
            // the reader to check what it counted.
            Text(focus.finishedEntries.isEmpty ? "\u{2014}" : Fmt.duration(focus.finishedTotal))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(focus.finishedEntries.isEmpty ? NotchTheme.mutedText
                                                               : NotchTheme.primaryText)
        }
        .frame(width: 88, alignment: .trailing)
    }
}

// MARK: - Run marker

/// The mark that says which row is the one running.
///
/// A ring rather than a dot, thickened to nearly solid while live, so it reads
/// as the same object in both states instead of two different marks. Reserved
/// on every row and drawn on one, which is what keeps the names on a single
/// left edge whether or not a timer is going.
private struct RunDot: View {
    var live: Bool = false
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .strokeBorder(PopoverTheme.mutedText.opacity(live ? 0.9 : 0.5),
                          lineWidth: live ? 3 : 1.2)
            .frame(width: size, height: size)
            // Fixed on both axes: this is the one element in a row that must
            // not move when the name beside it is long.
            .frame(width: size + 3, height: size + 3)
    }
}

// MARK: - Popover section

/// The same sentence, on the surface with room to spell it out.
///
/// *What are you working on, for how long* — and then a named log of the day,
/// which is the part the notch panel has no room for. The panel is a glance
/// surface a pointer is passing over: it shows the clock, a row of tally marks
/// and the total, and names there would be detail nobody stopped to read.
struct PopoverFocusSection: View {
    @ObservedObject var focus: FocusStore
    let now: Date

    @FocusState private var taskFocused: Bool
    @FocusState private var customFocused: Bool
    /// See `FocusPageContent.length`: nil is the fresh-install state, not a
    /// missing value. The hardcoded `.openEnded` that used to live here is the
    /// bug this page was redesigned around.
    @State private var length: LengthChoice?
    @State private var customText = ""
    @State private var resolvedFor: String?
    @State private var nudge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if focus.isRunning {
                running
            } else {
                idle
            }

            Rectangle().fill(PopoverTheme.divider).frame(height: 1)

            log
        }
        .onAppear { resolveSelection(initial: true) }
        .onChange(of: focus.draftTitle) { _, _ in resolveSelection(initial: false) }
        .onExitCommand {
            taskFocused = false
            customFocused = false
        }
    }

    // MARK: What the start row is currently proposing

    /// Per task name, then the last length used at all, then nothing at all.
    /// Only re-run when the *name* changes, so a length picked by hand survives
    /// the next keystroke.
    private func resolveSelection(initial: Bool) {
        let key = FocusStore.clean(focus.draftTitle)
        guard initial || key != resolvedFor else { return }
        resolvedFor = key

        if let habit = focus.memory.habit(for: key) {
            if let remembered = habit.length {
                apply(remembered)
            } else if length == nil, let last = focus.memory.lastLength {
                apply(last)
            }
        } else if length == nil, let last = focus.memory.lastLength {
            apply(last)
        }
    }

    private func apply(_ memory: LengthMemory) {
        length = memory.choice
        if let text = memory.customText { customText = text }
        nudge = false
    }

    // MARK: Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                TaskField(text: $focus.draftTitle,
                          focus: $taskFocused,
                          textColour: PopoverTheme.primaryText,
                          placeholderColour: PopoverTheme.mutedText,
                          fill: PopoverTheme.selection.opacity(0.6),
                          stroke: taskFocused ? Color.accentColor.opacity(0.7)
                                              : Color.primary.opacity(0.12),
                          verticalPadding: 8,
                          fontSize: 13.5,
                          onSubmit: startNow)

                Button(FocusDisplay.startTitle, action: startNow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(startDisabled)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(FocusDisplay.lengthPrompt)
                        .font(.system(size: PopoverTheme.microSize, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(PopoverTheme.mutedText)
                    if length == nil {
                        Text(FocusDisplay.lengthHint)
                            .font(.system(size: PopoverTheme.captionSize))
                            .foregroundStyle(nudge ? Color.accentColor : PopoverTheme.mutedText)
                            .lineLimit(1)
                    }
                }

                lengthRows

                if length == .custom {
                    MinutesField(text: $customText,
                                 focus: $customFocused,
                                 fieldFill: PopoverTheme.selection,
                                 fieldStroke: Color.primary.opacity(0.15),
                                 textColour: PopoverTheme.primaryText,
                                 captionColour: PopoverTheme.mutedText,
                                 onSubmit: startNow)
                }
            }
        }
    }

    /// The six lengths, on two rows: the four with numbers on them, then the
    /// two answers made of words.
    ///
    /// One row was what the popover's old 460 was partly paying for — the six
    /// measure about 353pt and the content column is 348 now, so they no longer
    /// seat. The split is not the arithmetic one: 4+2 sorts them by *kind*, so
    /// the row of numbers reads as a scale you pick a point on and "Custom /
    /// Until I stop" reads as the two ways of declining to. A 3+3 split divides
    /// the scale in half and puts 60m next to two things that are not lengths at
    /// all, which is a straighter edge and a worse sentence.
    ///
    /// Still six buttons in the same order in the same container, so Tab still
    /// walks them 15m → Until I stop and every pill still has its own hit
    /// rectangle. Nothing about what they do changed.
    private var lengthRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                ForEach(FocusStore.lengthChoices, id: \.self) { minutes in
                    choicePill("\(minutes)m", .minutes(minutes))
                }
            }
            HStack(spacing: 5) {
                choicePill(FocusDisplay.customTitle, .custom)
                choicePill(FocusDisplay.openEndedTitle, .openEnded)
            }
        }
    }

    private var startDisabled: Bool {
        FocusStore.decide(length: length, custom: customText) == .refuse
    }

    private func choicePill(_ title: String, _ choice: LengthChoice) -> some View {
        FocusPill(title: title,
                  style: length == choice ? .popoverSelected : .popover) {
            length = choice
            nudge = false
        }
    }

    // MARK: Running

    @ViewBuilder
    private var running: some View {
        HStack(alignment: .center, spacing: 15) {
            if let donut = FocusDisplay.donut(focus, now: now) {
                FocusDonut(progress: focus.progress(now: now),
                           value: donut.value,
                           caption: donut.caption,
                           size: 82,
                           track: PopoverTheme.track,
                           fill: Color.primary.opacity(0.8),
                           valueColour: PopoverTheme.primaryText,
                           captionColour: PopoverTheme.mutedText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(focus.runningLabel ?? FocusEntry.untitled)
                    .font(.system(size: PopoverTheme.heroSize, weight: .bold))
                    .foregroundStyle(PopoverTheme.primaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)

                if let caption = FocusDisplay.runCaption(focus) {
                    Text(caption)
                        .font(.system(size: PopoverTheme.captionSize))
                        .foregroundStyle(PopoverTheme.mutedText)
                }
                // Pause and Stop are not here any more: the run has a row in
                // the log below, and the row is the run. Two sets of controls
                // for one timer, eight points apart, was the page asking twice.
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Log

    /// Rows only need a leading mark while something is running — it is there
    /// to say *which* row that is. Reserved for every row at once, so the names
    /// stay on one left edge instead of shifting when a timer starts.
    private var showsDots: Bool { focus.isRunning }

    /// How many rows the log will draw before it stops.
    ///
    /// **This list used to have no cap at all** — the notch panel's `suffix(6)`
    /// is its tally marks, not this — so a long day grew the popover without
    /// limit and a genuinely busy one could run it off the bottom of a small
    /// screen. Ten is chosen against the page it has to fit inside: at 380 the
    /// focus page with a full log measures about 490pt, still shorter than the
    /// usage page's 625, so the tallest thing the popover can be is not this.
    ///
    /// No ScrollView. A scroller inside a popover is a second thing to scroll
    /// in a surface the pointer is already swiping between pages, and half a
    /// row peeking under a fold reads as damage. Ten rows and a count of what
    /// is under them is the whole of it.
    private static let logDepth = 10

    /// Newest first, capped. `reversed()` before `prefix` so the ten kept are
    /// the ten most recent — capping the other end would show a busy day's
    /// morning and hide the run that is on screen right now.
    private var shownEntries: [FocusEntry] {
        Array(focus.todayEntries.reversed().prefix(PopoverFocusSection.logDepth))
    }

    private var hiddenCount: Int {
        max(0, focus.todayEntries.count - PopoverFocusSection.logDepth)
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(focus.summaryLine ?? FocusDisplay.emptyLogText)
                .font(.system(size: PopoverTheme.bodySize, weight: .medium))
                .foregroundStyle(PopoverTheme.secondaryText)

            // Newest first, so the run in progress is the top row. Every
            // finished line can be picked back up: a cut-short run continues
            // from its total, a finished countdown starts over at the full
            // length.
            //
            // Keyed on the entry's own id rather than its position: the list is
            // reversed and entries leave it on resume, so a positional key
            // hands the wrong row's state to the wrong row.
            ForEach(shownEntries, id: \.id) { entry in
                row(entry)
            }

            // Said only when something is actually being withheld. The summary
            // line above counts the whole day, so a cut list with no note would
            // have the total disagreeing with the rows underneath it — which is
            // the one way this page could lie.
            if hiddenCount > 0 {
                Text("\(hiddenCount) earlier today")
                    .font(.system(size: PopoverTheme.captionSize))
                    .foregroundStyle(PopoverTheme.mutedText)
            }
        }
    }

    private func row(_ entry: FocusEntry) -> some View {
        HStack(spacing: 8) {
            if showsDots { dot(entry) }

            // The name is what the row is about, so the name is what the row
            // leads with — in title type, in primary. Everything after it is
            // `fixedSize`, which is what makes the *name* the thing that
            // truncates when a row runs out of width.
            Text(entry.displayTitle)
                .font(.system(size: PopoverTheme.titleSize, weight: .semibold))
                .foregroundStyle(PopoverTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            // The timestamp moves behind the name: "when" is a detail of
            // "what".
            Text(Fmt.clockTime(entry.startedAt))
                .font(.system(size: PopoverTheme.captionSize).monospacedDigit())
                .foregroundStyle(PopoverTheme.mutedText)
                .fixedSize()

            Spacer(minLength: 6)

            Text(Fmt.duration(duration(of: entry)))
                .font(.system(size: PopoverTheme.bodySize, weight: .semibold).monospacedDigit())
                .foregroundStyle(PopoverTheme.primaryText)
                .fixedSize()
            controls(entry)
        }
    }

    /// The live row counts from the same clock the donut does, rather than from
    /// the last time the store's tick wrote it down.
    private func duration(of entry: FocusEntry) -> TimeInterval {
        guard entry.isRunning else { return entry.duration }
        return focus.elapsed(now: now) ?? entry.duration
    }

    /// The leading mark, drawn on the run in progress and reserved — blank — on
    /// every other row, so starting a timer does not shift the whole log
    /// sideways.
    private func dot(_ entry: FocusEntry) -> some View {
        RunDot(live: entry.isRunning)
            .opacity(entry.isRunning ? 1 : 0)
    }

    /// The row's own verbs. The run in progress carries Pause and Stop, because
    /// the row *is* the run; every finished row carries the one that picks it
    /// back up.
    @ViewBuilder
    private func controls(_ entry: FocusEntry) -> some View {
        if entry.isRunning {
            HStack(spacing: 4) {
                if focus.isPaused {
                    rowButton("play.circle.fill", help: FocusDisplay.resumeTitle) {
                        focus.resumeRun(now: now)
                    }
                } else {
                    rowButton("pause.circle", help: FocusDisplay.pauseTitle) {
                        focus.pause(now: now)
                    }
                }
                rowButton("stop.circle", help: FocusDisplay.stopTitle, tint: NotchTheme.attention) {
                    focus.stop(now: now)
                }
            }
            .fixedSize()
        } else {
            rowButton("play.circle",
                      help: entry.isContinuable
                          ? "Resume \u{2014} continues from \(Fmt.duration(entry.duration))"
                          : "Start this task again") {
                focus.resume(entry, now: now)
            }
        }
    }

    private func rowButton(_ symbol: String,
                           help: String,
                           tint: Color = PopoverTheme.secondaryText,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .fixedSize()
    }

    private func startNow() {
        guard case let .start(minutes) = FocusStore.decide(length: length, custom: customText) else {
            // Return with nothing selected does not start anything. It moves
            // the emphasis to the length row, which is the only thing missing.
            nudge = true
            return
        }
        focus.start(minutes: minutes, now: now)
        taskFocused = false
        customFocused = false
    }
}

