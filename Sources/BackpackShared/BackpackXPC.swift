import Foundation

/// Everything Hotch and its Backpack helper have to agree on.
///
/// Backpack mode keeps the Mac awake with the lid closed. The only switch for
/// that is the root-only power setting `SleepDisabled` (`pmset -a disablesleep 1`),
/// so a small LaunchDaemon flips it on request and always flips it back. This
/// file is compiled into both the app and the daemon; a mismatch between the two
/// copies is what `protocolVersion` exists to catch.
public enum BackpackXPC {
    /// Mach service the daemon listens on. Also the launchd Label.
    public static let machServiceName = "com.hojaejung.hotch.backpack"
    /// File name inside `Contents/Library/LaunchDaemons/` that `SMAppService.daemon(plistName:)` looks up.
    public static let daemonPlistName = "com.hojaejung.hotch.backpack.plist"
    /// Executable name inside `Contents/MacOS/`.
    public static let helperExecutableName = "HotchBackpackHelper"

    public static let appIdentifier = "com.hojaejung.hotch"
    /// Code-signing identifier the helper is signed with (`codesign --identifier`).
    public static let helperIdentifier = "com.hojaejung.hotch.backpack"
    public static let teamIdentifier = "WCJ787853P"

    /// Bumped whenever a method or its meaning changes. The app refuses to start a
    /// session against a helper that answers with a different number.
    public static let protocolVersion = 1
    public static let helperBuild = "1.0.0"

    /// The app pings this often while a session is on.
    public static let heartbeatInterval: TimeInterval = 30
    /// The helper restores sleep when it has heard nothing for this long.
    public static let heartbeatTimeout: TimeInterval = 3 * 60
    /// The app ends a session at 4 h; the helper's own cap sits 15 min later as a backstop.
    public static let appTimeLimit: TimeInterval = 4 * 60 * 60
    public static let helperHardCap: TimeInterval = 4 * 60 * 60 + 15 * 60
    /// The helper exits when it has had no session and no connections for this long.
    public static let idleExitDelay: TimeInterval = 30

    /// Written before anything is changed, removed after everything is restored.
    /// Its presence at helper launch means a session was cut short, so the helper
    /// puts things back.
    public static let markerPath = "/Library/Application Support/Hotch/backpack-active.json"

    /// Requirement the helper places on its clients, and the app on the helper.
    /// `anchor apple generic` plus the team OU accepts Developer ID builds from this
    /// team only; ad-hoc builds never satisfy it.
    public static func requirement(identifier: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    public static var appRequirement: String { requirement(identifier: appIdentifier) }
    public static var helperRequirement: String { requirement(identifier: helperIdentifier) }

    public static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: BackpackHelperProtocol.self)
    }
}

/// The helper's XPC surface. Every reply block is called exactly once.
///
/// The Objective-C name is fixed so both sides agree regardless of which Swift
/// module the protocol is compiled into.
@objc(HotchBackpackHelperProtocol)
public protocol BackpackHelperProtocol {
    /// Disables sleep (and, if asked, turns on Low Power Mode) and starts the
    /// session. `note` carries anything worth showing, such as "Low Power Mode was
    /// already on". Calling it while a session is on hands the session to the caller.
    func begin(lowPower: Bool, reply: @escaping (_ ok: Bool, _ note: String?) -> Void)

    /// Restores everything Hotch changed and ends the session. Safe to call when
    /// nothing is active.
    func end(reply: @escaping (_ ok: Bool, _ note: String?) -> Void)

    /// Keeps the session alive. `active` is false once the helper has ended the
    /// session by itself; `note` then says why.
    func heartbeat(reply: @escaping (_ active: Bool, _ note: String?) -> Void)

    /// Current `SleepDisabled` value, whether a session is on, and a short note.
    func status(reply: @escaping (_ sleepDisabled: Bool, _ active: Bool, _ note: String?) -> Void)

    func helperVersion(reply: @escaping (_ protocolVersion: Int, _ build: String) -> Void)
}
