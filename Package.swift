// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rukey",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RukeyCore",
            path: "Sources/RukeyCore"
        ),
        .executableTarget(
            name: "rukey",
            dependencies: ["RukeyCore"],
            path: "Sources/rukey"
        ),
        .testTarget(
            name: "RukeyCoreTests",
            dependencies: ["RukeyCore"],
            path: "Tests/RukeyCoreTests"
        ),
    ]
)