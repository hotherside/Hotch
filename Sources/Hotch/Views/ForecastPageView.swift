import SwiftUI

/// The forecast page: the same windows as the usage page, but showing where
/// each one *lands* by the time it resets rather than where it stands now.
///
/// The first version drew a sparkline of consumption over time, and it did not
/// work. A trace of "% used" only ever goes up and then resets, so a window in
/// trouble and a window with hours to spare drew the same rising line — the
/// picture carried no answer, and the reader had to get it from the caption
/// instead. It also showed the *past*, which is not what the page is for.
///
/// What the page is really about is a race: consumption climbing toward the cap
/// against the clock running toward the reset. So the picture is a bar with the
/// coming change drawn onto it — solid for what is certain, a shaded band for
/// what this pace spends before the reset. Whether the band reaches the far end
/// is the whole answer, and it is legible before any of the words are read.
enum ForecastDisplay {
    /// Below this the pace is measurement jitter, and extrapolating jitter to a
    /// cap time produces impressive-sounding nonsense like "caps next Tuesday".
    static let quietRate: Double = 0.75
    /// A cap landing within this of the reset is too close to call either way.
    static let tightMargin: TimeInterval = 30 * 60

    /// What the page is actually for: the answer, in one word.
    enum Outlook {
        /// Not enough history to state a pace. The footer explains once.
        case collecting
        /// A pace too small to extrapolate honestly.
        case idle
        /// The window resets before this pace could exhaust it.
        case onTrack
        /// Cap and reset land within half an hour of each other.
        case tight
        /// The cap arrives first.
        case runsOut

        var word: String {
            switch self {
            case .collecting: return ""
            case .idle: return "idle"
            case .onTrack: return "on track"
            case .tight: return "tight"
            case .runsOut: return "runs out"
            }
        }

        /// Amber is for what is *coming*, red for what already *is* — so a
        /// prediction never wears the colour the usage page uses for a window
        /// that is genuinely nearly spent. Everything calm stays quiet.
        var color: Color {
            switch self {
            case .collecting, .idle: return NotchTheme.mutedText
            case .onTrack: return NotchTheme.unitText
            case .tight, .runsOut: return NotchTheme.attention
            }
        }

        var isAlarming: Bool { self == .tight || self == .runsOut }

        /// Lower is worse. A row shows one verdict for several windows, and it
        /// has to be the worst of them: reporting the session window because it
        /// happens to be listed first would hide a weekly that is about to run
        /// out behind a session window with hours to spare.
        var severity: Int {
            switch self {
            case .runsOut: return 0
            case .tight: return 1
            case .onTrack: return 2
            case .idle: return 3
            case .collecting: return 4
            }
        }
    }

    /// Consumption this window reaches by its reset, at the fitted pace.
    ///
    /// Deliberately unclamped: a window heading for 140% is a different
    /// statement from one landing exactly on 100%, and the bar needs to know
    /// which before it decides what to draw.
    static func projectedConsumed(window: UsageWindow,
                                  forecast: BurnForecast?,
                                  now: Date) -> Double? {
        guard let consumed = window.consumedPercent else { return nil }
        guard let forecast, forecast.ratePerHour >= quietRate,
              let resets = window.resetsAt else { return consumed }
        let hours = max(0, resets.timeIntervalSince(now) / 3600)
        return consumed + forecast.ratePerHour * hours
    }

    /// The outlook plus the one number worth printing beside it.
    ///
    /// `mode` is taken because the landing figure is a share of a plan window
    /// like every other number in the app, and so has to be stated in the same
    /// direction as the bar beside it. Reporting it in consumed terms next to a
    /// bar drawing what is left is exactly the two-quantities-one-slot mistake
    /// the display-mode rule exists to prevent.
    static func outlook(forecast: BurnForecast?,
                        window: UsageWindow,
                        now: Date,
                        mode: UsageDisplayMode) -> (outlook: Outlook, detail: String) {
        guard let forecast else { return (.collecting, "") }
        guard let eta = forecast.capETA, forecast.ratePerHour >= quietRate else {
            return (.idle, "steady")
        }
        guard let resets = window.resetsAt else {
            return (.runsOut, "~\(ForecastDisplay.when(eta, now: now))")
        }
        // How far the cap lands *after* the reset. Positive is the safe
        // direction: the window empties and starts again before this pace could
        // exhaust it. Getting this sign backwards is not a symmetric mistake —
        // it labels a healthy window "runs out", which is the one error a
        // glance surface must not make, so the demo fixture carries a provider
        // in each direction to keep it honest.
        let capAfterReset = eta.timeIntervalSince(resets)
        if capAfterReset > tightMargin {
            // Where it actually lands is the useful number when nothing is
            // wrong: it is the difference between "comfortable" and "only just".
            let landing = projectedConsumed(window: window, forecast: forecast, now: now)
                .map { consumed -> Double in
                    let clamped = min(100, max(0, consumed))
                    return mode == .used ? clamped : 100 - clamped
                }
            let text = landing.map { "lands ~\(Fmt.percent($0)) \(mode.unit)" } ?? "resets first"
            return (.onTrack, text)
        }
        if capAfterReset > -tightMargin {
            return (.tight, "cap ~\(ForecastDisplay.when(eta, now: now))")
        }
        return (.runsOut, "~\(ForecastDisplay.when(eta, now: now))")
    }

    /// A clock time, with the weekday once it is more than most of a day
    /// away: "9:14 PM" tonight, "Fri 10:35 AM" for a weekly window. A bare
    /// time four days out reads as today.
    static func when(_ date: Date, now: Date) -> String {
        guard date.timeIntervalSince(now) > 18 * 3600 else { return Fmt.clockTime(date) }
        return weekdayClock.string(from: date)
    }

    private static let weekdayClock: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return f
    }()

    /// "+11%/hr", or nothing when there is no honest pace to quote.
    static func rateText(_ forecast: BurnForecast?) -> String? {
        guard let forecast, forecast.ratePerHour >= quietRate else { return nil }
        return "+\(Int(forecast.ratePerHour.rounded()))%/hr"
    }

    static let emptyText = "nothing to forecast \u{2014} connect a provider with plan windows"
    static let collectingText = "collecting history \u{2014} a pace appears after ~15 minutes"
    /// Said once in the footer. The shaded band is the one piece of notation on
    /// the page that cannot be worked out by looking at it, so it gets a key
    /// rather than leaving every reader to infer it.
    ///
    /// Kept short deliberately: the footer's centre belongs to the page dots,
    /// and the long form ran underneath them.
    static let legendText = "shaded = spent by reset"

    /// True when not one provider has enough history to state a pace yet, which
    /// is the case the footer explains once instead of every row saying it.
    static func isCollecting(usages: [ProviderUsage],
                             history: UsageHistoryStore,
                             now: Date) -> Bool {
        let windowed = usages.filter { !$0.windows.isEmpty }
        guard !windowed.isEmpty else { return false }
        return !windowed.contains { usage in
            guard let window = usage.windows.first else { return false }
            return history.forecast(providerID: usage.providerID,
                                    windowLabel: window.shortWindowLabel,
                                    now: now) != nil
        }
    }
}

// MARK: - Projection bar

/// A meter with the coming change drawn onto it.
///
/// Three zones, and the rule holds in both display directions because it is
/// stated in terms of change rather than of "more" or "less":
///
/// - **solid** — the part that is certain either way,
/// - **shaded** — what this pace spends between now and the reset,
/// - **track** — what is left over when the reset arrives.
///
/// In Used mode the bar fills rightward and the shaded band is the part about
/// to fill; in Remaining mode the bar drains and the shaded band is the part
/// about to drain. Either way the reading is the same: **if the shaded band
/// reaches the far end, the window does not survive to its reset.** No empty
/// track means no headroom.
struct ProjectionBar: View {
    /// Where the window stands now, 0...1 in the displayed direction.
    let current: Double?
    /// Where it lands at reset, same direction, already clamped to 0...1.
    let projected: Double?
    /// The projection reaches the end: this window runs out first.
    let isAlarming: Bool
    /// The projection was clipped — the pace spends past the end of the bar.
    let overflowed: Bool
    let identity: ProviderIdentity

    static let height: CGFloat = 8

    private var tint: ProviderIdentity {
        isAlarming ? ProviderIdentity.warning : identity
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lo = min(current ?? 0, projected ?? current ?? 0)
            let hi = max(current ?? 0, projected ?? current ?? 0)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(current == nil ? PopoverTheme.trackDim : PopoverTheme.track)

                if current != nil {
                    // The band first, so the solid segment draws over its
                    // rounded left cap and the two read as one bar rather than
                    // two capsules touching. Alarming bands are drawn harder:
                    // when a window runs out there is no solid segment left to
                    // contrast against, and at 0.34 the whole bar was a dim
                    // stub that read as "nearly empty" rather than "all of this
                    // is about to go".
                    Capsule(style: .continuous)
                        .fill(tint.accent.opacity(isAlarming ? 0.55 : 0.32))
                        .frame(width: max(0, w * hi))

                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(lo > 0 ? ProjectionBar.height : 0, w * lo))

                    // A hairline where certainty ends and the projection
                    // begins, so the boundary survives at 8pt tall even when
                    // the two fills are close in value.
                    if hi - lo > 0.004 {
                        Rectangle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 1, height: ProjectionBar.height)
                            .offset(x: max(0, w * lo))
                    }

                    // The wall. A clipped projection has run past the end of
                    // the bar, and without a mark for it the drawing tops out
                    // and quietly understates the case — "exactly full" and
                    // "over by half again" would look identical. It lands on
                    // whichever end the window empties toward, so it is the
                    // right edge in Used mode and the left in Remaining.
                    if overflowed {
                        Capsule(style: .continuous)
                            .fill(ProviderIdentity.warning.highlight)
                            .frame(width: 2.5, height: ProjectionBar.height)
                            .offset(x: min(w - 2.5, max(0, w * (projected ?? 0) - 1.25)))
                    }
                }
            }
        }
        .frame(height: ProjectionBar.height)
    }
}

/// Resolves a window and its forecast into what the bar draws.
enum ProjectionData {
    struct Shares {
        var current: Double?
        var projected: Double?
        /// The unclamped projection fell outside 0...100: the pace spends past
        /// the end of the bar, so the drawing is clipped and needs to say so.
        var overflowed: Bool
    }

    static func shares(window: UsageWindow,
                       forecast: BurnForecast?,
                       now: Date,
                       mode: UsageDisplayMode) -> Shares {
        guard let current = window.fillShare(mode) else {
            return Shares(current: nil, projected: nil, overflowed: false)
        }
        guard let landing = ForecastDisplay.projectedConsumed(window: window,
                                                              forecast: forecast,
                                                              now: now) else {
            return Shares(current: current, projected: current, overflowed: false)
        }
        let shown = mode == .used ? landing : 100 - landing
        return Shares(current: current,
                      projected: min(1, max(0, shown / 100)),
                      overflowed: landing > 100)
    }
}

// MARK: - Panel block

/// One provider on the forecast page: a projection bar per window, the pace
/// beneath, and the outlook on the right.
struct ForecastProviderBlock: View {
    let usage: ProviderUsage
    let history: UsageHistoryStore
    let now: Date
    let active: Bool
    let index: Int
    /// Only the exit reads it — see `PanelMotion.rowOut(_:of:)`.
    let blockCount: Int

    @Environment(\.usageDisplayMode) private var mode

    private var identity: ProviderIdentity {
        ProviderIdentity.identity(for: usage.providerID)
    }

    /// The two windows the usage page shows, and no more.
    private var shownWindows: [UsageWindow] {
        Array(usage.windows.prefix(2))
    }

    /// The window in the most trouble, and everything derived from it. One row
    /// carries one verdict, so it has to describe the worst of the windows on
    /// it rather than whichever happens to be listed first. Which window that
    /// is stays visible without being named: an alarming bar is drawn in the
    /// warning tint while its neighbour keeps the brand colour.
    private var worst: (window: UsageWindow,
                        forecast: BurnForecast?,
                        outlook: ForecastDisplay.Outlook,
                        detail: String)? {
        shownWindows
            .map { window -> (UsageWindow, BurnForecast?, ForecastDisplay.Outlook, String) in
                let forecast = history.forecast(providerID: usage.providerID,
                                                windowLabel: window.shortWindowLabel,
                                                now: now)
                let resolved = ForecastDisplay.outlook(forecast: forecast, window: window,
                                                       now: now, mode: mode)
                return (window, forecast, resolved.outlook, resolved.detail)
            }
            .min { $0.2.severity < $1.2.severity }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            brandColumn

            VStack(alignment: .leading, spacing: NotchTheme.forecastCaptionGap) {
                // Side by side, in the same two slots the usage page puts its
                // rings in, so the two pages line up column for column.
                HStack(spacing: 14) {
                    ForEach(shownWindows) { window in
                        windowCell(window).frame(maxWidth: .infinity)
                    }
                    if shownWindows.count < 2 {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .frame(height: NotchTheme.forecastWindowRowHeight)

                paceLine
            }

            verdictColumn
        }
        .frame(height: NotchTheme.forecastBlockHeight)
        .opacity(active ? 1 : 0)
        .offset(y: active ? 0 : -4)
        .animation(active ? PanelMotion.rowIn(index)
                          : PanelMotion.rowOut(index, of: blockCount),
                   value: active)
    }

    private var brandColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            BrandMark(kind: identity.mark, size: 15, tint: identity.accent)
            Text(usage.displayName.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(identity.accent)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: NotchTheme.leadingColumnWidth, alignment: .leading)
    }

    /// Window label and its bar. No percentage: the usage page owns where you
    /// stand, this page owns where you are heading, and printing the same
    /// figure twice in a smaller font is what made this page read as a worse
    /// copy of that one.
    private func windowCell(_ window: UsageWindow) -> some View {
        let forecast = history.forecast(providerID: usage.providerID,
                                        windowLabel: window.shortWindowLabel,
                                        now: now)
        let shares = ProjectionData.shares(window: window, forecast: forecast,
                                           now: now, mode: mode)
        let outlook = ForecastDisplay.outlook(forecast: forecast, window: window, now: now, mode: mode).outlook

        return HStack(spacing: 7) {
            Text(window.shortWindowLabel.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(NotchTheme.unitText)
                .lineLimit(1)
                .fixedSize()

            ProjectionBar(current: shares.current,
                          projected: shares.projected,
                          isAlarming: outlook.isAlarming,
                          overflowed: shares.overflowed,
                          identity: identity)
        }
    }

    /// The pace and the horizon it is measured against, so the bar's shaded
    /// band has a stated length in time as well as in width.
    private var paceLine: some View {
        let parts = [worst.flatMap { ForecastDisplay.rateText($0.forecast) },
                     worst?.window.resetsAt.map { "resets \(Fmt.clockTime($0))" }]
        return Text(parts.compactMap { $0 }.joined(separator: "  \u{00B7}  "))
            .font(.system(size: 9.5))
            .foregroundStyle(NotchTheme.captionText)
            .lineLimit(1)
            .frame(height: NotchTheme.forecastCaptionHeight, alignment: .center)
    }

    /// The answer in a word, with its one number beneath. Laid out like the
    /// sessions page's status column, which is already the first thing anyone
    /// reads on that page.
    private var verdictColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let worst, worst.outlook != .collecting {
                Text(worst.outlook.word)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(worst.outlook.color)
                    .lineLimit(1)
                Text(worst.detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(NotchTheme.mutedText)
                    .lineLimit(1)
            }
        }
        .frame(width: 104, alignment: .trailing)
    }
}

/// The row stack for the panel's forecast page.
struct ForecastPageRows: View {
    let usages: [ProviderUsage]
    let history: UsageHistoryStore
    let now: Date
    let active: Bool

    private var forecastable: [ProviderUsage] {
        usages.filter { !$0.windows.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            if forecastable.isEmpty {
                Text(ForecastDisplay.emptyText)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.mutedText)
                    .frame(maxWidth: .infinity, minHeight: NotchTheme.rowHeight)
                    .opacity(active ? 1 : 0)
                    .animation(PanelMotion.contentIn(after: active ? PanelMotion.brandLead : 0),
                               value: active)
            }
            ForEach(Array(forecastable.enumerated()), id: \.element.id) { index, usage in
                if index > 0 {
                    Rectangle()
                        .fill(NotchTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 3.5)
                        .opacity(active ? 1 : 0)
                        .animation(PanelMotion.contentIn(after: active ? PanelMotion.statLead : 0),
                                   value: active)
                }
                ForecastProviderBlock(usage: usage,
                                      history: history,
                                      now: now,
                                      active: active,
                                      index: index,
                                      blockCount: forecastable.count)
            }
        }
    }
}

// MARK: - Popover section

/// The forecast re-laid for the popover: full-width bars, one per window.
struct PopoverForecastSection: View {
    let usages: [ProviderUsage]
    let history: UsageHistoryStore
    let now: Date

    @Environment(\.usageDisplayMode) private var mode

    private var forecastable: [ProviderUsage] {
        usages.filter { !$0.windows.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if forecastable.isEmpty {
                Text(ForecastDisplay.emptyText)
                    .font(.system(size: PopoverTheme.bodySize))
                    .foregroundStyle(PopoverTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(forecastable.enumerated()), id: \.element.id) { index, usage in
                if index > 0 {
                    Rectangle()
                        .fill(PopoverTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 14)
                }
                section(usage)
            }
            if !forecastable.isEmpty {
                Text(ForecastDisplay.legendText)
                    .font(.system(size: PopoverTheme.captionSize))
                    .foregroundStyle(PopoverTheme.mutedText)
                    .padding(.top, 12)
            }
        }
    }

    private func section(_ usage: ProviderUsage) -> some View {
        let identity = ProviderIdentity.identity(for: usage.providerID)
        let window = usage.windows.first
        let forecast = window.flatMap {
            history.forecast(providerID: usage.providerID, windowLabel: $0.shortWindowLabel, now: now)
        }
        let resolved = window.map { ForecastDisplay.outlook(forecast: forecast, window: $0, now: now, mode: mode) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandMark(kind: identity.mark, size: 15, tint: identity.accent)
                Text(usage.displayName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(identity.accent)
                Spacer(minLength: 6)
                // The answer rides the brand line here: the popover is a narrow
                // column, so there is no room for a status column beside the
                // bars the way the panel has.
                if let resolved, resolved.outlook != .collecting {
                    Text(resolved.outlook.word)
                        .font(.system(size: PopoverTheme.bodySize, weight: .semibold))
                        .foregroundStyle(resolved.outlook.color)
                        .lineLimit(1)
                }
            }

            ForEach(usage.windows.prefix(2)) { window in
                let f = history.forecast(providerID: usage.providerID,
                                         windowLabel: window.shortWindowLabel, now: now)
                let shares = ProjectionData.shares(window: window, forecast: f,
                                                   now: now, mode: mode)
                let outlook = ForecastDisplay.outlook(forecast: f, window: window, now: now, mode: mode).outlook

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(window.shortWindowLabel.uppercased())
                            .font(.system(size: PopoverTheme.microSize, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(PopoverTheme.secondaryText)
                        Spacer(minLength: 4)
                        if let resets = window.resetsAt {
                            Text("resets \(Fmt.clockTime(resets))")
                                .font(.system(size: PopoverTheme.captionSize))
                                .foregroundStyle(PopoverTheme.mutedText)
                        }
                    }
                    ProjectionBar(current: shares.current,
                                  projected: shares.projected,
                                  isAlarming: outlook.isAlarming,
                                  overflowed: shares.overflowed,
                                  identity: identity)
                }
            }

            if let resolved, resolved.outlook != .collecting {
                Text([ForecastDisplay.rateText(forecast), resolved.detail]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: "  \u{00B7}  "))
                    .font(.system(size: PopoverTheme.captionSize))
                    .foregroundStyle(PopoverTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
