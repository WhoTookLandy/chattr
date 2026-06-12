// swift-tools-version: 6.2

import PackageDescription

// ChatModel: the presentation-layer types between TwitchKit's raw
// ChatMessage and the SwiftUI rows that render chat. Owns:
//
//   - ChatLine: a display-ready message line (id, badges, runs, …)
//   - LineRun:  a single inline piece of a message (text, emote, mention)
//   - Normalizer: pure sync function ChatMessage + EmoteIndex → ChatLine
//
// Dependency direction (this package depends on these — nothing in this
// list depends back, preventing cycles):
//
//   ChatModel
//     ├─ Core              (AppLogger only, for the few logging sites)
//     ├─ EmoteSources      (Emote type + EmoteIndex snapshot access)
//     └─ TwitchKit         (ChatMessage / ChatFragment / EmoteReference input shape)
//
// Notably ChatModel does NOT depend on Features or Channels — those packages
// import ChatModel later (Channels does so in Phase 2.3 Task 11 when
// ChannelSession starts emitting ChatLine; Features does so today via the
// per-channel render path).

let package = Package(
    name: "ChatModel",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "ChatModel", targets: ["ChatModel"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../EmoteSources"),
        // TwitchKit pulled in transitively via... no, it's not — we need it directly.
        // ChatModel needs TwitchKit.ChatMessage as input to Normalizer.
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", exact: "0.3.4"),
    ],
    targets: [
        .target(
            name: "ChatModel",
            dependencies: [
                "Core",
                "EmoteSources",
                .product(name: "TwitchKit", package: "TwitchKit"),
            ],
            path: "Sources/ChatModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChatModelTests",
            dependencies: ["ChatModel"],
            path: "Tests/ChatModelTests"
        ),
    ]
)
