// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Superwarm",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SuperwarmCore", targets: ["SuperwarmCore"]),
    ],
    targets: [
        .target(name: "SuperwarmCore"),
        .testTarget(name: "SuperwarmCoreTests", dependencies: ["SuperwarmCore"]),
    ]
)
