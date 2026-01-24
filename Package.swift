// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HotkeyLauncher",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "HotkeyLauncher",
            path: "Sources/HotkeyLauncher"
        )
    ]
)
