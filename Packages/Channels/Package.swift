// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Channels",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Channels", targets: ["Channels"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Accounts"),
        .package(path: "../EmoteSources"),
        .package(path: "../ChatModel"),
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", exact: "0.3.4"),
    ],
    targets: [
        .target(
            name: "Channels",
            dependencies: [
                "Core",
                "Accounts",
                "EmoteSources",
                "ChatModel",
                .product(name: "TwitchKit", package: "TwitchKit"),
            ],
            path: "Sources/Channels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChannelsTests",
            dependencies: ["Channels"],
            path: "Tests/ChannelsTests"
        ),
    ]
)
