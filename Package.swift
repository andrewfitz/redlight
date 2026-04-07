// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Redlight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Redlight"),
        .testTarget(name: "RedlightTests", dependencies: ["Redlight"]),
    ]
)
