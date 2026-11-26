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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "SuperwarmCore"),
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
    ]
)
