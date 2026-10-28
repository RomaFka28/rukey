// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rukey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RukeyCore", targets: ["RukeyCore"]),
        .executable(name: "rukey", targets: ["RukeyApp"]),
        .executable(name: "rukey-measure", targets: ["RukeyMeasure"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "RukeyCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "RukeyApp",
            dependencies: ["RukeyCore"]
        ),
        .executableTarget(
            name: "RukeyMeasure",
            dependencies: ["RukeyCore"]
        ),
        .executableTarget(
            name: "RukeyGUI",
            dependencies: [
                "RukeyCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "RukeyCoreTests",
            dependencies: ["RukeyCore"]
        ),
        .testTarget(
            name: "RukeyGUITests",
            dependencies: ["RukeyGUI", "RukeyCore"]
        ),
    ]
)
