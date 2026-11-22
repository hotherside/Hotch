import SwiftUI

// MARK: - Hotch (home)

/// Home: usage, the Mac's three vitals and the desk tools at a glance. Each
/// block leads to its tab; the only thing that ever pushes in above them is a
/// session waiting on you, because a blocked agent is the most actionable
/// thing Hotch knows.
struct CompactHome: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var system: SystemMonitor
    @ObservedObject var focus: FocusStore
    @ObservedObject var clipboard: ClipboardStore
    let history: UsageHistoryStore
    let now: Date
    let nav: SectionNav

    private var needing: [AgentSession] { sessionStore.sessions.filter { $0.activity == .needsInput } }

    private var sessionsLabel: String {
        let live = sessionStore.sessions.filter { $0.activity <= .shell }.count
        return live == 0 ? "Sessions" : "\(live) session\(live == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(needing.prefix(2)) { session in
                NeedsYouLine(session: session) { nav.jump(session) }
            }
            BlockHeading(title: "AI usage", link: sessionsLabel) { nav.go(.ai) }
            usage
            BlockHeading(title: "This Mac", link: "More") { nav.go(.mac) }
            HomeMacTiles(system: system, nav: nav)
            BlockHeading(title: "Desk", link: "More") { nav.go(.desk) }
            HomeDesk(focus: focus, clipboard: clipboard, now: now, nav: nav)
        }
    }

    @ViewBuilder
    private var usage: some View {
        if store.usages.isEmpty {
            Button(action: nav.openSettings) {
                HStack {
                    Text("No AI accounts connected yet").font(.system(size: CT.body, weight: .semibold))
                    Spacer()
                    Text("Settings").font(.system(size: CT.caption)).foregroundStyle(HP.text3)
                }
                .padding(.horizontal, 10).frame(height: 40)
            }
            .buttonStyle(TileButtonStyle(radius: 12))
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(store.usages.prefix(4)) { usage in
                    Button {
                        if usage.needsSetup { nav.openSettings() } else { nav.go(.ai) }
                    } label: {
                        HomeUsageTile(usage: usage, now: now)
                    }
                    .buttonStyle(TileButtonStyle(radius: 12))
                }
            }
        }
    }
}

/// A block's small heading with the way into its tab on the right.
struct BlockHeading: View {
    let title: String
    let link: String
    var action: () -> Void

    var body: some View {
        HStack {
            Kicker(text: title)
            Spacer(minLength: 4)
            Button(action: action) {
                HStack(spacing: 3) {
                    Text(link)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: CT.caption, weight: .medium))
                .foregroundStyle(HP.text3)
                .padding(.horizontal, 4).frame(height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("\(title): \(link)")
        }
        .padding(.leading, 2)
        .padding(.top, 2)
    }
}

/// The one line home gives a session that is waiting on you.
struct NeedsYouLine: View {
    let session: AgentSession
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "hand.raised.fill").foregroundStyle(HP.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    (Text("Needs you").fontWeight(.semibold).foregroundColor(HP.amber)
                        + Text("  \u{00B7}  \(session.name)").foregroundColor(HP.text))
                        .font(.system(size: CT.body))
                        .lineLimit(1)
                    if let ask = session.step?.command ?? session.step?.label ?? session.waitingFor {
                        Text(ask)
                            .font(.system(size: 10.5, design: session.step?.command == nil ? .default : .monospaced))
                            .foregroundStyle(HP.text2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HP.amber).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HP.amber.opacity(0.13)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing(radius: 12))
        .help(session.waitingFor ?? "Go to the session")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(session.surface ?? "the session’s app")")
    }
}

/// A provider at home: its tightest window as a ring, or its balance.
struct HomeUsageTile: View {
    let usage: ProviderUsage
    let now: Date
    @Environment(\.usageDisplayMode) private var mode
    private var identity: ProviderIdentity { ProviderIdentity.identity(for: usage.providerID) }
    private var tightest: UsageWindow? {
        usage.windows.max { ($0.consumedPercent ?? -1) < ($1.consumedPercent ?? -1) }
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                if let window = tightest {
                    ForecastRing(share: window.fillShare(mode), isCritical: window.isCritical,
                                 color: identity.accent, size: 32, lineWidth: 3)
                } else {
                    Circle().stroke(HP.track, lineWidth: 3).frame(width: 32, height: 32)
                }
                BrandMark(kind: identity.mark, size: 12, tint: identity.accent)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(usage.displayName).font(.system(size: CT.caption)).foregroundStyle(HP.text2).lineLimit(1)
                Text(value)
                    .font(.system(size: CT.title, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(tightest?.isCritical == true || usage.needsSetup ? HP.amber : HP.text)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(caption).font(.system(size: 10.5)).foregroundStyle(HP.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var value: String {
        if usage.needsSetup { return "Set up" }
        if let window = tightest {
            return window.percent(mode).map { "\(Fmt.percent($0)) \(mode.unit)" } ?? "No reading"
        }
        if let balance = usage.balance { return Fmt.money(balance.amount, currency: balance.currency) }
        return "No reading"
    }

    private var caption: String {
        if usage.needsSetup { return usage.detail ?? "Finish in Settings" }
        if let window = tightest {
            return [window.displayName, Fmt.remaining(to: window.resetsAt, now: now)]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        return usage.balance == nil ? (usage.detail ?? "") : "credit left"
    }
}

/// CPU, memory and thermals: the three readings worth a glance.
struct HomeMacTiles: View {
    @ObservedObject var system: SystemMonitor
    let nav: SectionNav

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            if let snap = system.latest {
                tile("CPU", "\(SysFmt.percent(snap.cpu.total))%", action: { nav.openDetail(.cpu) }) {
                    Sparkline(values: Array(system.cpuHistory.suffix(30)), maxValue: 100,
                              color: HP.cpu, lineWidth: 1.2)
                }
                tile("Memory", "\(SysFmt.percent(snap.memory.usedPercent))%",
                     action: { nav.openDetail(.memory) }) {
                    MemoryBar(memory: snap.memory, height: 5)
                }
                let thermal = Thermals(snap.thermal)
                tile("Thermals", thermal.value, tint: thermal.color, action: { nav.go(.mac) }) {
                    HStack(spacing: 4) {
                        Circle().fill(thermal.color).frame(width: 5, height: 5)
                        Text(thermal.caption).lineLimit(1)
                    }
                    .font(.system(size: 10.5)).foregroundStyle(HP.text3)
                }
            } else {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HP.tile).frame(height: 66)
                }
            }
        }
    }

    private func tile<Chart: View>(_ label: String, _ value: String, tint: Color = HP.text,
                                   action: @escaping () -> Void,
                                   @ViewBuilder chart: () -> Chart) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: CT.caption)).foregroundStyle(HP.text2)
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tint).lineLimit(1)
                chart().frame(height: 14)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle(radius: 12))
        .accessibilityElement(children: .combine)
    }

    /// The part most over its own limits (a battery is hot far sooner than a
    /// core), so this tile and the Mac tab's thermals never disagree.
    private struct Thermals {
        let value: String
        let caption: String
        let color: Color

        init(_ thermal: ThermalReading) {
            func level(_ c: ComponentTemp) -> Int { c.tempC >= c.hotAt ? 2 : (c.tempC >= c.warmAt ? 1 : 0) }
            let worst = thermal.components.max {
                (level($0), $0.tempC) < (level($1), $1.tempC)
            }
            let severity = max(worst.map(level) ?? 0,
                               thermal.state == .critical ? 2 : (thermal.state == .serious ? 1 : 0))
            value = SysFmt.temp(worst?.tempC ?? thermal.cpuTempC) ?? SysFmt.thermal(thermal.state)
            color = severity == 2 ? HP.red : (severity == 1 ? HP.amber : HP.ok)
            if severity > 0, let worst {
                caption = "\(worst.name) \(severity == 2 ? "hot" : "warm")"
            } else if let top = thermal.fans.map(\.rpm).max() {
                caption = top < 100 ? "fans off" : "fans on"
            } else {
                caption = worst?.name ?? "no sensors"
            }
        }
    }
}

/// Focus started in one click, and the last two things copied.
struct HomeDesk: View {
    @ObservedObject var focus: FocusStore
    @ObservedObject var clipboard: ClipboardStore
    let now: Date
    let nav: SectionNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            focusRow
            if clipboard.enabled, !clipboard.items.isEmpty {
                Rectangle().fill(HP.stroke).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 2)
                ClipboardRows(clipboard: clipboard, now: now, limit: 2)
            }
        }
        .padding(4)
        .tile(radius: 12)
    }

    @ViewBuilder
    private var focusRow: some View {
        if focus.isRunning, let readout = FocusDisplay.readout(focus, now: now) {
            Button { nav.go(.desk) } label: {
                HStack(spacing: 8) {
                    Image(systemName: focus.isPaused ? "pause.fill" : "timer").foregroundStyle(HP.text2)
                    Text(FocusDisplay.runCaption(focus) ?? "Focus").foregroundStyle(HP.text)
                    Spacer(minLength: 4)
                    Text(readout.value).font(.system(size: CT.title, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(readout.caption).foregroundStyle(HP.text3)
                }
                .font(.system(size: CT.body))
                .padding(.horizontal, 6).frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        } else {
            HStack(spacing: 5) {
                Image(systemName: "timer").foregroundStyle(HP.text2).accessibilityHidden(true)
                Text("Focus").font(.system(size: CT.body, weight: .semibold)).foregroundStyle(HP.text)
                Spacer(minLength: 4)
                ForEach(FocusSetup.durations, id: \.self) { minutes in
                    chip("\(minutes)m", help: "Start a \(minutes) minute timer") {
                        focus.start(minutes: minutes, now: now)
                    }
                }
                chip(nil, help: "Start a stopwatch") { focus.start(minutes: nil, now: now) }
            }
            .padding(.leading, 6).padding(.trailing, 2).frame(height: 34)
        }
    }

    private func chip(_ title: String?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let title { Text(title) } else { Image(systemName: "stopwatch") }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(HP.text)
            .padding(.horizontal, title == nil ? 7 : 9)
            .frame(height: 24)
            .background(Capsule(style: .continuous).fill(HP.tile))
            .overlay(Capsule(style: .continuous).strokeBorder(HP.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(KeyboardFocusRing(radius: 12))
        .help(help)
        .accessibilityLabel(help)
    }

}

/// Copied text as short rows: click one to copy it again.
struct ClipboardRows: View {
    @ObservedObject var clipboard: ClipboardStore
    let now: Date
    var limit: Int = ClipboardStore.maxItems
    @State private var copiedID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(clipboard.items.prefix(limit)) { item in
                row(item)
            }
        }
    }

    private func row(_ item: ClipboardItem) -> some View {
        Button {
            clipboard.copyBack(item)
            copiedID = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedID == item.id { copiedID = nil }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 11)).foregroundStyle(HP.text3)
                    .accessibilityHidden(true)
                Text(item.preview).font(.system(size: CT.body)).foregroundStyle(HP.text)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(copiedID == item.id ? "copied" : (Fmt.ago(item.copiedAt, now: now) ?? ""))
                    .font(.system(size: CT.caption, weight: copiedID == item.id ? .semibold : .regular))
                    .foregroundStyle(copiedID == item.id ? HP.amber : HP.text3)
                    .fixedSize()
            }
            .padding(.horizontal, 6).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help(ClipboardDisplay.tooltip(for: item))
        .accessibilityLabel("Copy \(item.preview)")
    }
}

// MARK: - AI

/// Every provider with its plan windows, and the sessions running on it
/// nested beneath: usage and the work spending it, in one place.
struct CompactAITab: View {
    @ObservedObject var store: UsageStore
    let sessions: [AgentSession]
    let history: UsageHistoryStore
    let now: Date
    let nav: SectionNav

    /// Providers in the store's order, then any provider with sessions but no
    /// usage reading (Codex running with usage switched off, say).
    private var groups: [String] {
        var ids = store.usages.map(\.providerID)
        for session in sessions where !ids.contains(session.providerID) {
            ids.append(session.providerID)
        }
        return ids
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty {
                Text("No AI accounts switched on").font(.system(size: CT.body, weight: .semibold))
                Text("Claude Code and Codex sessions appear here as they run.")
                    .font(.system(size: CT.caption)).foregroundStyle(HP.text3)
                Button("Connect an account", action: nav.openSettings).buttonStyle(PillButtonStyle())
            }
            ForEach(groups, id: \.self) { id in
                ProviderGroup(usage: store.usages.first { $0.providerID == id }, providerID: id,
                              sessions: sessions.filter { $0.providerID == id },
                              history: history, now: now, nav: nav)
            }
            if store.usages.contains(where: { !$0.windows.isEmpty }) {
                Text("Lighter arc estimates usage before the reset.")
                    .font(.system(size: CT.caption)).foregroundStyle(HP.text3)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct ProviderGroup: View {
    let usage: ProviderUsage?
    let providerID: String
    let sessions: [AgentSession]
    let history: UsageHistoryStore
    let now: Date
    let nav: SectionNav
    @Environment(\.usageDisplayMode) private var mode
    private var identity: ProviderIdentity { ProviderIdentity.identity(for: providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let usage { usageBody(usage) }
            if !sessions.isEmpty {
                VStack(spacing: 1) {
                    ForEach(sessions) { session in
                        CardSessionRow(session: session, now: now) { nav.jump(session) }
                    }
                }
                .padding(.leading, 4)
                .overlay(alignment: .leading) {
                    Rectangle().fill(HP.stroke).frame(width: 1.5).padding(.vertical, 4)
                }
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, sessions.isEmpty ? 10 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(radius: 14)
    }

    private var header: some View {
        HStack(spacing: 7) {
            BrandMark(kind: identity.mark, size: 14, tint: identity.accent).accessibilityHidden(true)
            Text(usage?.displayName ?? Fmt.humanize(key: providerID))
                .font(.system(size: CT.title, weight: .semibold)).foregroundStyle(HP.text)
            if let plan = usage.flatMap({ $0.plan ?? (status($0) == nil ? $0.detail : nil) }) {
                Text(plan).font(.system(size: CT.caption)).foregroundStyle(HP.text3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let usage, usage.windows.isEmpty, let balance = usage.balance {
                Text(Fmt.money(balance.amount, currency: balance.currency))
                    .font(.system(size: CT.body, weight: .semibold)).monospacedDigit().foregroundStyle(HP.text)
                Text("credit left").font(.system(size: CT.caption)).foregroundStyle(HP.text3)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func usageBody(_ usage: ProviderUsage) -> some View {
        let readings = usage.windows.map {
            WindowReading(window: $0, providerID: usage.providerID, history: history, now: now, mode: mode)
        }
        if !readings.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
                    windowChip(reading)
                }
            }
        }
        if !usage.windows.isEmpty, let balance = usage.balance {
            Text("\(Fmt.money(balance.amount, currency: balance.currency)) credit left")
                .font(.system(size: CT.caption)).foregroundStyle(HP.text2).padding(.horizontal, 4)
        }
        ForEach(Array(readings.enumerated()), id: \.offset) { _, reading in
            if reading.alarming && !usage.isStale(now: now) {
                Text("\(reading.window.displayName): \(reading.compact)")
                    .font(.system(size: CT.caption, weight: .medium)).foregroundStyle(HP.amber)
                    .padding(.horizontal, 4)
            }
        }
        if let status = status(usage) {
            Text(status).font(.system(size: CT.caption))
                .foregroundStyle(usage.needsSetup || usage.isStale(now: now) ? HP.amber : HP.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        if usage.needsSetup {
            Button(usage.providerID == "claude" ? "Sign in with Claude Code" : "Open Settings",
                   action: usage.providerID == "claude" ? nav.signInClaude : nav.openSettings)
                .buttonStyle(PillButtonStyle(compact: true))
                .padding(.horizontal, 4)
        }
        if !usage.extras.isEmpty {
            Text(usage.extras.joined(separator: " \u{00B7} "))
                .font(.system(size: CT.caption)).foregroundStyle(HP.text2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    /// The freshness line, only when it warns: setup, a stale reading, or no
    /// reading at all. Otherwise the vendor's detail is the plan's name and
    /// sits beside the provider instead.
    private func status(_ usage: ProviderUsage) -> String? {
        guard usage.needsSetup || usage.isStale(now: now) || (usage.windows.isEmpty && usage.balance == nil)
        else { return nil }
        return usage.freshnessCaption(now: now)
    }

    private func windowChip(_ reading: WindowReading) -> some View {
        let window = reading.window
        let percent = window.percent(mode).map { Fmt.percent($0) } ?? "\u{2014}"
        let reset = Fmt.remaining(to: window.resetsAt, now: now)
        return HStack(spacing: 8) {
            ForecastRing(share: reading.share, projected: reading.projected, isCritical: window.isCritical,
                         color: identity.accent, size: 20, lineWidth: 2.6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(window.displayName).font(.system(size: 10.5)).foregroundStyle(HP.text3).lineLimit(1)
                Text([percent, reset].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.system(size: CT.body, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(window.isCritical ? HP.amber : HP.text)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HP.tile))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.displayName), \(percent) \(mode.unit)"
                            + (reset.map { ", resets in \($0)" } ?? ""))
    }
}

/// A session as the AI tab shows it: what it is doing this second, what it
/// wants approved, or where it sits when idle. Click to bring its app forward.
struct CardSessionRow: View {
    let session: AgentSession
    let now: Date
    var action: () -> Void

    @Environment(\.usageDisplayMode) private var mode
    private var identity: ProviderIdentity { ProviderIdentity.identity(for: session.providerID) }
    private var live: Bool { session.activity <= .shell }
    private var needsYou: Bool { session.activity == .needsInput }

    var body: some View {
        Button(action: action) {
            Group {
                if live { liveRow } else { quietRow }
            }
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help(needsYou ? (session.waitingFor ?? "Go to the session") : "Open in \(session.surface ?? "its app")")
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(session.surface ?? "the session’s app")")
    }

    private var liveRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(HP.text)
                    .lineLimit(1)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                StatusCapsule(word: AgentStatus.word(session), dot: dotColor, text: wordColor)
                Text(contextCaption).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(HP.text3)
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.vertical, 7)
        .frame(minHeight: 50)
    }

    private var quietRow: some View {
        HStack(spacing: 8) {
            Text(session.name).font(.system(size: CT.body)).foregroundStyle(HP.text2).lineLimit(1)
            Spacer(minLength: 6)
            Text([AgentStatus.word(session), Fmt.ago(session.lastEventAt, now: now)]
                    .compactMap { $0 }.joined(separator: " \u{00B7} "))
                .font(.system(size: 10.5)).foregroundStyle(HP.text3).lineLimit(1).fixedSize()
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private var detail: some View {
        if needsYou, let ask = session.step?.command ?? session.step?.label ?? session.waitingFor {
            HStack(spacing: 0) {
                Text(ask)
                    .font(.system(size: 10.5, design: session.step?.command == nil ? .default : .monospaced))
                    .foregroundStyle(HP.text)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(HP.amber.opacity(0.14)))
                Spacer(minLength: 0)
            }
        } else if let step = session.step, !needsYou {
            HStack(spacing: 5) {
                Image(systemName: step.symbol).font(.system(size: 10)).foregroundStyle(HP.text3)
                    .accessibilityHidden(true)
                Text(step.label)
                    .font(.system(size: step.label == step.command ? 10.5 : 11,
                                  design: step.label == step.command ? .monospaced : .default))
                    .foregroundStyle(HP.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let started = step.startedAt {
                    Text(FocusDisplay.clock(now.timeIntervalSince(started)))
                        .font(.system(size: CT.caption)).monospacedDigit().foregroundStyle(HP.text3)
                }
            }
        } else {
            Text([session.projectName.isEmpty ? nil : session.projectName, session.surface]
                    .compactMap { $0 }.joined(separator: " \u{00B7} "))
                .font(.system(size: CT.caption)).foregroundStyle(HP.text3).lineLimit(1)
        }
    }

    private var dotColor: Color { needsYou ? HP.amber : identity.accent }
    private var wordColor: Color { needsYou ? HP.amber : identity.textAccent }

    private var contextCaption: String {
        guard let percent = session.contextPercent(mode) else {
            return SessionDisplay.age(for: session, now: now) ?? ""
        }
        return "\(Fmt.percent(percent)) \(mode == .used ? "context" : "context left")"
    }
}

/// A status word on a tint of its own colour. Only live states get one;
/// quiet states stay plain text, so the eye goes to what is moving.
struct StatusCapsule: View {
    let word: String
    let dot: Color
    let text: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(word)
        }
        .font(.system(size: CT.caption, weight: .semibold))
        .foregroundStyle(text)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule(style: .continuous).fill(dot.opacity(0.14)))
    }
}

// MARK: - Desk

/// The tools you switch on: Focus, the clipboard and Backpack mode.
struct CompactDesk: View {
    @ObservedObject var focus: FocusStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var backpack: BackpackManager
    let now: Date
    let nav: SectionNav

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PopoverFocusSection(focus: focus, now: now)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Kicker(text: "Clipboard")
                    Spacer(minLength: 4)
                    Text(clipboard.enabled ? "memory only" : "off")
                        .font(.system(size: CT.caption)).foregroundStyle(HP.text3)
                }
                .padding(.horizontal, 2)
                Group {
                    if !clipboard.enabled || clipboard.items.isEmpty {
                        Text(clipboard.enabled ? ClipboardDisplay.emptyText : ClipboardDisplay.disabledText)
                            .font(.system(size: CT.caption)).foregroundStyle(HP.text3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 6).padding(.vertical, 8)
                    } else {
                        ClipboardRows(clipboard: clipboard, now: now)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tile(radius: 12)
            }
            BackpackDiscoveryRow(backpack: backpack, action: nav.openBackpack)
        }
    }
}

// MARK: - Update

/// A found update, as a button beside Settings in the footer of every tab:
/// filled violet, the one coloured control down there, so it is seen at a
/// glance without taking the status line's place. It is there only while
/// something is waiting to install.
struct UpdateButton: View {
    let offer: AppUpdater.Offer
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 6).padding(.trailing, 8)
            .frame(height: 22)
            .background(Capsule(style: .continuous).fill(UpdateButton.violet.opacity(hovering ? 0.86 : 1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .modifier(KeyboardFocusRing(radius: 11))
        .help(help)
        .accessibilityLabel(help)
    }

    /// White on either clears 4.5:1, so the small label stays readable.
    static let violet = Dynamic.color(dark: Dynamic.rgb(0.49, 0.36, 0.93), light: Dynamic.rgb(0.44, 0.30, 0.86))

    private var symbol: String {
        switch offer {
        case .available: return "arrow.down.circle.fill"
        case .ready: return "arrow.clockwise.circle.fill"
        }
    }

    private var label: String {
        switch offer {
        case .available: return "Update"
        case .ready: return "Restart"
        }
    }

    private var help: String {
        switch offer {
        case .available(let version): return "Update to Hotch \(version): see what's new and install it"
        case .ready(let version): return "Restart Hotch now to finish updating to \(version)"
        }
    }
}

// MARK: - Mac warning

extension SystemSnapshot {
    /// The one Mac condition worth a line of its own, most serious first.
    var warning: String? {
        if memory.pressure == .critical { return "Memory pressure is high" }
        if thermal.state == .critical || thermal.state == .serious { return "Mac is running hot" }
        if thermal.components.contains(where: { $0.tempC >= $0.hotAt }) { return "A component is running hot" }
        if memory.pressure == .warning { return "Memory pressure is raised" }
        if thermal.state == .fair || thermal.components.contains(where: { $0.tempC >= $0.warmAt }) {
            return "Mac is running warm"
        }
        if let power, power.hasBattery, !power.isCharging, power.batteryPercent <= 20 {
            return "Battery is low"
        }
        return nil
    }
}
