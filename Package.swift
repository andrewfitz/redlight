// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Redlight",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", branch: "main"),
    ],
    targets: [
        .executableTarget(name: "Redlight"),
        .testTarget(
            name: "RedlightTests",
            dependencies: [
                "Redlight",
                .product(name: "Testing", package: "swift-testing"),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                              "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"]),
            ]
        ),
    ]
)
