// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacNotchIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacNotchIsland",
            path: "Sources/MacNotchIsland",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("Quartz"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "MacNotchIslandTests",
            dependencies: ["MacNotchIsland"],
            path: "Tests/MacNotchIslandTests"
        ),
    ]
)
