// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Superwarm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Superwarm", targets: ["Superwarm"]),
        .executable(name: "superwarm-cli", targets: ["superwarm-cli"]),
        .library(name: "SuperwarmCore", targets: ["SuperwarmCore"]),
        .library(name: "SuperwarmKit", targets: ["SuperwarmKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "SuperwarmCore"),
        // Decodes the Rust engine's snapshot and runs the engine binary.
        .target(name: "SuperwarmKit"),
        .executableTarget(name: "superwarm-cli", dependencies: ["SuperwarmCore"]),
        .executableTarget(
            name: "Superwarm",
            dependencies: [
                "SuperwarmCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources/Logo.png")],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks of the app bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "SuperwarmCoreTests", dependencies: ["SuperwarmCore"]),
        .testTarget(
            name: "SuperwarmKitTests",
            dependencies: ["SuperwarmKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
