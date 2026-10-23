import AppKit
import Foundation

/// `--check-notch`: clearance, display coordinates, compact clock rollover,
/// and migration checks without opening a window or changing real defaults.
enum NotchGeometryCheck {
    @MainActor
    static func runBlockingAndExit() -> Never {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("  \(condition ? "ok  " : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }
        for frame in [CGRect(x: 0, y: 0, width: 1512, height: 982),
                      CGRect(x: -1920, y: 400, width: 1920, height: 1080),
                      CGRect(x: 1512, y: -900, width: 1440, height: 900)] {
            for real in [true, false] {
                let clearance: CGFloat = real ? 37 : NotchGeometryResolver.virtualClearance
                let cutout = CGRect(x: frame.midX - 100, y: frame.maxY - clearance, width: 200, height: clearance)
                let geometry = NotchGeometryResolver.assemble(screenFrame: frame, notch: cutout,
                                                              clearance: clearance,
                                                              contentHeight: PanelMetrics.maxBelowStrip, isReal: real)
                let content = NotchGeometryResolver.contentRect(for: geometry)
                check("\(real ? "real" : "virtual") content clears the top strip at \(frame.origin)",
                      abs(content.maxY - (frame.maxY - clearance)) < 0.01)
                check("panel remains centred on its display", abs(geometry.panelRect.midX - frame.midX) < 0.01)
                check("panel overlaps the bezel to avoid a wallpaper seam",
                      geometry.panelRect.maxY > frame.maxY)
                let badge = NotchFocusBadgeController.frame(for: geometry, running: true)
                check("Focus badge stays inside its display", frame.contains(badge))
                if real {
                    check("Focus clock is wholly below the camera cutout", badge.maxY <= cutout.minY)
                    check("Focus tab connects within the camera width", badge.minX >= cutout.minX && badge.maxX <= cutout.maxX)
                } else {
                    check("virtual Focus clock is centred", badge.midX == frame.midX)
                    check("virtual clock leaves menu items clear", badge.maxY <= cutout.minY)
                }
            }
        }
        check("countdown rounds up through its last second", AnchorFocusClock.text(0.2, countingDown: true) == "0:01")
        check("elapsed clock only shows completed seconds", AnchorFocusClock.text(59.9, countingDown: false) == "0:59")
        check("minute rollover keeps a familiar clock", AnchorFocusClock.text(60, countingDown: false) == "1:00")
        check("long Focus clocks name hours within five characters", AnchorFocusClock.text(3661, countingDown: false) == "1h01")
        check("longest open run fits its rail target", AnchorFocusClock.text(FocusStore.openEndedCap, countingDown: false).count <= 5)
        let suite = "com.hotch.notch-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("notch", forKey: "anchor")
        check("legacy notch preference restores the notch", HotchPrefs(defaults: defaults).anchor == .notch)
        for anchor in HotchPrefs.Anchor.allCases {
            defaults.set(anchor.rawValue, forKey: "anchor")
            check("saved \(anchor.label) placement survives", HotchPrefs(defaults: defaults).anchor == anchor)
        }
        print(failures == 0 ? "Notch checks passed." : "\(failures) notch checks failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
