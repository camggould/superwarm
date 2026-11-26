// swift-tools-version: 6.0
import PackageDescription

// The macOS menu bar app. Estimation lives in the Rust engine (engine/), which
// the app bundles and runs; SuperwarmKit decodes its output.
let package = Package(
    name: "Superwarm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Superwarm", targets: ["Superwarm"]),
        .library(name: "SuperwarmKit", targets: ["SuperwarmKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Decodes the Rust engine's snapshot and runs the engine binary.
        .target(name: "SuperwarmKit"),
        .executableTarget(
            name: "Superwarm",
            dependencies: [
                "SuperwarmKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources/Logo.png")],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks of the app bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "SuperwarmKitTests",
            dependencies: ["SuperwarmKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
