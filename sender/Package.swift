// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FireScreen",
    platforms: [.macOS(.v14)],
    targets: [
        // Thin Objective-C wrapper around the private CGVirtualDisplay API.
        .target(
            name: "VirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "FireScreen",
            dependencies: ["VirtualDisplay"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
