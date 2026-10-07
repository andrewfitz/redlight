import Foundation
import Testing
@testable import Redlight

@Suite struct CLIVersionTests {
    @Test func symlinkAndDirectExecutableReadTheSameAppVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RedlightVersionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Redlight.app/Contents")
        let executable = contents.appendingPathComponent("MacOS/Redlight")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let info: [String: String] = [
            "CFBundleIdentifier": "com.redlight.version-test.\(UUID().uuidString)",
            "CFBundleExecutable": "Redlight", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "9.7", "CFBundleVersion": "123"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let link = directory.appendingPathComponent("redlight")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

        #expect(RedlightCLI.version(executableURL: executable) == "9.7 (123)")
        #expect(RedlightCLI.version(executableURL: link) == "9.7 (123)")
    }

    @Test func unbundledExecutableUsesDevelopmentFallback() {
        #expect(RedlightCLI.version(executableURL: URL(fileURLWithPath: "/tmp/redlight-unbundled/Redlight")) == "development")
    }
}
