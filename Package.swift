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
    ]
)
