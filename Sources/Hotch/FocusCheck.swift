import Foundation

/// `--check-focus`: exercises the timer's log against the store, in memory.
///
/// It exists because of a bug that a render could never have caught. The stop
/// button said "Stop & log", and for anything under two minutes it logged
/// nothing and said nothing — so the first thing anyone does with a new timer
/// (start it, stop it, see what happens) produced an empty log and no
/// explanation. Snapshots verify what a page *looks* like; this verifies that
/// pressing the button puts a line in the log.
///
/// It has since grown the two questions the redesign turned on, for the same
/// reason: neither has any pixels. That the line exists from the moment the run
/// *starts* — and is finished in place rather than added a second time — and
/// that the length offered is one this Mac was told, with nothing offered at all
/// on a store that has never been told anything.
///
/// Runs against a throwaway store with an injected clock, so it neither reads
/// nor writes the real focus log. The one scenario that needs a real file uses
/// the system temp directory and removes it afterwards.
@MainActor
enum FocusCheck {
    static func runBlockingAndExit() -> Never {
        var failures = 0

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok    \(name)")
            } else {
                failures += 1
                let suffix = detail().isEmpty ? "" : " \u{2014} \(detail())"
                print("  FAIL  \(name)\(suffix)")
            }
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // The reported bug, exactly: start it, stop it seconds later, look for
        // the line.
        print("a few seconds, stopped by hand")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.draftTitle = "Trying the timer"
            focus.start(minutes: 25, now: start)
            focus.stop(now: start.addingTimeInterval(6))
            check("logs one entry", focus.todayEntries.count == 1,
                  "got \(focus.todayEntries.count)")
            check("keeps the name", focus.todayEntries.first?.title == "Trying the timer",
                  focus.todayEntries.first?.title ?? "none")
            check("keeps the length", focus.todayEntries.first.map { abs($0.duration - 6) < 0.001 } ?? false)
            check("goes idle", !focus.isRunning)
            check("clears the draft", focus.draftTitle.isEmpty)
        }

        print("the line exists the moment the run starts")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.draftTitle = "Rewriting the forecast page"
            focus.start(minutes: 30, now: start)

            check("one line, immediately", focus.todayEntries.count == 1,
                  "got \(focus.todayEntries.count)")
            let live = focus.todayEntries.first
            check("and it is the run", live?.id == focus.run?.entryID)
            check("marked as running", live?.isRunning == true)
            check("named already", live?.title == "Rewriting the forecast page")
            check("nothing has finished yet", focus.finishedEntries.isEmpty)
            // The panel's tally column is the finished list, so it must not
            // gain a mark for a run that is still the donut beside it.
            check("the tally has nothing to show", focus.finishedTotal == 0)

            // The heartbeat keeps the row's duration current.
            focus.tick(now: start.addingTimeInterval(5 * 60))
            check("the live row's duration advances",
                  focus.todayEntries.first?.duration == 5 * 60,
                  "\(focus.todayEntries.first?.duration ?? -1)")
            check("the day total counts the run in progress", focus.todayTotal == 5 * 60,
                  "\(focus.todayTotal)")
            check("still one line", focus.todayEntries.count == 1)

            focus.stop(now: start.addingTimeInterval(7 * 60))
            check("stopping finishes the same line, it does not add one",
                  focus.todayEntries.count == 1, "got \(focus.todayEntries.count)")
            check("same identity throughout", focus.todayEntries.first?.id == live?.id)
            check("no longer running", focus.todayEntries.first?.isRunning == false)
            check("banked what it served", focus.todayEntries.first?.duration == 7 * 60)
            check("and now the tally has it", focus.finishedEntries.count == 1
                    && focus.finishedTotal == 7 * 60)
        }

        print("a run stopped under the floor takes its line with it")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.start(minutes: 15, now: start)
            check("the line is there while it runs", focus.todayEntries.count == 1)
            // A double-fire on the stop button. Nothing loggable happened, so
            // nothing may be left behind — a row of zero would be worse than
            // the silence the floor used to keep.
            focus.stop(now: start.addingTimeInterval(0.2))
            check("nothing is left in the log", focus.todayEntries.isEmpty)
            check("and it is idle", !focus.isRunning)
        }

        print("a set length, left to finish itself")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.start(minutes: 15, now: start)
            focus.tick(now: start.addingTimeInterval(14 * 60))
            check("still running before the end", focus.isRunning)
            focus.tick(now: start.addingTimeInterval(15 * 60 + 3))
            check("logs itself at the end", focus.todayEntries.count == 1)
            // Logged as the length promised, not the length observed: the tick
            // that notices may arrive a second late, and a "15m" timer that
            // logs 15m 3s would be reporting the poll interval.
            check("logs the length, not the overshoot",
                  focus.todayEntries.first.map { $0.duration == 15 * 60 } ?? false)
            check("the line is finished, not still running",
                  focus.todayEntries.first?.isRunning == false)
            check("goes idle", !focus.isRunning)
        }

        print("no set length")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.start(minutes: nil, now: start)
            check("no target", focus.targetDuration == nil)
            check("no ring fill without a denominator",
                  focus.progress(now: start.addingTimeInterval(600)) == nil)
            check("nothing to count down to", focus.remaining(now: start.addingTimeInterval(600)) == nil)
            check("counts up", focus.elapsed(now: start.addingTimeInterval(600)) == 600)
            // The overnight guard.
            focus.tick(now: start.addingTimeInterval(FocusStore.openEndedCap + 60))
            check("closes itself at the cap", !focus.isRunning)
            check("banks exactly the cap",
                  focus.todayEntries.first.map { $0.duration == FocusStore.openEndedCap } ?? false)
        }

        print("starting over a running one")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.start(minutes: 30, now: start)
            focus.start(minutes: 15, now: start.addingTimeInterval(10 * 60))
            check("banks the abandoned one", focus.finishedEntries.count == 1)
            check("banks what it served",
                  focus.finishedEntries.first.map { $0.duration == 10 * 60 } ?? false)
            check("the new one is running", focus.targetDuration == 15 * 60)
            check("and has a line of its own", focus.todayEntries.count == 2
                    && focus.todayEntries.last?.isRunning == true)
        }

        print("pause freezes the clock")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.draftTitle = "Deep work"
            focus.start(minutes: 30, now: start)
            focus.pause(now: start.addingTimeInterval(10 * 60))
            // A paused run must not advance, complete, or finish by itself.
            focus.tick(now: start.addingTimeInterval(2 * 3600))
            check("still running while paused", focus.isRunning && focus.isPaused)
            check("elapsed frozen at the pause",
                  focus.elapsed(now: start.addingTimeInterval(2 * 3600)) == 10 * 60)
            check("remaining frozen too",
                  focus.remaining(now: start.addingTimeInterval(2 * 3600)) == 20 * 60)
            check("nothing has finished", focus.finishedEntries.isEmpty)
            check("the live row froze with it",
                  focus.todayEntries.first?.duration == 10 * 60,
                  "\(focus.todayEntries.first?.duration ?? -1)")
            // Resume two hours later; the gap does not count.
            focus.resumeRun(now: start.addingTimeInterval(2 * 3600))
            focus.stop(now: start.addingTimeInterval(2 * 3600 + 5 * 60))
            check("logs served time only, not the gap",
                  focus.todayEntries.first.map { $0.duration == 15 * 60 } ?? false,
                  focus.todayEntries.first.map { Fmt.duration($0.duration) } ?? "none")
            check("dates the work at its first start",
                  focus.todayEntries.first?.startedAt == start)
        }

        print("a countdown completes across a pause")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.start(minutes: 15, now: start)
            focus.pause(now: start.addingTimeInterval(10 * 60))
            focus.resumeRun(now: start.addingTimeInterval(3600))
            focus.tick(now: start.addingTimeInterval(3600 + 5 * 60 + 2))
            check("finishes itself after the remaining 5m", !focus.isRunning)
            check("logs the length", focus.todayEntries.first.map { $0.duration == 15 * 60 } ?? false)
        }

        print("resuming a stopped task continues it")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.draftTitle = "Inbox"
            focus.start(minutes: 30, now: start)
            focus.stop(now: start.addingTimeInterval(12 * 60))
            let entry = focus.todayEntries[0]
            check("cut-short countdown is continuable", entry.isContinuable)
            focus.resume(entry, now: start.addingTimeInterval(3600))
            check("the finished line became the live one",
                  focus.finishedEntries.isEmpty && focus.todayEntries.count == 1
                      && focus.todayEntries.first?.isRunning == true)
            check("keeping its identity", focus.todayEntries.first?.id == entry.id)
            check("the clock continues where it stopped",
                  focus.elapsed(now: start.addingTimeInterval(3600)) == 12 * 60)
            check("counting down toward the same target",
                  focus.remaining(now: start.addingTimeInterval(3600)) == 18 * 60)
            focus.stop(now: start.addingTimeInterval(3600 + 6 * 60))
            check("one combined line, not fragments",
                  focus.todayEntries.count == 1
                      && focus.todayEntries.first?.duration == 18 * 60)
            check("keeps the name", focus.todayEntries.first?.title == "Inbox")
        }

        print("resuming a finished countdown starts it over")
        do {
            let focus = FocusStore(persists: false)
            let done = FocusEntry(startedAt: start, duration: 15 * 60,
                                  title: "Review", length: 15 * 60)
            focus.inject(state: .idle, entries: [done])
            check("a completed countdown is not continuable", !done.isContinuable)
            focus.resume(done, now: start.addingTimeInterval(3600))
            check("the finished entry stays logged", focus.finishedEntries.count == 1)
            check("and the fresh run has its own line",
                  focus.todayEntries.count == 2
                      && focus.todayEntries.last?.id != done.id)
            check("a fresh run at the full length",
                  focus.remaining(now: start.addingTimeInterval(3600)) == 15 * 60)
            check("same task name", focus.runningLabel == "Review")
        }

        print("resuming an open-ended task continues up")
        do {
            let focus = FocusStore(persists: false)
            let open = FocusEntry(startedAt: start, duration: 20 * 60, title: "Sketching")
            focus.inject(state: .idle, entries: [open])
            check("open-ended is always continuable", open.isContinuable)
            focus.resume(open, now: start.addingTimeInterval(3600))
            check("nothing finished is left", focus.finishedEntries.isEmpty)
            check("counts up from its total",
                  focus.elapsed(now: start.addingTimeInterval(3600 + 60)) == 21 * 60)
            check("still no target", focus.targetDuration == nil)
        }

        print("the run in progress cannot be resumed on top of itself")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.start(minutes: 30, now: start)
            guard let live = focus.todayEntries.first else {
                check("a live row to try it on", false)
                exit(1)
            }
            focus.resume(live, now: start.addingTimeInterval(60))
            check("still exactly one line", focus.todayEntries.count == 1)
            check("still the same run", focus.run?.entryID == live.id)
            check("and the clock did not restart",
                  focus.elapsed(now: start.addingTimeInterval(60)) == 60)
        }

        print("a run that never closed comes back finished")
        do {
            // The crash case. A scratch file in the system temp directory,
            // never the real `focus-log`: a verification mode must not write
            // anything the app would later read.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hotch-check-focus-log.json")
            try? FileManager.default.removeItem(at: url)
            defer { try? FileManager.default.removeItem(at: url) }

            // Today, because the log is one day deep and a fixed epoch date is
            // not today.
            let today = Date()
            let first = FocusStore(file: .scratch(url))
            first.draftTitle = "Interrupted by a kernel panic"
            first.start(minutes: 60, now: today.addingTimeInterval(-20 * 60))
            first.tick(now: today)
            check("the running line reached the file",
                  FileManager.default.fileExists(atPath: url.path))

            // No stop, no quit: the process simply ends. A relaunch reads it.
            let second = FocusStore(file: .scratch(url))
            check("the time survived", second.todayEntries.count == 1,
                  "got \(second.todayEntries.count)")
            check("as a finished entry, not a running one",
                  second.todayEntries.first?.isRunning == false)
            // Deliberately not resumed: a timer counting again because the app
            // relaunched is a timer nobody started.
            check("nothing was resumed behind the user's back", !second.isRunning)
            check("carrying what it had reached",
                  second.todayEntries.first.map { abs($0.duration - 20 * 60) < 1 } ?? false,
                  "\(second.todayEntries.first?.duration ?? -1)")
            check("and it can be picked back up by hand",
                  second.todayEntries.first?.isContinuable == true)
            // Killed again before anything could rewrite the file: the same
            // `running` line is read a second time and must not become a second
            // run of it, or the day would grow every time the app was relaunched.
            let third = FocusStore(file: .scratch(url))
            check("a second kill does not duplicate the line",
                  third.todayEntries.count == 1
                      && third.todayEntries.first?.id == second.todayEntries.first?.id,
                  "got \(third.todayEntries.count)")
            check("and the day's total does not move",
                  abs(third.todayTotal - second.todayTotal) < 0.001,
                  "\(third.todayTotal) vs \(second.todayTotal)")

            // A run stopped by hand lands beside it as an ordinary second line.
            let clean = FocusStore(file: .scratch(url))
            clean.draftTitle = "Stopped properly"
            clean.start(minutes: 15, now: today)
            clean.stop(now: today.addingTimeInterval(90))
            let reloaded = FocusStore(file: .scratch(url))
            check("a run that closed cleanly is just another line",
                  reloaded.todayEntries.count == 2,
                  "\(reloaded.todayEntries.count) entries")
        }

        print("the length is remembered, never chosen for you")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            // Rule 3, and the only state where Start has nothing to commit.
            check("a virgin store offers nothing",
                  focus.memory.resolvedLength(for: "") == nil)
            check("nor for a name it has never seen",
                  focus.memory.resolvedLength(for: "FRNSW DEV") == nil)

            focus.draftTitle = "FRNSW DEV"
            focus.start(minutes: 30, now: start)
            focus.stop(now: start.addingTimeInterval(30 * 60))
            // Rule 1.
            check("the task remembers its own length",
                  focus.memory.habit(for: "FRNSW DEV")?.length == .minutes(30),
                  "\(String(describing: focus.memory.habit(for: "FRNSW DEV")?.length))")
            check("however it is capitalised",
                  focus.memory.habit(for: "frnsw dev")?.length == .minutes(30))
            // Rule 2.
            check("and an unseen task falls back to the last length used",
                  focus.memory.resolvedLength(for: "Something new") == .minutes(30))

            focus.draftTitle = "Inbox"
            focus.start(minutes: 15, now: start.addingTimeInterval(3600))
            focus.stop(now: start.addingTimeInterval(3600 + 15 * 60))
            check("the global fallback follows the newest run",
                  focus.memory.resolvedLength(for: "Something new") == .minutes(15))
            check("but the named task keeps its own",
                  focus.memory.resolvedLength(for: "FRNSW DEV") == .minutes(30))

            focus.draftTitle = "Sketching"
            focus.start(minutes: nil, now: start.addingTimeInterval(7200))
            focus.stop(now: start.addingTimeInterval(7200 + 600))
            check("open-ended is a remembered answer too, not an absent one",
                  focus.memory.resolvedLength(for: "Sketching") == .openEnded)

            focus.draftTitle = "Long haul"
            focus.start(minutes: 90, now: start.addingTimeInterval(10_000))
            check("a custom length comes back as the typed field",
                  focus.memory.habit(for: "Long haul")?.length?.choice == .custom)
            check("with the number in it",
                  focus.memory.habit(for: "Long haul")?.length?.customText == "90")
        }

        print("the memory cannot grow without bound")
        do {
            var memory = FocusMemory()
            for index in 0..<(FocusMemory.taskLimit + 40) {
                memory.remember(title: "Task \(index)", length: .minutes(30),
                                at: start.addingTimeInterval(Double(index)))
            }
            check("capped at the limit", memory.habits.count == FocusMemory.taskLimit,
                  "\(memory.habits.count)")
            check("the oldest names went first",
                  memory.habit(for: "Task 0") == nil && memory.habit(for: "Task 239") != nil)
            // Most recent wins rather than a second row for the same name.
            memory.remember(title: "Task 239", length: .minutes(45),
                            at: start.addingTimeInterval(9_999))
            check("a repeated name is replaced, not duplicated",
                  memory.habits.filter { $0.title == "Task 239" }.count == 1)
            check("with the newer answer", memory.habit(for: "Task 239")?.length == .minutes(45))
            check("an unnamed run remembers no name",
                  { var m = FocusMemory()
                    m.remember(title: "  ", length: .openEnded, at: start)
                    return m.habits.isEmpty && m.lastLength == .openEnded }())
        }

        print("Return with nothing selected does not start")
        do {
            check("no selection refuses", FocusStore.decide(length: nil, custom: "") == .refuse)
            check("half-typed custom refuses",
                  FocusStore.decide(length: .custom, custom: "abc") == .refuse)
            check("an empty custom field refuses",
                  FocusStore.decide(length: .custom, custom: "") == .refuse)
            check("a pill starts", FocusStore.decide(length: .minutes(30), custom: "")
                    == .start(minutes: 30))
            check("open-ended starts with no length",
                  FocusStore.decide(length: .openEnded, custom: "") == .start(minutes: nil))
            check("a typed custom starts",
                  FocusStore.decide(length: .custom, custom: "90") == .start(minutes: 90))

            // What the surfaces do with a refusal: nothing at all.
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.draftTitle = "Ready to go"
            if case let .start(minutes) = FocusStore.decide(length: nil, custom: "") {
                focus.start(minutes: minutes, now: start)
            }
            check("so nothing starts", !focus.isRunning && focus.todayEntries.isEmpty)
            check("and the typed name is still there", focus.draftTitle == "Ready to go")
        }

        print("the memory outlives the process")
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hotch-check-focus-memory.json")
            try? FileManager.default.removeItem(at: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let first = FocusStore(file: .scratch(url))
            first.draftTitle = "FRNSW DEV"
            first.start(minutes: 30, now: Date())
            first.stop(now: Date().addingTimeInterval(1))

            let second = FocusStore(file: .scratch(url))
            check("the task's length came back",
                  second.memory.habit(for: "FRNSW DEV")?.length == .minutes(30))
            check("and the global fallback with it", second.memory.lastLength == .minutes(30))

            // Garbage costs the memory, never the launch.
            try? Data("{not json at all".utf8).write(to: url)
            let third = FocusStore(file: .scratch(url))
            check("a corrupt file loads as empty",
                  third.memory.habits.isEmpty && third.todayEntries.isEmpty)
            check("and nothing is selected on the way back up",
                  third.memory.resolvedLength(for: "FRNSW DEV") == nil)

            // Valid JSON with every value the wrong shape, which is the likelier
            // failure and a different path through the loader than unparseable
            // bytes: half a file, or one a later version wrote differently.
            try? Data(#"{"entries":"not a list","memory":[1,2,3]}"#.utf8).write(to: url)
            let fourth = FocusStore(file: .scratch(url))
            check("a file of the wrong shape loads as empty too",
                  fourth.todayEntries.isEmpty && fourth.memory.habits.isEmpty
                      && fourth.memory.lastLength == nil)

            // Right shape, nonsense contents. Bad rows are dropped one at a
            // time rather than costing the whole file.
            try? Data(#"""
            {"entries":[{"startedAt":"soon"},{"duration":5}],
             "memory":{"tasks":[{"at":1},{"title":"  "}],"lastMinutes":"soon"}}
            """#.utf8).write(to: url)
            let fifth = FocusStore(file: .scratch(url))
            check("and rows that make no sense are dropped one at a time",
                  fifth.todayEntries.isEmpty && fifth.memory.habits.isEmpty
                      && fifth.memory.lastLength == nil)
        }

        print("names")
        do {
            let focus = FocusStore(persists: false)
            focus.inject(state: .idle, entries: [])
            focus.start(minutes: 15, now: start)
            focus.stop(now: start.addingTimeInterval(60))
            check("an unnamed run still reads as something",
                  focus.todayEntries.first?.displayTitle == FocusEntry.untitled)
            check("a pasted paragraph cannot become a name",
                  FocusStore.clean(String(repeating: "x", count: 500)).count
                      == FocusStore.titleLimit)
            check("surrounding space is not a name", FocusStore.clean("   ").isEmpty)
        }

        print("custom lengths")
        do {
            check("plain minutes", FocusStore.customLength(from: "90") == 90)
            check("padded minutes", FocusStore.customLength(from: " 90 ") == 90)
            check("zero is not a length", FocusStore.customLength(from: "0") == nil)
            check("nor is a word", FocusStore.customLength(from: "soon") == nil)
            check("nor is a week",
                  FocusStore.customLength(from: "10080") == nil)
        }

        print(failures == 0 ? "\nfocus: all checks passed"
                            : "\nfocus: \(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
