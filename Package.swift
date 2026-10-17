// swift-tools-version: 6.4

import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "GCSF",
    platforms: [
        .macOS(.v27),
    ],
    products: [
        .library(name: "GCSFCore", targets: ["GCSFCore"]),
        .executable(name: "gcsf", targets: ["gcsf-cli"]),
        .library(name: "GCSFTestSupport", targets: ["GCSFTestSupport"]),
    ],
    targets: [
        .target(
            name: "GCSFCore",
            swiftSettings: strict,
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "gcsf-cli",
            dependencies: ["GCSFCore"],
            exclude: ["gcsf-cli.entitlements"],
            swiftSettings: strict
        ),
        .target(
            name: "GCSFTestSupport",
            dependencies: ["GCSFCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "GCSFCoreTests",
            dependencies: ["GCSFCore", "GCSFTestSupport"],
            swiftSettings: strict
        ),
    ],
    swiftLanguageModes: [.v6]
)
