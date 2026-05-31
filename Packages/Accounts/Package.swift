// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Accounts",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Accounts", targets: ["Accounts"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../DesignSystem"),
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", exact: "0.3.0"),
    ],
    targets: [
        .target(
            name: "Accounts",
            dependencies: [
                "Core",
                "DesignSystem",
                .product(name: "TwitchKit", package: "TwitchKit"),
            ],
            path: "Sources/Accounts",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AccountsTests",
            dependencies: ["Accounts"],
            path: "Tests/AccountsTests"
        ),
    ]
)
