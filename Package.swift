// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AkkuMonitor",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AkkuMonitor",
            path: "Sources/AkkuMonitor",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
