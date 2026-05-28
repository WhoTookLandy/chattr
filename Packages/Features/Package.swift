// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Features",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Features", targets: ["Features"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../DesignSystem"),
        .package(path: "../Accounts"),
        .package(path: "../Channels"),
        .package(path: "../EmoteSources"),
        .package(path: "../ChatModel"),
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: [
                "Core",
                "DesignSystem",
                "Accounts",
                "Channels",
                "EmoteSources",
                "ChatModel",
                .product(name: "TwitchKit", package: "TwitchKit"),
            ],
            path: "Sources/Features",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
