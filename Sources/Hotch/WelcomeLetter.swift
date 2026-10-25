import AppKit
import SwiftUI

// MARK: - Style

enum WelcomeStyle {
    /// The app icon's warm signal, the one colour the welcome borrows.
    static let signal = Color(red: 1, green: 0.55, blue: 0.40)
    static let cream = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let width: CGFloat = 460
    static let padding: CGFloat = 36

    /// Tall enough for the letter on a typical screen, never taller than the
    /// screen itself. Setup scrolls inside it on a short display.
    static func windowSize(for screen: NSScreen?, visibleHeight: CGFloat? = nil) -> CGSize {
        let visible = visibleHeight ?? screen?.visibleFrame.height ?? 800
        return CGSize(width: width, height: min(580, max(380, visible - 60)))
    }

    /// Whether the greeting plays. With motion reduced, or VoiceOver reading,
    /// everything is simply there.
    static var animates: Bool {
        !HMotion.reduceMotion && !NSWorkspace.shared.isVoiceOverEnabled
    }
}

// MARK: - The mark

/// The app icon's companion curve and warm signal, drawn as shapes so the
/// curve can draw itself and the signal can arrive. Same proportions as
/// `HotchIcon.drawAppIcon`, flipped into SwiftUI's top-left coordinates.
struct WelcomeMark: View {
    var timeline: WelcomeTimeline
    var size: CGFloat = 72

    private var markSide: CGFloat { size * 0.84 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.19, blue: 0.22),
                                              Color(red: 0.075, green: 0.083, blue: 0.10)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: max(1, size * 0.008)))
                .shadow(color: .black.opacity(0.22), radius: size * 0.06, y: size * 0.02)
            ZStack(alignment: .topLeading) {
                CompanionCurve()
                    .trim(from: 0, to: timeline.curve)
                    .stroke(WelcomeStyle.cream,
                            style: StrokeStyle(lineWidth: markSide * 0.12, lineCap: .round))
                let dot = markSide * 0.20
                let centre = CGPoint(x: markSide * 0.65, y: markSide * 0.50)
                if timeline.ripple > 0 && timeline.ripple < 1 {
                    Circle()
                        .stroke(WelcomeStyle.signal.opacity(0.55 * (1 - timeline.ripple)), lineWidth: 1.5)
                        .frame(width: dot * (1 + 2.6 * timeline.ripple), height: dot * (1 + 2.6 * timeline.ripple))
                        .position(centre)
                }
                Circle()
                    .fill(WelcomeStyle.signal)
                    .frame(width: dot, height: dot)
                    .scaleEffect(timeline.signal)
                    .opacity(min(1, timeline.signal * 2))
                    .position(centre)
            }
            .frame(width: markSide, height: markSide)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The open curve of the mark, from its top end round to its bottom end.
struct CompanionCurve: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0.60, 0.16))
        path.addCurve(to: point(0.60, 0.84), control1: point(0.17, 0.21), control2: point(0.17, 0.79))
        return path
    }
}

// MARK: - The letter

/// The first thing a new person sees: the mark draws itself, the signal
/// lights, and a short letter eases in line by line.
struct WelcomeLetterView: View {
    var installed: Bool = true
    /// One moment of the greeting, for rendered docs; nil plays it live.
    var frozenAt: TimeInterval? = nil
    var onExplainInstall: () -> Void = {}
    var onContinue: () -> Void = {}

    @State private var start = Date()
    @State private var settled = !WelcomeStyle.animates

    var body: some View {
        if let frozenAt {
            content(WelcomeTimeline(time: frozenAt))
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: settled)) { context in
                content(settled ? .settled : WelcomeTimeline(time: context.date.timeIntervalSince(start)))
            }
            .task {
                guard !settled else { return }
                try? await Task.sleep(for: .seconds(WelcomeTimeline.duration))
                settled = true
            }
        }
    }

    private func content(_ timeline: WelcomeTimeline) -> some View {
        VStack(spacing: 0) {
            // The letter sits in the middle of whatever height the screen
            // allows, and scrolls on a display too short to hold it. The
            // button stays in reach below it either way.
            GeometryReader { proxy in
                ScrollView {
                    letter(timeline)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            VStack(spacing: 14) {
                if !installed { installNote }
                Button(action: onContinue) {
                    Text("Set up Hotch").frame(minWidth: 150)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .opacity(timeline.footer)
            .padding(.horizontal, WelcomeStyle.padding)
            .padding(.top, 14)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) { WelcomeGlow(amount: timeline.glow) }
    }

    private func letter(_ timeline: WelcomeTimeline) -> some View {
        VStack(spacing: 0) {
            // Clear of the title bar.
            Spacer(minLength: 34)
            WelcomeMark(timeline: timeline)
            Text(WelcomeCopy.greeting)
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .modifier(BlurFade(amount: 1 - timeline.line(0)))
                .padding(.top, 22)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(WelcomeCopy.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .modifier(BlurFade(amount: 1 - timeline.line(index + 1)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(WelcomeCopy.signOff)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Link(WelcomeCopy.contact, destination: URL(string: "mailto:\(WelcomeCopy.contact)")!)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .help("Write to Hojae")
                }
                .padding(.top, 7)
                .accessibilityElement(children: .combine)
                .modifier(BlurFade(amount: 1 - timeline.line(WelcomeTimeline.lineCount - 1)))
            }
            .font(.system(size: 13.5))
            .lineSpacing(2.5)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, WelcomeStyle.padding)
    }

    /// A copy run from the disk image works, but cannot open at login and is
    /// gone after a restart. Said gently here rather than in an alert on top
    /// of the greeting.
    private var installNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(HP.amber)
                .accessibilityHidden(true)
            Text(WelcomeCopy.notInstalled)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Me", action: onExplainInstall)
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HP.amber.opacity(0.10)))
        .accessibilityElement(children: .contain)
    }
}

/// Warm light from the signal, spreading behind the mark. Opaque layers only,
/// so it reads the same with transparency reduced.
struct WelcomeGlow: View {
    var amount: Double

    var body: some View {
        RadialGradient(colors: [WelcomeStyle.signal.opacity(0.16 * amount), WelcomeStyle.signal.opacity(0)],
                       center: .init(x: 0.5, y: 0.23), startRadius: 0, endRadius: 150 + 120 * amount)
            .frame(height: 360)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
