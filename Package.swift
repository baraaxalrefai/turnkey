// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Turnkey",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Turnkey", targets: ["Turnkey"]),
    ],
    targets: [
        // Pure maths: features, smoothing, gaze model, calibration layout. No system access.
        .target(name: "TurnkeyCore", path: "Sources/TurnkeyCore"),
        // The menu bar app: camera, Vision, Accessibility, UI.
        .executableTarget(
            name: "Turnkey",
            dependencies: ["TurnkeyCore"],
            path: "Sources/Turnkey",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "TurnkeyCoreTests", dependencies: ["TurnkeyCore"], path: "Tests/TurnkeyCoreTests"),
    ]
)
