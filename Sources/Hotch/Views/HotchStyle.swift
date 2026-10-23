import AppKit
import SwiftUI

// MARK: - Palette

/// Hotch 2's colours. Every one is dynamic, so the same section views draw on
/// the panel (forced dark, it is pretending to be the bezel) and in the popover
/// (which follows the system) without either knowing which it is in.
///
/// The system metrics each own one hue and keep it everywhere — tile, chart,
/// detail, menu bar — so a colour means the same thing wherever it appears.
/// They are chosen away from the provider brands (clay, periwinkle) so a CPU
/// chart never reads as Claude.
enum HP {
    static let text = Dynamic.color(dark: .init(white: 1, alpha: 0.94), light: .init(white: 0, alpha: 0.88))
    static let text2 = Dynamic.color(dark: .init(white: 1, alpha: 0.66), light: .init(white: 0, alpha: 0.62))
    static let text3 = Dynamic.color(dark: .init(white: 1, alpha: 0.58), light: .init(white: 0, alpha: 0.58))
    static let tile = Dynamic.color(dark: .init(white: 1, alpha: 0.055), light: .init(white: 0, alpha: 0.045))
    static let tileHover = Dynamic.color(dark: .init(white: 1, alpha: 0.095), light: .init(white: 0, alpha: 0.075))
    static let stroke = Dynamic.color(dark: .init(white: 1, alpha: 0.075), light: .init(white: 0, alpha: 0.07))
    static let track = Dynamic.color(dark: .init(white: 1, alpha: 0.14), light: .init(white: 0, alpha: 0.10))
    static let pill = Dynamic.color(dark: .init(white: 1, alpha: 0.16), light: .init(white: 1, alpha: 1))

    static let amber = NotchTheme.attention
    static let red = Dynamic.color(dark: Dynamic.rgb(1.0, 0.27, 0.23), light: Dynamic.rgb(0.84, 0.0, 0.08))
    static let ok = Dynamic.color(dark: Dynamic.rgb(0.20, 0.84, 0.29), light: Dynamic.rgb(0.12, 0.56, 0.23))

    static let cpu = Dynamic.color(dark: Dynamic.rgb(0.39, 0.82, 1.0), light: Dynamic.rgb(0.0, 0.43, 0.62))
    static let gpu = Dynamic.color(dark: Dynamic.rgb(0.75, 0.35, 0.95), light: Dynamic.rgb(0.54, 0.27, 0.67))
    static let memory = Dynamic.color(dark: Dynamic.rgb(1.0, 0.84, 0.04), light: Dynamic.rgb(0.58, 0.42, 0.0))
    static let down = Dynamic.color(dark: Dynamic.rgb(0.25, 0.61, 1.0), light: Dynamic.rgb(0.0, 0.38, 0.78))
    static let up = Dynamic.color(dark: Dynamic.rgb(1.0, 0.62, 0.04), light: Dynamic.rgb(0.68, 0.34, 0.0))
    static let disk = Dynamic.color(dark: Dynamic.rgb(0.40, 0.83, 0.81), light: Dynamic.rgb(0.05, 0.49, 0.47))
    static let power = Dynamic.color(dark: Dynamic.rgb(0.20, 0.84, 0.29), light: Dynamic.rgb(0.12, 0.56, 0.23))

    static func pressure(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: return ok
        case .warning: return amber
        case .critical: return red
        }
    }

    static let tileRadius: CGFloat = 14
}

// MARK: - Motion

/// Hotch 2's motion vocabulary, layered on `PanelMotion` (which still owns the
/// unfold and fold). Springs throughout: the panel is one physical object, and
/// everything that moves inside it moves the same way.
enum HMotion {
    /// Read the system preferences on access so newly shown surfaces stay in sync.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var section: Animation? { reduceMotion ? nil : .spring(duration: 0.28, bounce: 0) }
    static var tab: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }
    static var detail: Animation? { reduceMotion ? nil : .spring(duration: 0.28, bounce: 0) }
    /// Live telemetry updates in place; animation is reserved for user actions.
    static var tick: Animation? { nil }
    static var sectionTransition: AnyTransition { reduceMotion ? .identity : .opacity }
}

struct BlurFade: ViewModifier {
    var amount: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: HMotion.reduceMotion || HMotion.reduceTransparency ? 0 : 4 * amount)
            .offset(y: HMotion.reduceMotion ? 0 : 3 * amount)
    }
}

// MARK: - Tiles

struct TileBackground: ViewModifier {
    var radius: CGFloat = HP.tileRadius
    var fill: Color = HP.tile
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
    }
}

extension View {
    func tile(radius: CGFloat = HP.tileRadius) -> some View {
        modifier(TileBackground(radius: radius))
    }
}

/// A tile that is also a button: lifts on hover, gives a little on press.
struct TileButtonStyle: ButtonStyle {
    var radius: CGFloat = HP.tileRadius
    func makeBody(configuration: Configuration) -> some View {
        TileButtonBody(configuration: configuration, radius: radius)
    }

    private struct TileButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let radius: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(hovering ? HP.tileHover : HP.tile))
                .modifier(KeyboardFocusRing(radius: radius))
                .scaleEffect(configuration.isPressed && !HMotion.reduceMotion ? 0.985 : 1)
                .animation(HMotion.reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
                .animation(HMotion.reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Plain rows that wash on hover (clipboard rows, list rows).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }
    private struct RowBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering || configuration.isPressed ? HP.tile : .clear))
                .modifier(KeyboardFocusRing(radius: 10))
                .onHover { hovering = $0 }
        }
    }
}

/// A consistent keyboard focus cue for custom button content.
struct KeyboardFocusRing: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(HP.text2, lineWidth: isFocused ? 2 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Small rounded pill button used for actions inside sections.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, go }
    var kind: Kind = .plain
    var compact: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12.5, weight: .semibold))
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 26 : 28)
            .foregroundStyle(foreground)
            .background(Capsule(style: .continuous).fill(background))
            .overlay(Capsule(style: .continuous).strokeBorder(kind == .plain ? HP.stroke : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .modifier(KeyboardFocusRing(radius: 20))
    }
    private var background: Color {
        switch kind {
        case .plain: return HP.tile
        case .primary: return HP.text
        case .go: return HP.ok
        }
    }
    private var foreground: Color {
        switch kind {
        case .plain: return HP.text
        case .primary: return Dynamic.color(dark: .black, light: .white)
        case .go: return Dynamic.color(dark: Dynamic.rgb(0, 0.14, 0.04), light: .white)
        }
    }
}

// MARK: - Text helpers

struct Kicker: View {
    let text: String
    var color: Color = HP.text3
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A number that rolls rather than snapping when it changes.
struct RollingNumber: View {
    let value: Double
    let text: String
    var size: CGFloat = 17
    var weight: Font.Weight = .bold
    var color: Color = HP.text
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText(value: value))
            .animation(HMotion.tick, value: value)
            .lineLimit(1)
    }
}

// MARK: - Charts

/// A filled line chart for a fixed-length history, drawn with Canvas so a
/// once-a-second redraw costs a path, not a view tree.
struct Sparkline: View {
    let values: [Double]
    var maxValue: Double? = nil
    var color: Color
    var lineWidth: CGFloat = 1.5
    var fillOpacity: Double = 0.2
    var secondary: [Double]? = nil
    var secondaryColor: Color = HP.text3

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = maxValue ?? max(values.max() ?? 1, secondary?.max() ?? 0, 0.0001) * 1.15
            func path(_ series: [Double], closed: Bool) -> Path {
                var p = Path()
                let dx = size.width / CGFloat(series.count - 1)
                for (i, v) in series.enumerated() {
                    let y = size.height - CGFloat(min(max(v, 0), top) / top) * (size.height - lineWidth)
                    let pt = CGPoint(x: CGFloat(i) * dx, y: y)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                if closed {
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.addLine(to: CGPoint(x: 0, y: size.height))
                    p.closeSubpath()
                }
                return p
            }
            context.fill(path(values, closed: true), with: .color(color.opacity(fillOpacity)))
            context.stroke(path(values, closed: false), with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if let secondary, secondary.count > 1 {
                context.stroke(path(secondary, closed: false), with: .color(secondaryColor),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [2, 2]))
            }
        }
    }
}

/// Two series mirrored about a centre line: download above, upload below
/// (or read above, written below). Each half scales to its own peak so a quiet
/// upload is still a shape rather than a flat line under a busy download.
struct MirrorSparkline: View {
    let above: [Double]
    let below: [Double]
    var aboveColor: Color
    var belowColor: Color
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            func draw(_ series: [Double], sign: CGFloat, color: Color) {
                guard series.count > 1 else { return }
                let top = max(series.max() ?? 0, 0.0001) * 1.15
                let dx = size.width / CGFloat(series.count - 1)
                var line = Path()
                for (i, v) in series.enumerated() {
                    let y = mid - sign * CGFloat(max(v, 0) / top) * (mid - lineWidth)
                    let pt = CGPoint(x: CGFloat(i) * dx, y: y)
                    if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: mid))
                area.addLine(to: CGPoint(x: 0, y: mid))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.2)))
                context.stroke(line, with: .color(color),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
            draw(above, sign: 1, color: aboveColor)
            draw(below, sign: -1, color: belowColor)
        }
    }
}

/// A ring with the forecast drawn onto it: the solid arc is what is spent, the
/// translucent arc continuing from it is what the current pace spends before
/// the reset. If the two together close the circle, the window does not
/// survive to its reset — the same reading the old forecast bar gave, now in
/// the instrument people already look at.
///
/// Anchored at twelve and sweeping anti-clockwise, like every ring in Hotch.
struct ForecastRing: View {
    /// Share to paint solid, 0...1, nil for unmeasured.
    let share: Double?
    /// Additional share the current pace adds by the reset, 0...1.
    var projected: Double = 0
    let isCritical: Bool
    let color: Color
    var active: Bool = true
    var size: CGFloat = 44
    var lineWidth: CGFloat = 4.5

    private var solid: Double { min(1, max(0, share ?? 0)) }
    private var extra: Double { min(1 - solid, max(0, projected)) }

    var body: some View {
        ZStack {
            Circle().stroke(share == nil ? HP.track.opacity(0.6) : HP.track, lineWidth: lineWidth)
            if share != nil {
                Circle()
                    .trim(from: active ? max(0, 1 - solid - extra) : 1, to: active ? 1 - solid : 1)
                    .stroke(color.opacity(0.32), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(HMotion.reduceMotion ? nil : .easeOut(duration: 0.3), value: active)
                Circle()
                    .trim(from: active ? 1 - solid : 1, to: 1)
                    .stroke(isCritical ? HP.red : color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: isCritical ? HP.red.opacity(0.6) : .clear, radius: 4)
                    .animation(HMotion.reduceMotion ? nil : .easeOut(duration: PanelMotion.ringSweep), value: active)
                    .animation(HMotion.tick, value: solid)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capacity meter")
        .accessibilityValue(share.map { "\(Int(($0 * 100).rounded())) percent, \(isCritical ? "limit nearly reached" : "measured")" } ?? "No reading")
    }
}

/// A thin horizontal bar made of segments (memory composition, disk used).
struct SegmentBar: View {
    struct Segment: Identifiable { let id = UUID(); let fraction: Double; let color: Color }
    let segments: [Segment]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, seg.fraction))) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(HP.track)
            .clipShape(Capsule(style: .continuous))
            .animation(HMotion.tick, value: segments.map(\.fraction))
        }
        .frame(height: height)
    }
}

// MARK: - Tab bar

/// Icon tabs with a sliding pill; the selected tab grows to show its label.
/// The pill is one view moved with `matchedGeometryEffect`, so it travels
/// between tabs on a spring instead of fading out of one and into another.
struct HotchTabBar: View {
    @Binding var selection: PanelPage
    var pages: [PanelPage] = PanelPage.allCases
    var dimSelection: Bool = false
    /// The compact card's smaller row.
    var compact: Bool = false
    var onSelect: (PanelPage) -> Void = { _ in }
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pages, id: \.rawValue) { page in
                let selected = page == selection && !dimSelection
                Button {
                    onSelect(page)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: page.symbol)
                            .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
                            .frame(width: compact ? 14 : 16, height: compact ? 14 : 16)
                        if selected {
                            Text(page.title)
                                .font(.system(size: compact ? 11.5 : 12, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .transition(HMotion.reduceMotion ? .identity : .opacity)
                        }
                    }
                    .padding(.horizontal, selected ? (compact ? 8 : 11) : (compact ? 5 : 8))
                    .frame(height: compact ? 26 : 28)
                    .foregroundStyle(selected ? HP.text : HP.text3)
                    .background {
                        if selected {
                            Capsule(style: .continuous)
                                .fill(HP.pill)
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(KeyboardFocusRing(radius: 20))
                .help(page.title)
                .accessibilityLabel(page.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(compact ? 2 : 3)
        .background(Capsule(style: .continuous).fill(HP.tile))
        .overlay(Capsule(style: .continuous).strokeBorder(HP.stroke, lineWidth: 1))
        .animation(HMotion.tab, value: selection)
        .animation(HMotion.tab, value: dimSelection)
    }
}

// MARK: - Formatting for system values

enum SysFmt {
    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))" }

    static func bytes(_ b: UInt64, decimals: Int = 1) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 100 { return "\(Int(gb.rounded())) GB" }
        if gb >= 1 { return String(format: "%.\(decimals)f GB", gb) }
        let mb = Double(b) / 1_048_576
        if mb >= 1 { return "\(Int(mb.rounded())) MB" }
        return "\(Int((Double(b) / 1024).rounded())) KB"
    }

    static func gigabytes(_ b: UInt64) -> String {
        String(format: "%.1f", Double(b) / 1_073_741_824)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1000 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        return mb < 100 ? String(format: "%.1f MB/s", mb) : "\(Int(mb.rounded())) MB/s"
    }

    /// Compact form for tiles and the menu bar: "1.2M", "84K".
    static func rateShort(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1 { return "0K" }
        if kb < 1000 { return "\(Int(kb.rounded()))K" }
        let mb = kb / 1024
        return mb < 100 ? String(format: "%.1fM", mb) : "\(Int(mb.rounded()))M"
    }

    static func temp(_ c: Double?) -> String? {
        c.map { "\(Int($0.rounded()))°" }
    }

    static func minutes(_ m: Int?) -> String? {
        guard let m, m > 0 else { return nil }
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    static func thermal(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
