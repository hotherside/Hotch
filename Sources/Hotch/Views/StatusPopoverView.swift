import SwiftUI

/// The menu bar surface: the same six sections as the notch panel, laid out
/// for a narrow column. It is the whole app in clamshell or on an external
/// display, so it carries everything the panel does.
///
/// The popover **follows the system appearance**, unlike the panel: it is an
/// ordinary menu bar extra sitting next to Wi-Fi and Battery, and on a light
/// Mac it should look like them. Every colour in the sections is dynamic, so
/// the same views draw on both surfaces.
enum PopoverTheme {
    static let width: CGFloat = 380
    static let contentPadding: CGFloat = 16

    static let heroSize: CGFloat = 17
    static let titleSize: CGFloat = 12.5
    static let valueSize: CGFloat = 15
    static let bodySize: CGFloat = 12
    static let captionSize: CGFloat = 11
    static let microSize: CGFloat = 11
    static let material: Material = .ultraThinMaterial
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let mutedText = Color.secondary
    static let track = Color.primary.opacity(0.12)
    static let trackDim = Color.primary.opacity(0.06)
    static let divider = Color.primary.opacity(0.10)
    static let meterHeight: CGFloat = 6
    static let selection = Color.primary.opacity(0.10)
    static let snapshotBackground = Color(nsColor: .windowBackgroundColor)

    /// Tallest the popover's section area may be before it scrolls, so a busy
    /// machine cannot push it off the bottom of a 14" screen.
    static let maxSectionHeight: CGFloat = 560
}

/// Horizontal meter, still used by the focus and clipboard sections.
struct MeterBar: View {
    let share: Double?
    let isCritical: Bool
    let identity: ProviderIdentity

    private var effectiveIdentity: ProviderIdentity {
        isCritical ? ProviderIdentity.warning : identity
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(share == nil ? PopoverTheme.trackDim : PopoverTheme.track)
                if let share {
                    let fraction = min(1, max(0, share))
                    Capsule(style: .continuous)
                        .fill(effectiveIdentity.gradient)
                        .frame(width: max(fraction > 0 ? PopoverTheme.meterHeight : 0,
                                          geo.size.width * fraction))
                }
            }
        }
        .frame(height: PopoverTheme.meterHeight)
    }
}

/// Which section the popover shows. Its own model rather than the panel's: the
/// popover can be open while the panel is not, and flipping one surface's page
/// under the other would read as a haunting.
@MainActor
final class PopoverPageModel: ObservableObject {
    @Published var page: PanelPage = .home
    @Published var macDetail: SystemDetailKind?
    @Published var backpackCard = false
    /// Set by the status item while the popover is on screen; the content
    /// is only rendered then.
    @Published var isShown = false

    func change(by delta: Int) {
        if let target = PanelPage(rawValue: page.rawValue + delta) {
            select(target)
        }
    }

    func select(_ target: PanelPage) {
        withAnimation(HMotion.section) {
            page = target
            macDetail = nil
            backpackCard = false
        }
    }
}

struct StatusPopoverContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var focus: FocusStore
    @ObservedObject var pages: PopoverPageModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var backpack: BackpackManager
    let now: Date
    var history: UsageHistoryStore = .shared
    var flatBackground: Bool = false
    var scrollable: Bool = true
    var onRefresh: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var onSignInClaude: () -> Void = {}
    @State private var demandClient = "popover-\(UUID().uuidString)"

    private var columnWidth: CGFloat { PopoverTheme.width - PopoverTheme.contentPadding * 2 }

    private var nav: SectionNav {
        SectionNav(go: { pages.select($0) },
                   openDetail: { kind in
                       withAnimation(HMotion.detail) {
                           if pages.page != .mac { pages.page = .mac }
                           pages.macDetail = kind
                       }
                   },
                   openSettings: onOpenSettings,
                   signInClaude: onSignInClaude,
                   openBackpack: { withAnimation(HMotion.section) { pages.backpackCard = true } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HotchTabBar(selection: Binding(get: { pages.page }, set: { pages.select($0) }),
                            dimSelection: pages.backpackCard,
                            compact: true,
                            onSelect: { pages.select($0) })
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            section
                .frame(width: columnWidth, alignment: .topLeading)

            Rectangle()
                .fill(HP.stroke)
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 9)

            footer
        }
        .padding(.horizontal, PopoverTheme.contentPadding)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: PopoverTheme.width, alignment: .leading)
        .background(flatBackground ? AnyShapeStyle(PopoverTheme.snapshotBackground)
                                   : AnyShapeStyle(PopoverTheme.material))
        .onAppear { system.setDemand(.panel, for: demandClient) }
        .onDisappear { system.setDemand(.idle, for: demandClient) }
    }

    private var sectionIdentity: String {
        pages.backpackCard ? "backpack" : "\(pages.page.rawValue)-\(pages.macDetail?.rawValue ?? "")"
    }

    private var section: some View {
        SectionViewport(identity: sectionIdentity, maximumHeight: PopoverTheme.maxSectionHeight,
                        scrollable: scrollable) {
            sectionContent
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        let layout = SectionLayout.popover(width: columnWidth)
        Group {
            if pages.backpackCard {
                BackpackCard(backpack: backpack, sessions: sessionStore.sessions, now: now,
                             layout: layout, active: true)
            } else {
                switch pages.page {
                case .home:
                    NowSection(store: store, sessionStore: sessionStore, system: system, history: history,
                               now: now, active: true, layout: layout, nav: nav, backpack: backpack)
                case .ai:
                    VStack(alignment: .leading, spacing: 14) {
                        AISection(store: store, history: history, now: now, active: true, layout: layout, nav: nav)
                        AgentsSection(sessions: sessionStore.sessions, now: now, active: true, layout: layout)
                    }
                case .mac:
                    MacSection(system: system, detail: pages.macDetail, active: true, layout: layout, nav: nav)
                case .desk:
                    VStack(alignment: .leading, spacing: 14) {
                        PopoverFocusSection(focus: focus, now: now)
                        PopoverClipboardSection(items: clipboard.items, enabled: clipboard.enabled, now: now,
                                                onCopy: { clipboard.copyBack($0) })
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Text(Fmt.ago(store.lastRefresh, now: now).map { "updated \($0)" } ?? "never updated")
                .font(.system(size: PopoverTheme.captionSize))
                .foregroundStyle(HP.text3)
            Spacer(minLength: 6)
            BackpackShortcut(backpack: backpack, selected: pages.backpackCard) {
                withAnimation(HMotion.section) { pages.backpackCard.toggle() }
            }
            iconButton("arrow.clockwise", help: "Refresh now", action: onRefresh)
            iconButton("gearshape", help: "Settings", action: onOpenSettings)
            iconButton("power", help: "Quit Hotch", action: onQuit)
        }
    }

    private func iconButton(_ symbol: String, help: String, tint: Color = HP.text2,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help(help)
    }
}

/// Live popover, driven by a one-second clock.
struct StatusPopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var focus: FocusStore
    @ObservedObject var pages: PopoverPageModel
    @ObservedObject var system: SystemMonitor
    @ObservedObject var backpack: BackpackManager
    var onRefresh: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void
    var onSignInClaude: () -> Void = {}
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            StatusPopoverContent(store: store,
                                 sessionStore: sessionStore,
                                 clipboard: clipboard,
                                 focus: focus,
                                 pages: pages,
                                 system: system,
                                 backpack: backpack,
                                 now: context.date,
                                 onRefresh: onRefresh,
                                 onOpenSettings: onOpenSettings,
                                 onQuit: onQuit,
                                 onSignInClaude: onSignInClaude)
        }
        .environment(\.usageDisplayMode, settings.displayMode)
    }
}
