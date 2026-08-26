// swift-tools-version: 6.0

import PackageDescription

let strictConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "BackgroundEngine",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackgroundEngineCore", targets: ["BackgroundEngineCore"]),
        .executable(name: "BackgroundEngine", targets: ["BackgroundEngineApp"]),
        .executable(name: "be-cli", targets: ["becli"]),
        .executable(name: "BackgroundEngineSteamCMDRunner", targets: ["SteamCMDRunnerService"]),
        .library(
            name: "BackgroundEngineDocumentation",
            targets: ["User_Documentation_en_US", "User_Documentation_zh_CN"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/LamPPKK/Plash.git",
            revision: "b9f585368264c79de997d7d82e10d2dc85f3024e"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            exact: "1.5.0"
        )
    ],
    targets: [
        .target(
            name: "BackgroundEngineCore",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "BackgroundEngineApp",
            dependencies: [
                "BackgroundEngineCore",
                .product(name: "PlashRuntime", package: "Plash")
            ],
            resources: [.process("Resources")],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "becli",
            dependencies: ["BackgroundEngineCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SteamCMDRunnerService",
            dependencies: ["BackgroundEngineCore"],
            swiftSettings: strictConcurrency
        ),
        .target(name: "User_Documentation_en_US"),
        .target(name: "User_Documentation_zh_CN"),
        .testTarget(
            name: "BackgroundEngineCoreTests",
            dependencies: ["BackgroundEngineCore"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "BackgroundEngineAppTests",
            dependencies: ["BackgroundEngineApp"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "BECLITests",
            dependencies: ["becli", "BackgroundEngineCore"],
            swiftSettings: strictConcurrency
        )
    ],
    swiftLanguageModes: [.v6]
)
