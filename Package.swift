// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Redlight",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Redlight",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "RedlightTests", dependencies: ["Redlight"]),
    ]
)
