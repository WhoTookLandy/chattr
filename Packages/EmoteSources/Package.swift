// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EmoteSources",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "EmoteSources", targets: ["EmoteSources"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "EmoteSources",
            dependencies: ["Core"],
            path: "Sources/EmoteSources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EmoteSourcesTests",
            dependencies: ["EmoteSources"],
            path: "Tests/EmoteSourcesTests"
        ),
    ]
)
