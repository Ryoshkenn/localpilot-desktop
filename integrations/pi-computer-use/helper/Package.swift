// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "lpcu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "lpcu",
            path: "Sources/lpcu",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
    ]
)
