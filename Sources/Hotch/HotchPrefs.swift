import Combine
import Foundation

/// Hotch 2's own preferences: the menu bar readouts, the notch alerts and the
/// system sensors. Kept apart from `AppSettings`, which owns the providers and
/// the display direction, so each file has one job.
@MainActor
final class HotchPrefs: ObservableObject {
    /// A demo tour keeps its placements in a scratch domain instead of the
    /// person's own. Set before anything reads `shared`; the app never sets it.
    nonisolated(unsafe) static var defaultsOverride: UserDefaults?
    static let shared = HotchPrefs(defaults: defaultsOverride ?? .standard)

    private let defaults: UserDefaults

    /// Mac readouts beside the usage percentage in the menu bar, iStat style.
    /// Off by default: the menu bar item stays one glyph and one number until
    /// someone asks for more.
    @Published var menuBarCPU: Bool { didSet { defaults.set(menuBarCPU, forKey: Keys.cpu) } }
    @Published var menuBarMemory: Bool { didSet { defaults.set(menuBarMemory, forKey: Keys.memory) } }
    @Published var menuBarNetwork: Bool { didSet { defaults.set(menuBarNetwork, forKey: Keys.network) } }

    /// Short live activities around the closed notch when something needs you.
    @Published var notchAlerts: Bool { didSet { defaults.set(notchAlerts, forKey: Keys.alerts) } }

    /// Temperatures, fans and power from the SMC and IOReport. Private
    /// interfaces, so they can be switched off if a macOS update upsets them.
    @Published var advancedSensors: Bool {
        didSet {
            defaults.set(advancedSensors, forKey: Keys.sensors)
            SystemMonitor.shared.advancedSensors = advancedSensors
        }
    }

    /// Where Hotch lives. Notch also works at the top centre of displays
    /// without a physical cutout.
    enum Anchor: String, CaseIterable, Identifiable {
        case edge, notch, pill, orb, menuBar
        var id: String { rawValue }
        var label: String {
            switch self {
            case .edge: return "Screen edge"
            case .notch: return "Notch"
            case .pill: return "Floating pill"
            case .orb: return "Floating orb"
            case .menuBar: return "Menu bar only"
            }
        }
    }

    /// Which screen edge the rail sits on. Bottom is the strip beside the
    /// Dock, which windows never use while the Dock is shown.
    enum EdgeSide: String, CaseIterable, Identifiable {
        case right, left, bottom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .right: return "Right"
            case .left: return "Left"
            case .bottom: return "Bottom"
            }
        }
    }

    @Published var anchor: Anchor { didSet { defaults.set(anchor.rawValue, forKey: Keys.anchor) } }
    @Published var edgeSide: EdgeSide { didSet { defaults.set(edgeSide.rawValue, forKey: Keys.edgeSide) } }
    /// Where the rail sits down the edge: 0 is the top of the usable screen,
    /// 1 the bottom. Dragging the tab changes it.
    @Published var edgeOffset: Double { didSet { defaults.set(edgeOffset, forKey: Keys.edgeOffset) } }
    /// Where the rail sits along the bottom edge, as a share of the screen's
    /// width (its centre). The left of the Dock by default.
    @Published var bottomOffset: Double { didSet { defaults.set(bottomOffset, forKey: Keys.bottomOffset) } }
    /// The display the rail, or the pill or orb, was last put on (its UUID).
    /// Nil until it is dragged somewhere: the main display.
    @Published var railDisplay: String? { didSet { defaults.set(railDisplay, forKey: Keys.railDisplay) } }
    @Published var floatDisplay: String? { didSet { defaults.set(floatDisplay, forKey: Keys.floatDisplay) } }
    /// Where the floating pill or orb sits, as a share of the usable screen.
    @Published var floatX: Double { didSet { defaults.set(floatX, forKey: Keys.floatX) } }
    @Published var floatY: Double { didSet { defaults.set(floatY, forKey: Keys.floatY) } }
    /// ⌥⌘H opens the card wherever Hotch lives.
    @Published var shortcutEnabled: Bool { didSet { defaults.set(shortcutEnabled, forKey: Keys.shortcut) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarCPU = defaults.object(forKey: Keys.cpu) as? Bool ?? false
        menuBarMemory = defaults.object(forKey: Keys.memory) as? Bool ?? false
        menuBarNetwork = defaults.object(forKey: Keys.network) as? Bool ?? false
        notchAlerts = defaults.object(forKey: Keys.alerts) as? Bool ?? true
        advancedSensors = defaults.object(forKey: Keys.sensors) as? Bool ?? true
        anchor = (defaults.string(forKey: Keys.anchor)).flatMap(Anchor.init(rawValue:)) ?? .edge
        edgeSide = (defaults.string(forKey: Keys.edgeSide)).flatMap(EdgeSide.init(rawValue:)) ?? .right
        edgeOffset = defaults.object(forKey: Keys.edgeOffset) as? Double ?? 0.38
        bottomOffset = defaults.object(forKey: Keys.bottomOffset) as? Double ?? 0.09
        railDisplay = defaults.string(forKey: Keys.railDisplay)
        floatDisplay = defaults.string(forKey: Keys.floatDisplay)
        floatX = defaults.object(forKey: Keys.floatX) as? Double ?? 1
        floatY = defaults.object(forKey: Keys.floatY) as? Double ?? 0
        shortcutEnabled = defaults.object(forKey: Keys.shortcut) as? Bool ?? true
    }

    var wantsMenuBarSystem: Bool { menuBarCPU || menuBarMemory || menuBarNetwork }

    private enum Keys {
        static let cpu = "menuBarCPU"
        static let memory = "menuBarMemory"
        static let network = "menuBarNetwork"
        static let alerts = "notchAlerts"
        static let sensors = "advancedSensors"
        static let anchor = "anchor"
        static let edgeSide = "edgeSide"
        static let edgeOffset = "edgeOffset"
        static let bottomOffset = "bottomOffset"
        static let railDisplay = "railDisplay"
        static let floatDisplay = "floatDisplay"
        static let floatX = "floatX"
        static let floatY = "floatY"
        static let shortcut = "shortcutEnabled"
    }
}
