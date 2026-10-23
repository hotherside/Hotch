import AppKit
import CoreGraphics

/// Displays by a lasting name, so Hotch stays on the display it was put on:
/// a display's UUID survives unplugging and reconnecting, where its number
/// and its place in `NSScreen.screens` do not.
@MainActor
enum Displays {
    static func id(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The display with this id, or the main display when it is not
    /// connected (or none was chosen yet).
    static func screen(withID id: String?) -> NSScreen? {
        if let id, let match = NSScreen.screens.first(where: { Self.id(of: $0) == id }) { return match }
        return NSScreen.screens.first
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

/// Notices an app filling a display in full screen (its own Space, menu bar
/// and Dock hidden), so Hotch can step aside instead of floating over a
/// video or a call. A full-screen window covers its display exactly,
/// menu bar strip included, which no ordinary window does; window bounds
/// need no Screen Recording permission. Checked when the Space or the
/// front app changes, and every few seconds as a safety net.
@MainActor
final class FullscreenWatcher {
    var onChange: () -> Void = {}
    private(set) var displays: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Space changes animate; look once it has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated { self?.check() }
                }
            })
        }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func isFullscreen(_ screen: NSScreen?) -> Bool {
        guard let screen, let id = Displays.id(of: screen) else { return false }
        return displays.contains(id)
    }

    private func check() {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let bounds: [CGRect] = windows.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != own,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return rect
        }
        var found: Set<String> = []
        for screen in NSScreen.screens {
            // Window bounds are top-left based, from the primary display.
            let f = screen.frame
            let target = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            let covered = bounds.contains {
                abs($0.minX - target.minX) < 1 && abs($0.minY - target.minY) < 1
                    && abs($0.width - target.width) < 1 && abs($0.height - target.height) < 1
            }
            if covered, let id = Displays.id(of: screen) { found.insert(id) }
        }
        guard found != displays else { return }
        displays = found
        onChange()
    }
}
