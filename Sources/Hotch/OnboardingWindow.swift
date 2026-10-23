import AppKit
import SwiftUI

/// A short native introduction. Preferences apply live so placement can be
/// tried before finishing; closing early leaves welcome available next launch.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let settings: AppSettings
    private var window: NSWindow?
    var onPreviewAlert: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onFinish: () -> Void = {}

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let height = min(570, max(350, (NSScreen.main?.visibleFrame.height ?? 800) - 70))
        let view = OnboardingView(settings: settings,
                                  onPreviewAlert: { [weak self] in self?.onPreviewAlert() },
                                  onOpenSettings: { [weak self] in self?.onOpenSettings() },
                                  onFinish: { [weak self] in self?.finish() })
        let hosting = NSHostingController(rootView: view)
        if let window {
            window.contentViewController = hosting
        } else {
            let created = NSWindow(contentViewController: hosting)
            created.title = "Welcome to Hotch"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.delegate = self
            window = created
        }
        window?.setContentSize(NSSize(width: 500, height: height))
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        settings.completeWelcome()
        window?.close()
        onFinish()
    }
}

struct OnboardingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var prefs = HotchPrefs.shared
    var onPreviewAlert: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onFinish: () -> Void = {}
    @State private var step = 0
    @State private var readyIDs: Set<String> = []
    @State private var sampled = false

    private let titles = ["A quiet companion.", "Make room for your work.", "Your Mac. Your choice."]
    private let subtitles = [
        "A small place for your agents, your attention and your Mac.",
        "Choose where Hotch lives. You can move it any time.",
        "Know what stays here and what connects to a provider.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        HotchBadge(size: 48)
                        Spacer()
                        Text("\(step + 1) OF 3")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(titles[step])
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .tracking(-0.7)
                        Text(subtitles[step])
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Group {
                        switch step {
                        case 0: introduction
                        case 1: placement
                        default: privacy
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                if step > 0 {
                    Button("Back") { step -= 1 }
                } else {
                    Text("About a minute to make it yours")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(step == 2 ? "Start using Hotch" : "Continue") {
                    if step < 2 { step += 1 } else { onFinish() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refreshReadiness() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshReadiness()
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 18) {
            feature("sparkle", "Keep your agents in sight", "See sessions and plan usage without leaving your work.")
            feature("timer", "Protect a little focus", "Start a timer, check your Mac and get back to what matters.")
            feature("bell.badge", "A gentle nudge", "Short alerts tell you when an agent needs you or finishes.")
            feature("backpack", "Take your agents with you", "Find Backpack in the Now view to learn about keeping agents working with the lid closed.")
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines")
                Text("Hover to peek. Click to keep the card open.")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            Text("The menu bar icon is always there. ⌥⌘H opens the card too when its shortcut is enabled.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var placement: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(HotchPrefs.Anchor.allCases) { anchor in
                    Button {
                        prefs.anchor = anchor
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: anchor))
                                .frame(width: 20)
                            Text(anchor.label).font(.system(size: 12, weight: .medium))
                            Spacer(minLength: 0)
                            if prefs.anchor == anchor {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(prefs.anchor == anchor ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(prefs.anchor == anchor ? Color.accentColor.opacity(0.5) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(prefs.anchor == anchor ? [.isSelected] : [])
                }
            }
            if prefs.anchor == .edge {
                Picker("Screen edge", selection: $prefs.edgeSide) {
                    ForEach(HotchPrefs.EdgeSide.allCases) { side in
                        Text(side.label).tag(side)
                    }
                }
                .pickerStyle(.segmented)
            }
            Divider()
            HStack {
                Text("Ready on this Mac").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Check again") { refreshReadiness() }.font(.system(size: 11))
            }
            if readyIDs.isEmpty {
                Text("No provider sign-in found yet. You can connect one in Settings whenever you’re ready.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(ProviderCatalog.all.filter { readyIDs.contains($0.id) }) { provider in
                    Toggle(provider.name, isOn: Binding(
                        get: { settings.isEnabled(provider.id) },
                        set: { settings.setEnabled($0, providerID: provider.id) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }
            Text("Detection checks local configuration and CLI sign-in status. It sends no credentials or requests to providers.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Provider settings…", action: onOpenSettings)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            feature("internaldrive", "Local by default", "Sessions, focus history and Mac readings stay on this Mac. There is no Hotch account or analytics service.")
            feature("network", "Usage comes from your providers", "Enabled providers contact their own services for usage and balance. Claude and Codex use their CLI sign-ins. API keys you add stay in Hotch’s support folder and go only to their provider.")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Remember recent clipboard text", isOn: $settings.clipboardHistoryEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .medium))
                Text("Optional. Up to \(ClipboardStore.maxItems) text clips, held in memory until you quit. Concealed items are skipped. Turning this off stops watching and clears the history.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            HStack(spacing: 10) {
                Button(sampled ? "Try alert again" : "Try a sample alert") {
                    sampled = true
                    onPreviewAlert()
                }
                .disabled(prefs.anchor == .menuBar)
                Text(prefs.anchor == .menuBar ? "Choose a screen companion to preview its alert." : "Look for it at your chosen companion.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func symbol(for anchor: HotchPrefs.Anchor) -> String {
        switch anchor {
        case .edge: return "sidebar.right"
        case .notch: return "macbook"
        case .pill: return "capsule"
        case .orb: return "circle"
        case .menuBar: return "menubar.rectangle"
        }
    }

    private func refreshReadiness() {
        readyIDs = ProviderReadiness.configuredIDs(among: ProviderCatalog.all.map(\.id))
    }
}
