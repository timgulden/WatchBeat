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
        .executable(
            name: "AnalyzeSamples",
            targets: ["AnalyzeSamples"]
        ),
        .executable(
            name: "AmplitudeExperiment",
            targets: ["AmplitudeExperiment"]
        ),
        .executable(
            name: "CompareMics",
            targets: ["CompareMics"]
        ),
        .executable(
            name: "TickAnatomy",
            targets: ["TickAnatomy"]
        ),
        .executable(
            name: "DiagnoseRates",
            targets: ["DiagnoseRates"]
        ),
        .executable(
            name: "DumpResiduals",
            targets: ["DumpResiduals"]
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
        .executableTarget(
            name: "AnalyzeSamples",
            dependencies: ["WatchBeatCore"]
        ),
        .executableTarget(
            name: "AmplitudeExperiment",
            dependencies: ["WatchBeatCore"]
        ),
        .executableTarget(
            name: "CompareMics",
            dependencies: ["WatchBeatCore"]
        ),
        .executableTarget(
            name: "TickAnatomy",
            dependencies: ["WatchBeatCore"]
        ),
        .executableTarget(
            name: "DiagnoseRates",
            dependencies: ["WatchBeatCore"]
        ),
        .executableTarget(
            name: "DumpResiduals",
            dependencies: ["WatchBeatCore"]
        ),
        .testTarget(
            name: "WatchBeatCoreTests",
            dependencies: ["WatchBeatCore"]
        ),
    ]
)
