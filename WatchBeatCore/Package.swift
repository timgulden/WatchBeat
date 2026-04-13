// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WatchBeatCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "WatchBeatCore",
            targets: ["WatchBeatCore"]
        ),
    ],
    targets: [
        .target(
            name: "WatchBeatCore",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "WatchBeatCoreTests",
            dependencies: ["WatchBeatCore"]
        ),
    ]
)
