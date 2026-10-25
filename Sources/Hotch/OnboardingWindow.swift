import AppKit
import SwiftUI

/// The welcome: a short letter, then one screen to choose placement and
/// providers. Preferences apply live so placement can be tried before
/// finishing; closing early leaves welcome available next launch.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private var window: NSWindow?
    /// Bumped by every show and finish, so a fade that finishes after a
    /// replay began leaves the new welcome alone.
    private var generation = 0
    private var finishing = false
    var onOpenSettings: () -> Void = {}
    var onExplainInstall: () -> Void = {}
    /// Placement changed while choosing, so the app can point at the new spot.
    var onPlacementChange: () -> Void = {}
    /// Finished. Passes where the window was, for the signal to leave from.
    var onFinish: (CGRect) -> Void = { _ in }

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if let window, window.isVisible, !finishing {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        generation += 1
        finishing = false
        let view = OnboardingView(settings: settings,
                                  installNote: WelcomeCopy.installNote(
                                      installed: InstallLocation.isProperlyInstalled,
                                      onDiskImage: InstallLocation.isOnMountedVolume),
                                  onExplainInstall: { [weak self] in self?.onExplainInstall() },
                                  onOpenSettings: { [weak self] in self?.onOpenSettings() },
                                  onPlacementChange: { [weak self] in
                                      // Only while it is on screen and choosing.
                                      guard let self, self.window?.isVisible == true, !self.finishing else { return }
                                      self.onPlacementChange()
                                  },
                                  onFinish: { [weak self] in self?.finish() })
        let window = self.window ?? Self.makeWindow(delegate: self)
        self.window = window
        // A new view each time, so a replay from Settings greets afresh. The
        // window keeps the size given here; the letter and setup fill it.
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = WelcomeStyle.windowSize(for: screen)
        window.setContentSize(size)
        // The middle of the screen, not AppKit's upper-third `center()`.
        if let visible = screen?.visibleFrame {
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        }
        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // macOS may defer activation when another app launched Hotch. The
        // greeting still comes to the front; a click on it makes it key.
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HMotion.reduceMotion ? 0.15 : 0.35
            window.animator().alphaValue = 1
        }
    }

    /// A titled window with its title bar folded into the content: native
    /// corners, shadow, close button, dragging and keyboard, without chrome.
    static func makeWindow(_ kind: WelcomeWindow.Type = WelcomeWindow.self,
                           delegate: NSWindowDelegate?) -> NSWindow {
        let window = kind.init(contentRect: CGRect(origin: .zero, size: CGSize(width: WelcomeStyle.width, height: 560)),
                                   styleMask: [.titled, .closable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.title = "Welcome to Hotch"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.delegate = delegate
        return window
    }

    private func finish() {
        // A second Return or click during the fade is the same finish.
        guard !finishing else { return }
        finishing = true
        settings.completeWelcome()
        guard let window else { finishing = false; onFinish(.zero); return }
        let origin = window.frame
        let shown = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HMotion.reduceMotion ? 0.12 : 0.28
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.generation == shown else { return }
                window.orderOut(nil)
                window.alphaValue = 1
                self.release(window)
            }
        })
        onFinish(origin)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        release(window)
    }

    /// A hidden view would keep watching preferences and readiness, and
    /// point at the companion whenever it moved, for the rest of the session.
    private func release(_ window: NSWindow) {
        window.contentView = nil
        finishing = false
    }
}

/// Esc closes the letter (setup's Back takes it first), and ⌘W closes the
/// window, which an accessory app's menu does not otherwise offer.
class WelcomeWindow: NSWindow {
    required override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                           backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct OnboardingView: View {
    enum Phase { case letter, setup }

    @ObservedObject var settings: AppSettings
    @ObservedObject var prefs: HotchPrefs = .shared
    /// Why this copy cannot keep working from where it is, if it cannot.
    var installNote: String? = nil
    var onExplainInstall: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onPlacementChange: () -> Void = {}
    var onFinish: () -> Void = {}
    /// Rendered docs choose the phase and the moment of the greeting.
    var initialPhase: Phase = .letter
    var frozenAt: TimeInterval? = nil
    /// Rendered docs show a fixed set of providers instead of this Mac's.
    var readyOverride: Set<String>? = nil

    @State private var phase: Phase?
    /// Back from setup shows the letter as it was left, not greeting again.
    @State private var letterRead = false
    @State private var readyIDs: Set<String> = []

    private var current: Phase { phase ?? initialPhase }

    var body: some View {
        ZStack {
            switch current {
            case .letter:
                WelcomeLetterView(installNote: installNote,
                                  frozenAt: frozenAt ?? (letterRead ? WelcomeTimeline.duration : nil),
                                  onExplainInstall: onExplainInstall,
                                  onContinue: { go(to: .setup) })
                    .transition(slide(forward: false))
            case .setup:
                setup.transition(slide(forward: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refreshReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
        .onChange(of: prefs.anchor) { if current == .setup { onPlacementChange() } }
        .onChange(of: prefs.edgeSide) { if current == .setup { onPlacementChange() } }
    }

    private func go(to next: Phase) {
        if next == .setup { letterRead = true }
        if let animation = HMotion.section {
            withAnimation(animation.speed(0.6)) { phase = next }
        } else {
            phase = next
        }
    }

    private func slide(forward: Bool) -> AnyTransition {
        guard !HMotion.reduceMotion else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
                           removal: .opacity.combined(with: .offset(x: forward ? 28 : -28)))
    }

    // MARK: Setup

    private var setup: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        WelcomeMark(timeline: .settled, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(WelcomeCopy.setupTitle)
                                .font(.system(size: 20, weight: .semibold))
                                .tracking(-0.3)
                                .accessibilityAddTraits(.isHeader)
                            Text(WelcomeCopy.setupSubtitle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    placement
                    Divider()
                    providers
                    Divider()
                    clipboard
                }
                .padding(.horizontal, 30)
                .padding(.top, 38)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Back") { go(to: .letter) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start using Hotch", action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
        }
    }

    private var placement: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(HotchPrefs.Anchor.allCases) { anchor in
                    Button { prefs.anchor = anchor } label: {
                        PlacementTile(anchor: anchor, side: prefs.edgeSide, selected: prefs.anchor == anchor)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel(anchor.label)
                    .accessibilityHint(PlacementTile.detail(anchor))
                    .accessibilityAddTraits(prefs.anchor == anchor ? [.isSelected] : [])
                }
            }
            // One stop for the keyboard, reached by Tab when Full Keyboard
            // Access is on (as buttons are); the arrow keys then move Hotch,
            // the way a segmented control behaves.
            .focusable(interactions: .activate)
            .onMoveCommand { direction in
                let all = HotchPrefs.Anchor.allCases
                guard let index = all.firstIndex(of: prefs.anchor) else { return }
                switch direction {
                case .left where index > all.startIndex: prefs.anchor = all[index - 1]
                case .right where index < all.endIndex - 1: prefs.anchor = all[index + 1]
                default: break
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Where Hotch lives")
            HStack(alignment: .center, spacing: 12) {
                Text(PlacementTile.detail(prefs.anchor))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if prefs.anchor == .edge {
                    Picker("Screen edge", selection: $prefs.edgeSide) {
                        ForEach([HotchPrefs.EdgeSide.left, .right, .bottom]) { side in
                            Text(side.label).tag(side)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .frame(minHeight: 24)
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Providers on this Mac").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Check Again") { refreshReadiness() }
                    .controlSize(.small)
            }
            if readyIDs.isEmpty {
                Text("No signed-in provider found yet. Connect Claude Code, Codex or an API key in Settings whenever you’re ready.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(ProviderCatalog.all.filter { readyIDs.contains($0.id) }) { provider in
                    Toggle(provider.name, isOn: Binding(
                        get: { settings.isEnabled(provider.id) },
                        set: { settings.setEnabled($0, providerID: provider.id) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                }
            }
            Text("Found by checking local sign-in status only. Providers you keep on fetch usage from their own services.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Provider Settings…", action: onOpenSettings)
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    private var clipboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Remember recent clipboard text", isOn: $settings.clipboardHistoryEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
            Text("Optional. Up to \(ClipboardStore.maxItems) text clips, kept in memory until you quit. Concealed items are skipped.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshReadiness() {
        readyIDs = readyOverride ?? ProviderReadiness.configuredIDs(among: ProviderCatalog.all.map(\.id))
    }
}

/// A placement as a tiny screen with the companion drawn where it would sit.
struct PlacementTile: View {
    var anchor: HotchPrefs.Anchor
    var side: HotchPrefs.EdgeSide
    var selected: Bool

    static func title(_ anchor: HotchPrefs.Anchor) -> String {
        switch anchor {
        case .edge: return "Screen edge"
        case .notch: return "Notch"
        case .pill: return "Pill"
        case .orb: return "Orb"
        case .menuBar: return "Menu bar"
        }
    }

    static func detail(_ anchor: HotchPrefs.Anchor) -> String {
        switch anchor {
        case .edge: return "A slim tab on the edge of your screen."
        case .notch: return "Opens from the notch, the original Hotch view."
        case .pill: return "A small pill that floats where you put it."
        case .orb: return "A small circle that floats where you put it."
        case .menuBar: return "Just the menu bar icon, nothing on screen."
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(width: 60, height: 40)
            Text(Self.title(anchor))
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.06),
                          lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
        let frame = Path(roundedRect: screen, cornerRadius: 5, style: .continuous)
        context.fill(frame, with: .color(.primary.opacity(0.05)))
        context.stroke(frame, with: .color(.primary.opacity(0.28)), lineWidth: 1)
        let bar = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 5)
        context.fill(Path(roundedRect: bar, cornerRadii: .init(topLeading: 5, topTrailing: 5)),
                     with: .color(.primary.opacity(0.13)))
        let warm = GraphicsContext.Shading.color(WelcomeStyle.signal)
        switch anchor {
        case .edge:
            switch side {
            case .right:
                context.fill(Path(roundedRect: CGRect(x: screen.maxX - 4.5, y: screen.midY - 7, width: 4.5, height: 17),
                                  cornerRadius: 2), with: warm)
            case .left:
                context.fill(Path(roundedRect: CGRect(x: screen.minX, y: screen.midY - 7, width: 4.5, height: 17),
                                  cornerRadius: 2), with: warm)
            case .bottom:
                let dock = CGRect(x: screen.midX - 14, y: screen.maxY - 6, width: 20, height: 4)
                context.fill(Path(roundedRect: dock, cornerRadius: 2), with: .color(.primary.opacity(0.22)))
                context.fill(Path(roundedRect: CGRect(x: dock.maxX + 3, y: dock.minY, width: 11, height: 4),
                                  cornerRadius: 2), with: warm)
            }
        case .notch:
            context.fill(Path(roundedRect: CGRect(x: screen.midX - 9, y: screen.minY, width: 18, height: 6.5),
                              cornerRadii: .init(bottomLeading: 3, bottomTrailing: 3)), with: warm)
        case .pill:
            context.fill(Path(roundedRect: CGRect(x: screen.maxX - 24, y: screen.minY + 10, width: 18, height: 6),
                              cornerRadius: 3), with: warm)
        case .orb:
            context.fill(Path(ellipseIn: CGRect(x: screen.maxX - 15, y: screen.minY + 10, width: 8, height: 8)), with: warm)
        case .menuBar:
            for x in [screen.maxX - 22, screen.maxX - 16] {
                context.fill(Path(ellipseIn: CGRect(x: x, y: screen.minY + 1.25, width: 2.5, height: 2.5)),
                             with: .color(.primary.opacity(0.35)))
            }
            context.fill(Path(ellipseIn: CGRect(x: screen.maxX - 9.5, y: screen.minY + 0.75, width: 3.5, height: 3.5)), with: warm)
        }
    }
}
