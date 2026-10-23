import AppKit
import Combine
import SwiftUI

/// A clock that fits a permanent 34pt rail target without shrinking six or
/// eight digits to illegibility. Long runs explicitly switch to hours.
enum AnchorFocusClock {
    static func text(_ interval: TimeInterval, countingDown: Bool) -> String {
        let safe = interval.isFinite ? min(86_400_000, max(0, interval)) : 0
        let total = Int(countingDown ? safe.rounded(.up) : safe.rounded(.down))
        if total >= 3600 { return String(format: "%dh%02d", total / 3600, (total % 3600) / 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @MainActor
    static func readout(_ focus: FocusStore, now: Date = Date()) -> (value: String, caption: String)? {
        let remaining = focus.remaining(now: now)
        guard let interval = remaining ?? focus.elapsed(now: now) else { return nil }
        let direction = remaining == nil ? "elapsed" : "remaining"
        return (text(interval, countingDown: remaining != nil),
                focus.isPaused ? "paused · \(direction)" : direction)
    }
}

/// The shared FocusStore tick is the only clock for anchor readouts. A paused
/// run publishes its state once and then remains still.
struct AnchorFocusReadout: View {
    enum Style { case rail, inline }
    @ObservedObject var focus: FocusStore
    var style: Style
    private var symbol: String { focus.isPaused ? "pause.fill" : (focus.isOpenEnded ? "stopwatch" : "timer") }

    var body: some View {
        Group {
            if let time = AnchorFocusClock.readout(focus) {
                if style == .rail {
                    VStack(spacing: 1) {
                        Image(systemName: symbol)
                            .font(.system(size: 9, weight: .semibold))
                        Text(time.value).font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .frame(width: RailGeometry.slot, height: RailGeometry.slot)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: symbol)
                        Text(time.value)
                    }
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 4)
                }
            } else if style == .rail {
                Image(systemName: PanelPage.focus.symbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(HP.text3)
            }
        }
        .foregroundStyle(focus.isPaused ? HP.amber : HP.text)
        .monospacedDigit()
        .fixedSize()
        .help(AnchorFocusClock.readout(focus).map { "Focus: \($0.value) \($0.caption) · \(focus.runningLabel ?? "Focus time")" } ?? "Focus")
        .accessibilityLabel("Focus")
        .accessibilityValue(AnchorFocusClock.readout(focus).map { "\($0.value) \($0.caption)" } ?? "No timer running")
        .transaction { $0.animation = nil }
    }
}

/// A small black clock tab below a real cutout, or a virtual notch below an
/// external display's menu strip. Hardware and menu items remain unobstructed.
@MainActor
final class NotchFocusBadgeController {
    private let panel: NotchPanel
    private let focus: FocusStore
    private var observation: AnyCancellable?
    private var geometry: NotchGeometry?
    var suppressed = false { didSet { refresh() } }
    var onTap: () -> Void = {}
    var frame: CGRect? { panel.isVisible ? panel.frame : nil }

    init(focus: FocusStore) {
        self.focus = focus
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = FirstMouseHostingView(rootView: NotchFocusBadge(focus: focus, onTap: { [weak self] in self?.onTap() }))
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        panel.contentView = host
        observation = focus.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }
    }

    func place(_ geometry: NotchGeometry) {
        self.geometry = geometry
        refresh()
    }

    func stop() {
        suppressed = true
        observation?.cancel()
        panel.orderOut(nil)
    }

    private func refresh() {
        guard let geometry, !suppressed, focus.isRunning || !geometry.isRealNotch else {
            panel.orderOut(nil)
            return
        }
        let target = Self.frame(for: geometry, running: focus.isRunning)
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    static func frame(for geometry: NotchGeometry, running: Bool) -> CGRect {
        let height: CGFloat = 25
        let width: CGFloat = running ? 104 : 68
        return CGRect(x: geometry.notchRect.midX - width / 2,
                      y: geometry.notchRect.minY - height, width: width, height: height)
    }
}

private struct NotchFocusBadge: View {
    @ObservedObject var focus: FocusStore
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Group {
                if focus.isRunning {
                    AnchorFocusReadout(focus: focus, style: .inline)
                } else {
                    Image(nsImage: HotchIcon.statusBarImage(pointSize: 15)).foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .help("Hotch · hover to open")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(focus.isRunning ? "Focus" : "Hotch")
        .accessibilityValue(AnchorFocusClock.readout(focus).map { "\($0.value) \($0.caption)" } ?? "Open Hotch")
    }
}
