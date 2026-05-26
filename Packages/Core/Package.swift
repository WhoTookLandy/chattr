// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"]),
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
