import SwiftUI

/// Formatting shared by the focus page and menu bar. Every clock states which
/// direction it counts; paused runs keep that direction visible too.
enum FocusDisplay {
    static let identity = ProviderIdentity(red: 0.96, green: 0.96, blue: 0.96, mark: .generic)
    static let taskPlaceholder = "Task name (optional)"
    static let emptyLogText = "No focus time yet today"
    static let openEndedTitle = "Stopwatch"
    static let customTitle = "Custom"
    static let startTitle = "Start"
    static let stopTitle = "Stop"
    static let pauseTitle = "Pause"
    static let resumeTitle = "Resume"

    /// Remaining time rounds up so a live countdown never announces zero a
    /// fraction of a second before it ends. Elapsed time counts whole seconds.
    static func clock(_ interval: TimeInterval, countdown: Bool = false) -> String {
        let safe = interval.isFinite ? min(86_400_000, max(0, interval)) : 0
        let total = Int(countdown ? ceil(safe) : floor(safe))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    @MainActor
    static func readout(_ focus: FocusStore, now: Date) -> (value: String, caption: String)? {
        if let remaining = focus.remaining(now: now) {
            return (clock(remaining, countdown: true), "remaining")
        }
        if let elapsed = focus.elapsed(now: now) {
            return (clock(elapsed), "elapsed")
        }
        return nil
    }

    @MainActor
    static func menuTitle(_ focus: FocusStore, now: Date) -> String? {
        guard let readout = readout(focus, now: now) else { return nil }
        return focus.isPaused ? "\u{23F8} \(readout.value)" : readout.value
    }

    @MainActor
    static func runCaption(_ focus: FocusStore) -> String? {
        guard focus.isRunning else { return nil }
        return focus.targetDuration.map { "\(Int($0 / 60)) min timer" } ?? "Stopwatch"
    }

    @MainActor
    static func status(_ focus: FocusStore, now: Date) -> String {
        guard let readout = readout(focus, now: now) else { return "" }
        return focus.isPaused ? "Paused · \(readout.caption)" : "Time \(readout.caption)"
    }

    @MainActor
    static func endTitle(_ focus: FocusStore) -> String {
        focus.isOpenEnded ? "Stop" : "Finish"
    }
}

private struct FocusPalette {
    var panel = false
    var primary: Color { panel ? NotchTheme.primaryText : PopoverTheme.primaryText }
    var secondary: Color { panel ? NotchTheme.captionText : PopoverTheme.secondaryText }
    var fill: Color { panel ? .white.opacity(0.09) : PopoverTheme.selection.opacity(0.65) }
    var border: Color { panel ? .white.opacity(0.18) : .primary.opacity(0.15) }
    var selected: Color { panel ? .white.opacity(0.22) : .accentColor.opacity(0.16) }
    var selectedBorder: Color { panel ? .white.opacity(0.6) : .accentColor.opacity(0.7) }
}

/// Native text fields get matching stand-ins in snapshot mode, where
/// ImageRenderer cannot draw editable AppKit controls.
private struct FocusTaskField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let palette: FocusPalette
    var onSubmit: () -> Void
    @Environment(\.snapshotRendering) private var snapshotting

    var body: some View {
        Group {
            if snapshotting {
                Text(text.isEmpty ? FocusDisplay.taskPlaceholder : text)
                    .foregroundStyle(text.isEmpty ? palette.secondary : palette.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(FocusDisplay.taskPlaceholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .onSubmit(onSubmit)
                    .accessibilityLabel("Task name, optional")
            }
        }
        .font(.system(size: palette.panel ? 11 : 13))
        .foregroundStyle(palette.primary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: palette.panel ? 25 : 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(focus.wrappedValue ? palette.selectedBorder : palette.border, lineWidth: 0.75))
    }
}

private struct FocusChoice: View {
    let title: String
    var selected = false
    let palette: FocusPalette
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: palette.panel ? 10.5 : 11.5, weight: .semibold))
                .foregroundStyle(palette.primary)
                .padding(.horizontal, palette.panel ? 8 : 9)
                .frame(height: palette.panel ? 23 : 29)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? palette.selected : palette.fill))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? palette.selectedBorder : palette.border, lineWidth: 0.75))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing(radius: 6))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct FocusModePicker: View {
    @Binding var mode: FocusSetup.Mode
    let palette: FocusPalette

    var body: some View {
        HStack(spacing: 3) {
            ForEach(FocusSetup.Mode.allCases, id: \.self) { choice in
                FocusChoice(title: choice.rawValue, selected: mode == choice, palette: palette) {
                    mode = choice
                }
                .accessibilityHint(choice == .timer ? "Counts down for a set duration" : "Counts up until stopped")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus mode")
    }
}

private struct FocusDurationRow: View {
    @Binding var setup: FocusSetup
    var focus: FocusState<Bool>.Binding
    let palette: FocusPalette
    var onSubmit: () -> Void
    @Environment(\.snapshotRendering) private var snapshotting

    var body: some View {
        HStack(spacing: palette.panel ? 4 : 5) {
            ForEach(FocusSetup.durations, id: \.self) { minutes in
                FocusChoice(title: palette.panel ? "\(minutes)m" : "\(minutes) min",
                            selected: setup.duration == .minutes(minutes), palette: palette) {
                    setup.duration = .minutes(minutes)
                    focus.wrappedValue = false
                }
                .accessibilityLabel("\(minutes) minutes")
            }
            FocusChoice(title: "Custom", selected: setup.duration == .custom, palette: palette) {
                setup.duration = .custom
                focus.wrappedValue = true
            }
            if setup.duration == .custom {
                HStack(spacing: 3) {
                    Group {
                        if snapshotting {
                            Text(setup.customText.isEmpty ? "min" : setup.customText)
                        } else {
                            TextField("min", text: $setup.customText)
                                .textFieldStyle(.plain)
                                .focused(focus)
                                .onSubmit(onSubmit)
                                .onAppear { focus.wrappedValue = true }
                                .onChange(of: setup.customText) { _, value in
                                    let digits = String(value.filter(\.isNumber).prefix(3))
                                    if digits != value { setup.customText = digits }
                                }
                        }
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.primary)
                    .frame(width: 34, height: palette.panel ? 23 : 29)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.fill))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border, lineWidth: 0.75))
                    .accessibilityLabel("Custom duration in minutes")
                    .accessibilityHint("Enter 1 to 600 minutes")
                    .help("Enter 1–600 minutes")
                    Text("min").font(.system(size: 10)).foregroundStyle(palette.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timer duration")
    }
}

private struct FocusAction: View {
    let title: String
    let symbol: String
    let palette: FocusPalette
    var prominent = false
    var disabled = false
    var expands = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: palette.panel ? 11 : 12, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(prominent && !disabled
                    ? (palette.panel ? Color.black : Color.white) : palette.primary)
                .padding(.horizontal, palette.panel ? 9 : 13)
                .frame(maxWidth: expands ? .infinity : nil)
                .frame(height: palette.panel ? 25 : 34)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(prominent && !disabled
                        ? (palette.panel ? Color.white : Color.accentColor) : palette.fill))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(prominent && !disabled ? .clear : palette.border, lineWidth: 0.75))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing(radius: 7))
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

private struct FocusRunControls: View {
    @ObservedObject var focus: FocusStore
    let now: Date
    let palette: FocusPalette

    var body: some View {
        HStack(spacing: 7) {
            FocusAction(title: focus.isPaused ? "Resume" : "Pause",
                        symbol: focus.isPaused ? "play.fill" : "pause.fill",
                        palette: palette, prominent: true, expands: !palette.panel) {
                if focus.isPaused { focus.resumeRun(now: now) }
                else { focus.pause(now: now) }
            }
            FocusAction(title: FocusDisplay.endTitle(focus), symbol: "stop.fill",
                        palette: palette, expands: !palette.panel) {
                focus.stop(now: now)
            }
            .accessibilityHint("Saves the time measured so far to today’s history")
        }
    }
}

// MARK: - Expanded notch

struct FocusPageContent: View {
    @ObservedObject var focus: FocusStore
    let now: Date
    let active: Bool
    var onEditingChanged: (Bool) -> Void = { _ in }
    @FocusState private var taskFocused: Bool
    @FocusState private var customFocused: Bool
    private let palette = FocusPalette(panel: true)

    var body: some View {
        Group {
            if focus.isRunning { running }
            else { setup }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: NotchTheme.focusContentHeight)
        .onChange(of: taskFocused) { _, _ in reportEditing() }
        .onChange(of: customFocused) { _, _ in reportEditing() }
        .onDisappear { onEditingChanged(false) }
        .onExitCommand { taskFocused = false; customFocused = false }
        .opacity(active ? 1 : 0)
        .offset(y: active || HMotion.reduceMotion ? 0 : -4)
        .animation(HMotion.reduceMotion ? nil : (active ? PanelMotion.rowIn(0) : PanelMotion.rowOut(0, of: 1)), value: active)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                FocusTaskField(text: $focus.draftTitle, focus: $taskFocused, palette: palette, onSubmit: start)
                FocusAction(title: "Start", symbol: "play.fill", palette: palette,
                            prominent: true, disabled: focus.setup.decision == .refuse, action: start)
            }
            HStack {
                FocusModePicker(mode: $focus.setup.mode, palette: palette)
                Spacer(minLength: 8)
                Text("Today · \(Fmt.duration(focus.todayTotal))")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            if focus.setup.mode == .timer {
                FocusDurationRow(setup: $focus.setup, focus: $customFocused, palette: palette, onSubmit: start)
            } else {
                Text("Counts up until you stop · 4-hour limit")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                    .frame(height: 23, alignment: .leading)
            }
        }
    }

    private var running: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(FocusDisplay.readout(focus, now: now)?.value ?? "0:00")
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(FocusDisplay.status(focus, now: now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
            .frame(minWidth: 112, alignment: .leading)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 7) {
                Text(focus.runningLabel ?? FocusEntry.untitled)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                Text(FocusDisplay.runCaption(focus) ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
                FocusRunControls(focus: focus, now: now, palette: palette)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func reportEditing() { onEditingChanged(taskFocused || customFocused) }
    private func start() {
        guard case let .start(minutes) = focus.setup.decision else { customFocused = true; return }
        focus.start(minutes: minutes, now: now)
        taskFocused = false
        customFocused = false
    }
}

// MARK: - Compact card and menu bar popover

struct PopoverFocusSection: View {
    @ObservedObject var focus: FocusStore
    let now: Date
    @FocusState private var taskFocused: Bool
    @FocusState private var customFocused: Bool
    @State private var historyExpanded = false
    private let palette = FocusPalette()
    private static let historyDepth = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if focus.isRunning { running }
            else { setup }
            Divider()
            history
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand { taskFocused = false; customFocused = false }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            FocusModePicker(mode: $focus.setup.mode, palette: palette)
            FocusTaskField(text: $focus.draftTitle, focus: $taskFocused, palette: palette, onSubmit: start)
            if focus.setup.mode == .timer {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Duration")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondary)
                    FocusDurationRow(setup: $focus.setup, focus: $customFocused, palette: palette, onSubmit: start)
                    if focus.setup.duration == .custom && focus.setup.decision == .refuse {
                        Text("Enter 1–600 minutes")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondary)
                    }
                }
            } else {
                Text("Counts up until you stop. Stops automatically after 4 hours.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FocusAction(title: focus.setup.mode == .timer ? "Start timer" : "Start stopwatch",
                        symbol: "play.fill", palette: palette, prominent: true,
                        disabled: focus.setup.decision == .refuse, expands: true, action: start)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(FocusDisplay.runCaption(focus) ?? "Focus")
                Spacer()
                if focus.isPaused { Label("Paused", systemImage: "pause.fill") }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(FocusDisplay.readout(focus, now: now)?.value ?? "0:00")
                    .font(.system(size: 43, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(focus.isOpenEnded ? "Time elapsed" : "Time remaining")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Focus clock")
            .accessibilityValue("\(FocusDisplay.readout(focus, now: now)?.value ?? "0:00") \(focus.isOpenEnded ? "elapsed" : "remaining"), \(focus.isPaused ? "paused" : "running")")

            Text(focus.runningLabel ?? FocusEntry.untitled)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = focus.progress(now: now) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(PopoverTheme.track)
                        Capsule().fill(Color.accentColor)
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }
            FocusRunControls(focus: focus, now: now, palette: palette)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                historyExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("Today")
                    Spacer()
                    Text("\(Fmt.duration(focus.todayTotal)) focused")
                        .monospacedDigit()
                    Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(KeyboardFocusRing(radius: 4))
            .accessibilityLabel("Today's focus history")
            .accessibilityValue("\(Fmt.duration(focus.todayTotal)) focused, \(historyExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Show or hide finished sessions")

            if historyExpanded {
                if focus.finishedEntries.isEmpty {
                    Text(focus.isRunning ? "Your current session will appear here when it ends." : FocusDisplay.emptyLogText)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondary)
                }
                ForEach(Array(focus.finishedEntries.reversed().prefix(Self.historyDepth)), id: \.id) { entry in
                    historyRow(entry)
                }
                if focus.finishedEntries.count > Self.historyDepth {
                    Text("\(focus.finishedEntries.count - Self.historyDepth) earlier sessions included in today’s total")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondary)
                }
            }
        }
    }

    private func historyRow(_ entry: FocusEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                Text(Fmt.clockTime(entry.startedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 4)
            Text(Fmt.duration(entry.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(palette.secondary)
                .fixedSize()
            // Starting another session also finishes the current one. Keep
            // history informational while a clock is active to prevent that
            // surprising side effect from an innocent history click.
            if !focus.isRunning {
                Button(entry.isContinuable ? "Continue" : "Again") {
                    focus.resume(entry, now: now)
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("\(entry.isContinuable ? "Continue" : "Repeat") \(entry.displayTitle)")
                .help(entry.isContinuable ? "Continue from \(Fmt.duration(entry.duration))" : "Start a new session with the same duration")
            }
        }
    }

    private func start() {
        guard case let .start(minutes) = focus.setup.decision else { customFocused = true; return }
        focus.start(minutes: minutes, now: now)
        taskFocused = false
        customFocused = false
    }
}
