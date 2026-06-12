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
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", exact: "0.3.3"),
        // Nuke for image loading + caching. Profile-guided choice:
        // chat-row badges and emotes recycle constantly during scroll;
        // SwiftUI's AsyncImage refetches+redecodes per recycle and
        // bridges to UIKit every time. NukeUI's LazyImage does a sync
        // cache check on first frame (no placeholder flash), runs the
        // decode off-main, evicts under memory pressure, and ships
        // animated WebP/GIF (relevant for slice 4 animated emotes).
        //
        // Pinning to 13.0.0 minimum — that's the first major with
        // Swift 6 strict concurrency support, matching this package's
        // language mode.
        .package(url: "https://github.com/kean/Nuke.git", from: "13.0.0"),
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
                // Nuke = the loading pipeline (no SwiftUI surface).
                // NukeUI = the SwiftUI wrapper with LazyImage.
                // We use both because LazyImage delegates to the
                // pipeline for cache + fetch.
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
            ],
            path: "Sources/Features",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Features", "ChatModel"],
            path: "Tests/FeaturesTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
