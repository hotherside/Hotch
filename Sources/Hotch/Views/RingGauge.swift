import SwiftUI

/// Compact circular gauge. The centre is deliberately empty: the number lives in
/// the text column beside it so there is only one place to read.
///
/// **Direction.** The arc is anchored at twelve o'clock and grows
/// **anti-clockwise**, so the colour appears on the left of the ring and sweeps
/// round toward the right — the same direction the popover's bar fills, which is
/// the point. Clockwise put the colour on the right first, reading as though the
/// meter ran backwards next to a bar that ran forwards, and two meters on the same
/// row disagreeing about direction is worse than either choice on its own.
///
/// It takes a resolved share rather than a percentage so it knows nothing about
/// whether it is drawing consumption or the remainder. That is the caller's
/// decision, and keeping it out of here is what stops the two from drifting apart.
struct RingGauge: View {
    /// Share of the circle to paint, 0...1. Nil means there is nothing to show.
    let share: Double?
    /// Whether to abandon the brand colour for the warning treatment. Passed in
    /// because it keys off consumption, which this view can no longer see.
    let isCritical: Bool
    let identity: ProviderIdentity
    /// Drives the draw-in animation. Tied to the panel expansion state.
    let active: Bool
    var size: CGFloat = NotchTheme.ringSize
    var lineWidth: CGFloat = NotchTheme.ringLineWidth
    /// The unfilled remainder, and the dimmer version of it that stands for
    /// "nothing measured".
    ///
    /// Parameters rather than constants because the ring is no longer a
    /// panel-only instrument: the sessions page draws one per row on both
    /// surfaces, and `NotchTheme`'s track is white at 16% — correct on the
    /// near-black panel, and completely invisible on the light popover, where
    /// the first version of the context gauge drew an arc floating in nothing
    /// and a session with no reading drew literally nothing at all.
    var track: Color = NotchTheme.ringTrack
    var trackDim: Color = NotchTheme.ringTrackDim

    private var effectiveIdentity: ProviderIdentity {
        isCritical ? ProviderIdentity.warning : identity
    }

    private var fraction: Double {
        min(1, max(0, share ?? 0))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(share == nil ? trackDim : track, lineWidth: lineWidth)

            if share != nil {
                Circle()
                    // Trimming the *tail* of the path is what reverses the sweep.
                    // A Circle's path starts and ends at the same point, so taking
                    // the last `fraction` of it yields an arc that ends at twelve
                    // o'clock and extends backwards — anti-clockwise — from there.
                    // No mirror transform, which would also flip the gradient.
                    .trim(from: active ? 1 - fraction : 1, to: 1)
                    .stroke(effectiveIdentity.gradient,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: isCritical ? effectiveIdentity.accent.opacity(0.6) : .clear,
                            radius: 4)
                    .animation(HMotion.reduceMotion ? nil : .easeOut(duration: PanelMotion.ringSweep), value: active)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage meter")
        .accessibilityValue(share.map { "\(Int(($0 * 100).rounded())) percent" } ?? "No reading")
    }
}

/// One window, presented as an open stat block: no container, no border.
/// Ring, then a small uppercase window label, the consumed percentage as the
/// loudest number in the row, and the reset countdown beneath it.
struct StatBlock: View {
    let window: UsageWindow?
    let placeholderLabel: String
    let identity: ProviderIdentity
    let now: Date
    let active: Bool

    @Environment(\.usageDisplayMode) private var mode

    private var label: String {
        (window?.shortWindowLabel ?? placeholderLabel).uppercased()
    }

    var body: some View {
        HStack(spacing: 11) {
            RingGauge(share: window?.fillShare(mode),
                      isCritical: window?.isCritical ?? false,
                      identity: identity,
                      active: active)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(NotchTheme.captionText)

                if let percent = window?.percent(mode) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(Fmt.percent(percent))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(NotchTheme.primaryText)
                        Text(mode.unit)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(NotchTheme.unitText)
                    }
                    Text(Fmt.countdown(to: window?.resetsAt, now: now) ?? "no reset time")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(NotchTheme.subText)
                        .lineLimit(1)
                } else {
                    Text("no data")
                        .font(.system(size: 10.5, weight: .regular))
                        .foregroundStyle(NotchTheme.mutedText)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

/// Credit-metered providers (DeepSeek, Kimi) have no window ceiling to measure
/// against, so the slot shows the remaining balance as the loud number and an
/// empty ring beside it.
///
/// The ring used to be drawn full, in the brand colour, standing in for "credit
/// available". That did not survive reporting consumption: a full ring reads as a
/// spent window, so on a row that means "you have $42 left" it said the loudest
/// possible opposite. Nor is it rescued by the Remaining mode — a prepaid balance
/// has no denominator in *either* direction, so no arc length can be correct. The
/// honest mark is the bare track, which claims nothing.
///
/// `left` stays on the amount in both modes for the same reason: there is no
/// total to subtract from, so "used" would have nothing to mean.
struct BalanceSlot: View {
    let balance: ProviderBalance
    let detail: String?
    let identity: ProviderIdentity

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .stroke(NotchTheme.ringTrackDim, lineWidth: NotchTheme.ringLineWidth)
                .frame(width: NotchTheme.ringSize, height: NotchTheme.ringSize)

            VStack(alignment: .leading, spacing: 2) {
                Text("CREDIT")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(NotchTheme.captionText)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.money(balance.amount, currency: balance.currency))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotchTheme.primaryText)
                    Text("left")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(NotchTheme.unitText)
                }

                Text(detail ?? "prepaid API credit")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(NotchTheme.subText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }
}
