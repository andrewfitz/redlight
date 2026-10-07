// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Build metadata only for the app target. Passing a const-values path through global
// -Xswiftc flags also sends it to dependencies, which can overwrite the app's output.
let buildEnvironment = ProcessInfo.processInfo.environment
let appConstValuesPath = buildEnvironment["REDLIGHT_APP_CONST_VALUES_PATH"]
let appConstProtocolsPath = buildEnvironment["REDLIGHT_APP_CONST_PROTOCOLS_PATH"]
let appMetadataSettings: [SwiftSetting]
if let appConstValuesPath, let appConstProtocolsPath {
    appMetadataSettings = [.unsafeFlags([
        "-whole-module-optimization",
        "-emit-const-values-path", appConstValuesPath,
        "-Xfrontend", "-const-gather-protocols-file",
        "-Xfrontend", appConstProtocolsPath,
    ], .when(configuration: .release))]
} else {
    precondition(appConstValuesPath == nil && appConstProtocolsPath == nil,
                 "Set both REDLIGHT_APP_CONST_VALUES_PATH and REDLIGHT_APP_CONST_PROTOCOLS_PATH.")
    appMetadataSettings = []
}

let package = Package(
    name: "Redlight",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Redlight",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: appMetadataSettings
        ),
        .testTarget(name: "RedlightTests", dependencies: ["Redlight"]),
    ]
)
