import Foundation

// MARK: - Model

/// One run of the timer, and what it was spent on.
///
/// Called an entry rather than anything cleverer. An earlier version named the
/// unit a "stint" and used the word throughout the UI, which is a writer's
/// word, not a user's — the feature is a **timer** that logs **focus time**,
/// and every label says exactly that now.
struct FocusEntry: Sendable, Hashable {
    /// Stable local identity, minted when the entry is created and restored
    /// with it. Two runs of the same task for the same length really are
    /// indistinguishable by value, and the log is drawn by a `ForEach` that
    /// has to tell them apart — the list is reversed and rows leave it on
    /// resume, so a positional key hands the wrong row's state to the wrong
    /// row. `var`, not `let`, only because a `let` with a default value is left
    /// out of the memberwise initialiser, and the loader has to be able to
    /// restore an id it read from the file.
    var id: UUID = UUID()
    var startedAt: Date
    var duration: TimeInterval
    /// What the time went on. Empty when the timer was started unnamed, which
    /// is allowed: naming the task is the point, but demanding it before the
    /// clock may start would put a form in front of a button.
    var title: String = ""
    /// The length the run was started with, nil for open-ended. Kept so a
    /// resumed task continues counting the same way it was counting — down
    /// toward the same target, or up with no target at all.
    var length: TimeInterval? = nil
    /// True for the one entry a running timer keeps at the top of the log.
    ///
    /// The log used to gain its line at stop, which is why the day's total
    /// under-reported the run you were in and why a crash cost the time. The
    /// line now exists from the moment Start is pressed and is *finished* in
    /// place, so the day's total is true at every moment and a crash costs at
    /// most one write cadence.
    var isRunning: Bool = false

    /// Never blank on screen.
    var displayTitle: String {
        title.isEmpty ? FocusEntry.untitled : title
    }

    /// True when this run can be picked back up mid-flight: a countdown that
    /// was stopped short of its target, or any open-ended run. A countdown
    /// that ran to completion has nothing left to continue — resuming one
    /// starts the same task over at the full length instead.
    var isContinuable: Bool {
        guard let length else { return true }
        return duration < length
    }

    static let untitled = "Focus time"
}

// MARK: - The length, as a selection

/// Which length is selected, before Start commits it.
///
/// Lives beside the store rather than in a view because both surfaces select
/// from the same vocabulary, and because `--check-focus` asserts what a
/// selection does — including the one that does nothing.
enum LengthChoice: Equatable, Sendable {
    case minutes(Int)
    /// The typed field. Carries no number of its own: what is typed is the
    /// number, and it is allowed to be nonsense while it is half-typed.
    case custom
    case openEnded
}

/// A remembered length: the resolved answer, with no half-typed state in it.
///
/// Separate from `LengthChoice` because a memory of "90 minutes" has to come
/// back as *Custom, pre-filled with 90*, and `.custom` alone remembers nothing.
enum LengthMemory: Equatable, Sendable {
    case minutes(Int)
    case openEnded

    /// `0` is open-ended. Zero is not a length anyone can type — the custom
    /// field's floor is one minute — so the number stays a number in the file
    /// instead of needing a second flag beside it.
    var encoded: Int {
        switch self {
        case .openEnded: return 0
        case .minutes(let value): return value
        }
    }

    static func decoded(_ raw: Int?) -> LengthMemory? {
        guard let raw else { return nil }
        guard raw > 0 else { return .openEnded }
        guard FocusStore.customMinutes.contains(raw) else { return nil }
        return .minutes(raw)
    }

    /// How the selection row should show it: a ladder pill when the number is
    /// on the ladder, otherwise the typed field with the number in it.
    var choice: LengthChoice {
        switch self {
        case .openEnded: return .openEnded
        case .minutes(let value):
            return FocusStore.lengthChoices.contains(value) ? .minutes(value) : .custom
        }
    }

    /// What to put in the custom field when this memory is applied, or nil when
    /// the memory lands on a pill instead.
    var customText: String? {
        guard case let .minutes(value) = self,
              !FocusStore.lengthChoices.contains(value) else { return nil }
        return "\(value)"
    }
}

/// Whether pressing Start (or Return) should start anything.
enum StartDecision: Equatable, Sendable {
    case start(minutes: Int?)
    /// Nothing is selected, or Custom holds something that is not a length.
    case refuse
}

/// The visible setup, shared by the card and the expanded notch page. Task
/// names never change these choices. Historical task memory remains readable
/// for compatibility with existing logs, but does not select a mode or length.
struct FocusSetup: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case timer = "Timer"
        case stopwatch = "Stopwatch"
    }

    static let durations = [15, 25, 50]
    var mode: Mode = .timer
    var duration: LengthChoice = .minutes(25)
    var customText = "25"

    var decision: StartDecision {
        mode == .stopwatch ? .start(minutes: nil)
            : FocusStore.decide(length: duration, custom: customText)
    }
}

// MARK: - What this Mac remembers about a task

/// Historical lengths retained in the on-disk format for compatibility.
/// The visible setup uses `FocusSetup`; typing a task never applies a habit.
struct FocusMemory: Sendable, Equatable {
    /// One task name and what was decided about it.
    struct Habit: Sendable, Equatable {
        var title: String
        var length: LengthMemory?
        var at: Date
    }

    /// Enough names that a real working week is covered, few enough that the
    /// file stays a file. Most recent wins when the lid comes down.
    static let taskLimit = 200

    /// Oldest first, so trimming is a `removeFirst`.
    var habits: [Habit] = []
    /// The last length started, whatever it was for. Rule 2 of the three:
    /// a habit forms without anybody configuring one.
    var lastLength: LengthMemory?

    /// Names are matched the way people retype them, which is not always with
    /// the same capitals.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    func habit(for title: String) -> Habit? {
        let key = FocusStore.clean(title)
        guard !key.isEmpty else { return nil }
        return habits.last { FocusMemory.matches($0.title, key) }
    }

    /// The three tiers, in order: this task's own last length, then the last
    /// length used at all, then nothing.
    func resolvedLength(for title: String) -> LengthMemory? {
        habit(for: title)?.length ?? lastLength
    }


    /// Records a started run. Most-recent-wins: an existing name is replaced
    /// rather than duplicated, and the list is trimmed from the oldest end.
    mutating func remember(title: String,
                           length: LengthMemory?,
                           at: Date) {
        if let length { lastLength = length }
        let key = FocusStore.clean(title)
        // An unnamed run has nothing to key on. It still moves `lastLength`,
        // because the length was a real decision even when the task was not
        // named.
        guard !key.isEmpty else { return }
        var habit = Habit(title: key, length: length, at: at)
        if let existing = habits.last(where: { FocusMemory.matches($0.title, key) }),
           habit.length == nil {
            habit.length = existing.length
        }
        habits.removeAll { FocusMemory.matches($0.title, key) }
        habits.append(habit)
        trim()
    }

    private mutating func trim() {
        guard habits.count > FocusMemory.taskLimit else { return }
        habits.removeFirst(habits.count - FocusMemory.taskLimit)
    }
}

// MARK: - Store

/// A timer or stopwatch with a durable daily log. Runs bank active time across
/// pauses and manual resumes. Relaunching restores interrupted work as finished
/// entries so no clock starts without an explicit action.
@MainActor
final class FocusStore: ObservableObject {
    /// Lengths offered as one-tap pills, in minutes.
    ///
    /// An even ladder — quarter hour, half, three quarters, hour — because a
    /// row of shortcuts should be predictable, not opinionated. The first
    /// version offered 25 and 50, which is one particular technique's numbers
    /// presented as if they were the only two lengths of time.
    nonisolated static let lengthChoices: [Int] = [15, 30, 45, 60]
    /// What a typed custom length is allowed to be. An upper bound because the
    /// readout has an hour column, not a day column.
    nonisolated static let customMinutes: ClosedRange<Int> = 1...600
    /// A run stopped before this logs nothing.
    ///
    /// One second, and it exists only to swallow a double-fire on the stop
    /// button. **It used to be two minutes**, silently — start a timer, press
    /// the button that says "Stop & log", and if you were testing it rather
    /// than living it, nothing appeared in the log and nothing said why. A
    /// control that promises to log has to log. Time you deliberately measured
    /// is yours whether or not it was long enough to impress anyone.
    static let minimumLoggable: TimeInterval = 1
    /// A run with no set length banks this much and closes itself. Open-ended
    /// has no natural end, and a forgotten one running overnight would
    /// otherwise log nine hours of "focus" that happened while asleep. A
    /// *paused* run does not advance, so the cap cannot fire on one — paused
    /// is a deliberate state, not a forgotten one.
    static let openEndedCap: TimeInterval = 4 * 3600
    /// Long enough for a real task name, short enough that the readout line
    /// stays a line.
    nonisolated static let titleLimit = 64
    /// How often a running entry's growing duration is written to disk.
    ///
    /// The UI tick is one second and the disk does not need to hear about every
    /// one of them: this file is rewritten whole, and 3,600 writes an hour to
    /// bank a number nobody has asked for yet is a laptop's battery spent on
    /// bookkeeping. Twelve seconds is the deal — a hard kill costs at most the
    /// last twelve seconds of the run, where it used to cost all of it. Every
    /// *event* (start, pause, resume, stop, finish) still writes immediately;
    /// this cadence only covers the stretch where nothing is happening except
    /// time passing.
    static let liveWriteCadence: TimeInterval = 12

    private static let fileName = "focus-log"

    /// A timer in flight, possibly across several segments.
    struct Run: Equatable, Sendable {
        /// The identity the logged line carries. The line already exists, so
        /// this is not a promise about a future row — it names the row on
        /// screen. Threaded through a resume so an entry pulled out of the log
        /// and put back is the same entry, which is what lets a queued push be
        /// replaced rather than repeated.
        var entryID: UUID = UUID()
        /// When the task was first started — survives pauses and resumes from
        /// the log, so the logged line dates the work, not the last resume.
        var startedAt: Date
        /// Nil means no set length: it runs until you stop it.
        var length: TimeInterval?
        var title: String
        /// Time served in segments that have already closed.
        var banked: TimeInterval = 0
        /// When the current segment opened. Nil while paused.
        var segmentStart: Date?
    }

    enum State: Equatable {
        case idle
        case running(Run)
    }

    @Published private(set) var state: State = .idle
    /// Today's log, newest last, **including the run in progress** while there
    /// is one. `finishedEntries` is the other half of the pair for the surfaces
    /// that only want closed runs.
    @Published private(set) var todayEntries: [FocusEntry] = []
    /// Legacy task-length memory kept compatible with existing focus logs.
    @Published private(set) var memory = FocusMemory()
    /// What is being typed into "What are you working on?".
    ///
    /// It lives here rather than in a view because both surfaces show the same
    /// field, and because the notch panel closes the moment the pointer leaves
    /// it — a half-typed task name kept in view state would evaporate on the
    /// way to the keyboard.
    @Published var draftTitle: String = ""
    @Published var setup = FocusSetup()

    /// Where the log and the memory are kept.
    ///
    /// `.memory` for `--check-focus` and the snapshot renders, whose stores run
    /// scripted scenarios. The rule, learned the hard way: the first version of
    /// the check ran against a persisting store, and every `stop()` in its
    /// scenarios **overwrote the user's real focus log** with fixture data. A
    /// verification mode must not have side effects on the thing it verifies.
    /// `.scratch` exists so the one check that has to prove the *file* format —
    /// an unclosed run loading as a finished entry — can do it without going
    /// near the support folder.
    private let file: JSONFile
    /// When the file was last written, so the live cadence can be coarse
    /// without the event writes being late.
    private var lastWrite: Date = .distantPast

    init(persists: Bool = true, file: JSONFile? = nil) {
        self.file = file ?? (persists ? .credentialStore(name: FocusStore.fileName) : .memory)
        load()
    }

    // MARK: Reading the clock

    var run: Run? {
        if case let .running(run) = state { return run }
        return nil
    }

    var isRunning: Bool { run != nil }

    /// True while the run exists but its clock is not advancing.
    var isPaused: Bool {
        guard let run else { return false }
        return run.segmentStart == nil
    }

    /// True while a run with no set length is going.
    var isOpenEnded: Bool {
        guard let run else { return false }
        return run.length == nil
    }

    /// The run's length, or nil when it has none.
    var targetDuration: TimeInterval? { run?.length }

    /// What the running timer is pointed at, never blank.
    var runningLabel: String? {
        guard let run else { return nil }
        return run.title.isEmpty ? FocusEntry.untitled : run.title
    }

    /// Time left. Nil on an open-ended run — there is nothing to count down to,
    /// and inventing one would be a lie in the loudest slot.
    func remaining(now: Date = Date()) -> TimeInterval? {
        guard let run, let length = run.length else { return nil }
        return max(0, length - served(run, now: now))
    }

    /// Time served across every segment, frozen while paused.
    func elapsed(now: Date = Date()) -> TimeInterval? {
        guard let run else { return nil }
        let raw = served(run, now: now)
        return run.length.map { min($0, raw) } ?? raw
    }

    /// Elapsed share of a set length, for the donut. Nil on an open-ended run:
    /// a gauge with no denominator has no honest fill, the same rule the credit
    /// rows follow on the usage page.
    func progress(now: Date = Date()) -> Double? {
        guard let run, let length = run.length, length > 0 else { return nil }
        return min(1, max(0, served(run, now: now) / length))
    }

    private func served(_ run: Run, now: Date) -> TimeInterval {
        let live = run.segmentStart.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return run.banked + live
    }

    // MARK: Driving it

    /// Starts a run on whatever is in `draftTitle`, and logs it immediately.
    ///
    /// `minutes` nil means no set length. Starting over a running timer
    /// finishes the old one first, so a mis-tap never silently discards
    /// counted work.
    func start(minutes: Int?, now: Date = Date()) {
        if isRunning { stop(now: now) }
        let length = minutes
            .map { min(max($0, FocusStore.customMinutes.lowerBound), FocusStore.customMinutes.upperBound) }
            .map { TimeInterval($0) * 60 }
        let title = FocusStore.clean(draftTitle)

        var run = Run(startedAt: now,
                      length: length,
                      title: title,
                      segmentStart: now)
        run.entryID = UUID()
        state = .running(run)
        todayEntries.append(liveEntry(run, now: now))
        memory.remember(title: title,
                        length: minutes.map { LengthMemory.minutes($0) } ?? .openEnded,
                        at: now)
        // The name has moved into the run; leaving it in the field would offer
        // it again as a suggestion for the next, unrelated task.
        draftTitle = ""
        write(now: now)
    }

    /// Freezes the clock without finishing anything. The run keeps its place.
    func pause(now: Date = Date()) {
        guard case var .running(run) = state, run.segmentStart != nil else { return }
        run.banked = served(run, now: now)
        run.segmentStart = nil
        state = .running(run)
        refreshLive(run, now: now)
        write(now: now)
    }

    /// Continues a paused run from exactly where it froze.
    func resumeRun(now: Date = Date()) {
        guard case var .running(run) = state, run.segmentStart == nil else { return }
        run.segmentStart = now
        state = .running(run)
        refreshLive(run, now: now)
        write(now: now)
    }

    /// Picks a stopped task back up from the log.
    ///
    /// A continuable entry is **un-banked**: it stops being a finished line and
    /// becomes the live one, its time becoming the run's opening balance, so the
    /// donut continues counting the same direction from the same number and
    /// finishing again leaves one combined line — the total stays one number
    /// rather than fragments. A countdown that already ran to completion has
    /// nothing to continue, so resuming one starts the same task over at the
    /// full length and the finished entry stays where it is.
    func resume(_ entry: FocusEntry, now: Date = Date()) {
        // The run in progress is already going. Reaching this with the live row
        // would stop and restart it, which is not what any surface means by
        // resume.
        if let run, run.entryID == entry.id { return }
        if isRunning { stop(now: now) }

        if entry.isContinuable {
            // By id, not by value: entries carry an identity now, and two runs
            // of the same task at the same length are otherwise identical.
            todayEntries.removeAll { $0.id == entry.id }
            begin(Run(entryID: entry.id,
                      startedAt: entry.startedAt,
                      length: entry.length,
                      title: entry.title,
                      banked: entry.duration,
                      segmentStart: now),
                  now: now)
        } else {
            // Starting the same task over is a *new* run with a new identity:
            // the finished line stays where it is and keeps its own.
            begin(Run(startedAt: now,
                      length: entry.length,
                      title: entry.title,
                      segmentStart: now),
                  now: now)
        }
    }

    private func begin(_ run: Run, now: Date) {
        state = .running(run)
        todayEntries.append(liveEntry(run, now: now))
        write(now: now)
    }

    /// Ends the running timer and finishes its line, paused or not.
    func stop(now: Date = Date()) {
        guard case let .running(run) = state else { return }
        state = .idle
        var done = served(run, now: now)
        if let length = run.length { done = min(length, done) }
        guard done >= FocusStore.minimumLoggable else {
            // Under the floor: the line goes away again rather than staying as
            // a row of zero.
            todayEntries.removeAll { $0.id == run.entryID }
            write(now: now)
            return
        }
        finish(run, duration: done)
    }

    /// Called from the shared UI tick. Keeps the live line's duration current,
    /// and closes a run that reached its length — in full, with no chime and no
    /// prompt, just the readout going quiet. An open-ended one only closes
    /// itself at the safety cap. A paused run does not advance, so neither can
    /// fire on one.
    func tick(now: Date = Date()) {
        guard case let .running(run) = state, run.segmentStart != nil else { return }
        let limit = run.length ?? FocusStore.openEndedCap
        guard served(run, now: now) >= limit else {
            refreshLive(run, now: now)
            // Coarse: see `liveWriteCadence`.
            write(now: now, onlyIfDue: true)
            return
        }
        state = .idle
        finish(run, duration: limit)
    }

    /// The line a running run keeps in the log.
    private func liveEntry(_ run: Run, now: Date) -> FocusEntry {
        FocusEntry(id: run.entryID,
                   startedAt: run.startedAt,
                   duration: served(run, now: now),
                   title: run.title,
                   length: run.length,
                   isRunning: true)
    }

    /// Brings the live line back in step with its run, in place.
    private func refreshLive(_ run: Run, now: Date) {
        let entry = liveEntry(run, now: now)
        if let index = todayEntries.firstIndex(where: { $0.id == run.entryID }) {
            guard todayEntries[index] != entry else { return }
            todayEntries[index] = entry
        } else {
            // The day rolled over under a running timer, or a fixture injected
            // a run without its line. Either way the run is real.
            todayEntries.append(entry)
        }
    }

    /// Closes the live line in place. Not an append: the row already exists, and
    /// appending would leave the run in the log twice.
    private func finish(_ run: Run, duration: TimeInterval) {
        var entry = liveEntry(run, now: run.startedAt)
        entry.duration = duration
        entry.isRunning = false
        if let index = todayEntries.firstIndex(where: { $0.id == run.entryID }) {
            todayEntries[index] = entry
        } else {
            todayEntries.append(entry)
        }
        write(now: Date())
    }

    /// Trimmed and capped, so a pasted paragraph cannot become a task name.
    nonisolated static func clean(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleLimit))
    }

    /// A typed custom length, or nil when what was typed is not a length.
    nonisolated static func customLength(from text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(digits), customMinutes.contains(value) else { return nil }
        return value
    }

    /// What Start (or Return in the task field) should do with a selection.
    ///
    /// A function rather than a `switch` in each of the two surfaces, so both
    /// refuse in the same cases and `--check-focus` can assert the refusal —
    /// which is the case with no pixels to look at.
    nonisolated static func decide(length: LengthChoice?, custom: String) -> StartDecision {
        switch length {
        case .none:
            return .refuse
        case .minutes(let value):
            return .start(minutes: value)
        case .custom:
            guard let value = customLength(from: custom) else { return .refuse }
            return .start(minutes: value)
        case .openEnded:
            return .start(minutes: nil)
        }
    }

    // MARK: The log

    /// Runs that have ended. The panel's tally column and every "resume the
    /// last one" affordance use this: the run in progress is not something to
    /// resume, and on the panel it is already the whole left half of the page.
    var finishedEntries: [FocusEntry] {
        todayEntries.filter { !$0.isRunning }
    }

    /// Everything measured today, the live run included. True at every moment
    /// rather than only between runs, which is the point of logging at start.
    var todayTotal: TimeInterval {
        todayEntries.reduce(0) { $0 + $1.duration }
    }

    /// The same total without the run in progress.
    var finishedTotal: TimeInterval {
        finishedEntries.reduce(0) { $0 + $1.duration }
    }

    /// "1h 15m focused today", or nil before the first run.
    ///
    /// No count noun: there is no plain word for "one run of a timer" that is
    /// not either jargon or the already-taken "session", and the tally marks
    /// beside this line show how many there were anyway.
    var summaryLine: String? {
        guard !todayEntries.isEmpty else { return nil }
        return "\(Fmt.duration(todayTotal)) focused today"
    }

    /// Snapshot fixtures only.
    func inject(state: State,
                entries: [FocusEntry],
                draft: String = "",
                memory: FocusMemory? = nil) {
        self.state = state
        self.todayEntries = entries
        self.draftTitle = draft
        if let memory { self.memory = memory }
    }

    // MARK: - Persistence

    /// Same custody as the usage history: start times, durations, the names you
    /// typed and which project they were for — nothing secret, hand-encoded so
    /// a bad file costs the log and never the launch. Days other than today are
    /// dropped on load rather than accumulated; the task memory is not, because
    /// remembering that "FRNSW DEV" is 30 minutes is the opposite of a day's
    /// worth of rows.
    private func write(now: Date, onlyIfDue: Bool = false) {
        if onlyIfDue, now.timeIntervalSince(lastWrite) < FocusStore.liveWriteCadence { return }
        lastWrite = now
        let entries: [[String: Any]] = todayEntries.map {
            var item: [String: Any] = ["id": $0.id.uuidString,
                                       "startedAt": $0.startedAt.timeIntervalSince1970,
                                       "duration": $0.duration,
                                       "title": $0.title]
            if let length = $0.length { item["length"] = length }
            // Written so a crash can be told from a clean quit on the way back
            // in — and then deliberately not honoured as "still running".
            if $0.isRunning { item["running"] = true }
            return item
        }
        file.write(["entries": entries, "memory": encodedMemory()])
    }

    private func encodedMemory() -> [String: Any] {
        var payload: [String: Any] = [
            "tasks": memory.habits.map { habit -> [String: Any] in
                var item: [String: Any] = ["title": habit.title,
                                           "at": habit.at.timeIntervalSince1970]
                if let length = habit.length { item["minutes"] = length.encoded }
                return item
            },
        ]
        if let last = memory.lastLength { payload["lastMinutes"] = last.encoded }
        return payload
    }

    private func load() {
        guard let root = file.read() else { return }
        loadMemory(root["memory"])
        // `stints` is the key this file used before the rename. Reading both
        // costs one line and saves today's tally on the upgrade; only today is
        // ever loaded, so the fallback stops mattering after one day.
        guard let items = (root["entries"] ?? root["stints"]) as? [[String: Any]] else { return }
        let calendar = Calendar.current
        todayEntries = items.compactMap { item in
            guard let start = JSONWalk.double(item["startedAt"]),
                  let duration = JSONWalk.double(item["duration"]) else { return nil }
            let startedAt = Date(timeIntervalSince1970: start)
            guard calendar.isDateInToday(startedAt) else { return nil }
            // Entries written before names and lengths existed simply have none.
            let title = (item["title"] as? String).map(FocusStore.clean) ?? ""
            // Same tolerance for the id: a line written before entries had one
            // gets a fresh id here rather than being dropped. Nothing outside
            // this file refers to it, so a new one costs nothing.
            let id = JSONWalk.string(item["id"]).flatMap(UUID.init(uuidString:)) ?? UUID()
            // A line whose run never closed — a crash, a force quit — comes
            // back as a **finished** entry of the duration it had reached.
            // Deliberately not resumed: a timer counting again because the app
            // relaunched is a timer nobody started, and the one thing worse
            // than losing twelve seconds is banking hours that happened while
            // the Mac was off. It is resumable by hand from its own row, which
            // is the same gesture as any other line.
            return FocusEntry(id: id, startedAt: startedAt, duration: duration,
                              title: title, length: JSONWalk.double(item["length"]),
                              isRunning: false)
        }
    }

    private func loadMemory(_ raw: Any?) {
        guard let root = raw as? [String: Any] else { return }
        var loaded = FocusMemory()
        loaded.lastLength = LengthMemory.decoded(JSONWalk.int(root["lastMinutes"]))
        let tasks = (root["tasks"] as? [[String: Any]]) ?? []
        loaded.habits = tasks.compactMap { item in
            guard let title = JSONWalk.string(item["title"]).map(FocusStore.clean),
                  !title.isEmpty else { return nil }
            return FocusMemory.Habit(
                title: title,
                length: LengthMemory.decoded(JSONWalk.int(item["minutes"])),
                at: JSONWalk.double(item["at"]).map(Date.init(timeIntervalSince1970:)) ?? .distantPast)
        }
        // Trimmed on the way in as well as on the way out: a file written by a
        // future version with a bigger cap must not make this one unbounded.
        if loaded.habits.count > FocusMemory.taskLimit {
            loaded.habits.removeFirst(loaded.habits.count - FocusMemory.taskLimit)
        }
        memory = loaded
    }
}
