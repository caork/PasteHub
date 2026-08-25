// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PasteHub",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PasteHubCore", targets: ["PasteHubCore"]),
        .executable(name: "PasteHub", targets: ["PasteHub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "PasteHubCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/PasteHubCore"
        ),
        .target(
            name: "PasteHubAX",
            path: "Sources/PasteHubAX",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "PasteHub",
            dependencies: [
                "PasteHubCore",
                "PasteHubAX",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/PasteHub"
        ),
        .testTarget(
            name: "PasteHubCoreTests",
            dependencies: ["PasteHubCore"],
            path: "Tests/PasteHubCoreTests"
        ),
    ]
)
