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
        // Pure logic (wire protocol, bitstream and PCM conversion, options): no capture, no UI.
        .target(name: "FireScreenCore"),
        .executableTarget(
            name: "FireScreen",
            dependencies: ["VirtualDisplay", "FireScreenCore"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network"),
            ]
        ),
        // `swift run FireScreenSelfTest`: checks FireScreenCore. Kept as a plain executable so it
        // runs with the Command Line Tools alone, which ship neither XCTest nor swift-testing.
        .executableTarget(name: "FireScreenSelfTest", dependencies: ["FireScreenCore"]),
    ]
)
