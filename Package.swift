// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Superwarm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Superwarm", targets: ["Superwarm"]),
        .executable(name: "superwarm-cli", targets: ["superwarm-cli"]),
        .library(name: "SuperwarmCore", targets: ["SuperwarmCore"]),
    ],
    targets: [
        .target(name: "SuperwarmCore"),
        .executableTarget(name: "superwarm-cli", dependencies: ["SuperwarmCore"]),
        .executableTarget(
            name: "Superwarm",
            dependencies: ["SuperwarmCore"],
            resources: [.copy("Resources/Logo.png")]
        ),
        .testTarget(name: "SuperwarmCoreTests", dependencies: ["SuperwarmCore"]),
    ]
)
