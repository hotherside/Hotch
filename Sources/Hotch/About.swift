import SwiftUI

/// Authorship and version, in one place.
///
/// Kept in the app rather than only in the repo, and surfaced in three places so
/// it travels with a copy someone was handed: the Settings footer, the menu bar
/// menu, and `NSHumanReadableCopyright` in the bundle (which is what Finder's Get
/// Info panel shows).
enum HotchAbout {
    static let author = "Hojae Jung"
    static let email = "hello@hotherside.com"

    /// Read out of the bundle, so `VERSION` in the Makefile is the one place a
    /// release number is written.
    ///
    /// This used to be a literal beside the Makefile's own, and the comment above
    /// it claimed there was "no second copy to drift" — which was simply untrue,
    /// and the sort of untrue that shows up as an app reporting one version while
    /// its disk image is named after another.
    static let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? developmentVersion
    }()

    /// Fallback for running the executable directly out of `.build/release`,
    /// which has no Info.plist to read. Still a second copy, so `make
    /// check-version` fails the build when it disagrees with `VERSION`.
    static let developmentVersion = "2.4.0"

    /// "Built by Hojae Jung (hello@hotherside.com)"
    static var credit: String { "Built by \(author) (\(email))" }
}

/// The app icon at a small size, for the Settings credit line. Drawn from the
/// same code as the real icon, so there is no asset to keep in sync.
struct HotchBadge: View {
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: HotchIcon.appIconImage(pointSize: size * 4))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
