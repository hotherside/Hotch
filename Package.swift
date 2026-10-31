// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hotch",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // The app's one third-party dependency: in-app updates. Pinned exactly,
        // so a new updater only ever arrives as a reviewed change to this line.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // XPC protocol and constants shared by the app and the Backpack helper.
        .target(
            name: "BackpackShared",
            path: "Sources/BackpackShared"
        ),
        .executableTarget(
            name: "Hotch",
            dependencies: [
                "BackpackShared",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Hotch",
            // SwiftPM finds Sparkle.framework beside the executable in
            // .build/release. In the bundle the Makefile puts it in
            // Contents/Frameworks, which needs its own search path.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Root LaunchDaemon behind Backpack mode. Embedded in the bundle at
        // Contents/MacOS/HotchBackpackHelper and registered with SMAppService.
        .executableTarget(
            name: "HotchBackpackHelper",
            dependencies: ["BackpackShared"],
            path: "Sources/HotchBackpackHelper"
        ),
    ],
    swiftLanguageModes: [.v5]
)
