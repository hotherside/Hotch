// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hotch",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // XPC protocol and constants shared by the app and the Backpack helper.
        .target(
            name: "BackpackShared",
            path: "Sources/BackpackShared"
        ),
        .executableTarget(
            name: "Hotch",
            dependencies: ["BackpackShared"],
            path: "Sources/Hotch"
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
