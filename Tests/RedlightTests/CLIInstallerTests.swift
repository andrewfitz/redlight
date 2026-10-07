import Foundation
import Testing
@testable import Redlight

@Suite @MainActor struct CLIInstallerTests {
    private let executable = "/Applications/Redlight.app/Contents/MacOS/Redlight"
    private let home = "/Users/test"

    private func preferences() -> UserDefaults {
        let name = "Redlight.CLIInstallerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func acceptsOnlyInstalledAppLocations() {
        let accepted = [
            executable,
            "/Applications/Utilities/Redlight.app/Contents/MacOS/Redlight",
            "/Users/test/Applications/Redlight.app/Contents/MacOS/Redlight",
            "/Users/test/Applications/A 'quoted' folder/Redlight.app/Contents/MacOS/Redlight",
        ]
        let rejected = [
            "/Volumes/Redlight/Redlight.app/Contents/MacOS/Redlight",
            "/Users/test/Downloads/Redlight.app/Contents/MacOS/Redlight",
            "/private/var/folders/a/AppTranslocation/uuid/d/Redlight.app/Contents/MacOS/Redlight",
            "/Applications/AppTranslocation/Redlight.app/Contents/MacOS/Redlight",
            "/ApplicationsFake/Redlight.app/Contents/MacOS/Redlight",
            "/Applications/Other.app/Contents/MacOS/Redlight",
            "/Applications/Redlight.app/Contents/MacOS/redlight",
            "/Applications/../Volumes/Redlight/Redlight.app/Contents/MacOS/Redlight",
            "/Users/test/.Trash/Redlight.app/Contents/MacOS/Redlight",
            "/Users/test/Code/redlight/.build/debug/Redlight",
        ]
        for path in accepted { #expect(CLIInstaller.isSafeLocation(path, homeDirectory: home)) }
        for path in rejected { #expect(!CLIInstaller.isSafeLocation(path, homeDirectory: home)) }
    }

    @Test func refusesApplicationsLinkWhoseRealTargetIsOnMountedVolume() {
        let fileSystem = FakeCLIInstallerFileSystem()
        fileSystem.resolvedPath = "/Volumes/Redlight/Redlight.app/Contents/MacOS/Redlight"
        fileSystem.writable = ["/opt/homebrew/bin"]
        var prompts = 0
        let installer = CLIInstaller(executablePath: executable, homeDirectory: home,
                                     fileSystem: fileSystem, defaults: preferences()) { _ in
            prompts += 1
            return .success
        }
        #expect(installer.installSilentlyIfPossible() == .ineligibleLocation)
        #expect(installer.offerPrivilegedInstallOnPopoverOpen() == .ineligibleLocation)
        #expect(fileSystem.installs.isEmpty)
        #expect(prompts == 0)
    }

    @Test func nilAndUnbundledExecutablesNeverInstallOrPrompt() {
        for path in [nil, "/tmp/test/RedlightTests.xctest/Contents/MacOS/RedlightTests"] as [String?] {
            let fileSystem = FakeCLIInstallerFileSystem()
            fileSystem.writable = ["/opt/homebrew/bin", "/usr/local/bin"]
            let installer = CLIInstaller(executablePath: path, fileSystem: fileSystem,
                                         defaults: preferences()) { _ in
                Issue.record("An ineligible test executable must never prompt")
                return .success
            }
            #expect(installer.installSilentlyIfPossible() == .ineligibleLocation)
            #expect(installer.offerPrivilegedInstallOnPopoverOpen() == .ineligibleLocation)
            #expect(fileSystem.installs.isEmpty)
        }
    }

    @Test func choosesFirstWritableDirectoryAndReadsBackCreatedLink() {
        for directories in [["/opt/homebrew/bin", "/usr/local/bin"], ["/usr/local/bin"]] {
            let fileSystem = FakeCLIInstallerFileSystem()
            fileSystem.writable = Set(directories)
            let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                         defaults: preferences())
            let path = directories[0] + "/redlight"
            #expect(installer.installSilentlyIfPossible() == .installed(path))
            #expect(fileSystem.entries[path] == .symlink(executable))
            #expect(fileSystem.reads.filter { $0 == path }.count == 2)
            #expect(installer.offerPrivilegedInstallOnPopoverOpen() == .installed(path))
            #expect(fileSystem.installs.count == 1)
        }
    }

    @Test func repointsAllowedStaleAndDanglingLinks() {
        let oldTargets = [
            "/Users/test/Applications/Redlight.app/Contents/MacOS/Redlight",
            "/Deleted/Redlight.app/Contents/MacOS/Redlight",
            "../../../Applications/Old/Redlight.app/Contents/MacOS/Redlight",
        ]
        for old in oldTargets {
            let fileSystem = FakeCLIInstallerFileSystem()
            fileSystem.writable = ["/usr/local/bin"]
            fileSystem.entries["/usr/local/bin/redlight"] = .symlink(old)
            let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                         defaults: preferences())
            #expect(installer.installSilentlyIfPossible() == .installed("/usr/local/bin/redlight"))
            #expect(fileSystem.installs.first?.replacing == old)
            #expect(fileSystem.entries["/usr/local/bin/redlight"] == .symlink(executable))
        }
    }

    @Test func doesNotRewriteCurrentLinkIncludingRelativeTarget() {
        for target in [executable, "../../../Applications/Redlight.app/Contents/MacOS/Redlight"] {
            let fileSystem = FakeCLIInstallerFileSystem()
            fileSystem.writable = ["/usr/local/bin"]
            fileSystem.entries["/usr/local/bin/redlight"] = .symlink(target)
            let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                         defaults: preferences())
            #expect(installer.installSilentlyIfPossible() == .alreadyInstalled("/usr/local/bin/redlight"))
            #expect(fileSystem.installs.isEmpty)
        }
    }

    @Test func conflictsArePreservedAndNeverPrompted() {
        for conflict in [CLIPathEntry.other, .symlink("/usr/local/bin/other"),
                         .symlink("/Deleted/Other.app/Contents/MacOS/Redlight")] {
            for writable in [Set(["/usr/local/bin"]), Set<String>()] {
                let fileSystem = FakeCLIInstallerFileSystem()
                fileSystem.writable = writable
                fileSystem.entries["/usr/local/bin/redlight"] = conflict
                let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                             defaults: preferences()) { _ in
                    Issue.record("A conflicting file must never cause a privileged operation")
                    return .success
                }
                if writable.isEmpty {
                    #expect(installer.installSilentlyIfPossible() == .requiresPrivileges)
                } else {
                    #expect(installer.installSilentlyIfPossible() == .conflict("/usr/local/bin/redlight"))
                }
                #expect(installer.offerPrivilegedInstallOnPopoverOpen() == .conflict("/usr/local/bin/redlight"))
                #expect(fileSystem.entries["/usr/local/bin/redlight"] == conflict)
                #expect(fileSystem.installs.isEmpty)
            }
        }
    }

    @Test func doesNotMaskHomebrewConflictByCreatingSecondLink() {
        let fileSystem = FakeCLIInstallerFileSystem()
        fileSystem.writable = ["/opt/homebrew/bin", "/usr/local/bin"]
        fileSystem.entries["/opt/homebrew/bin/redlight"] = .other
        let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                     defaults: preferences())
        #expect(installer.installSilentlyIfPossible() == .conflict("/opt/homebrew/bin/redlight"))
        #expect(fileSystem.installs.isEmpty)
    }

    @Test func silentFailureAndBadReadbackAreReportedWithoutRetrying() {
        for failByThrowing in [true, false] {
            let fileSystem = FakeCLIInstallerFileSystem()
            fileSystem.writable = ["/usr/local/bin"]
            fileSystem.failInstall = failByThrowing
            fileSystem.badReadback = !failByThrowing
            let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                         defaults: preferences())
            guard case .failed = installer.installSilentlyIfPossible() else {
                Issue.record("Expected an installation failure")
                return
            }
            _ = installer.installSilentlyIfPossible()
            _ = installer.offerPrivilegedInstallOnPopoverOpen()
            #expect(fileSystem.installs.count == 1)
        }
    }

    @Test func promptsOnlyOnPopoverAndVerifiesPrivilegedSuccess() {
        let fileSystem = FakeCLIInstallerFileSystem()
        let defaults = preferences()
        var prompts = 0
        let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                     defaults: defaults) { source in
            prompts += 1
            #expect(source.hasPrefix("do shell script "))
            #expect(source.hasSuffix(" with administrator privileges"))
            #expect(!source.contains("ln -sf"))
            fileSystem.entries["/usr/local/bin/redlight"] = .symlink(executable)
            return .success
        }
        #expect(installer.installSilentlyIfPossible() == .requiresPrivileges)
        #expect(prompts == 0)
        #expect(installer.offerPrivilegedInstallOnPopoverOpen() == .installed("/usr/local/bin/redlight"))
        #expect(defaults.bool(forKey: CLIInstaller.attemptedKey))
        #expect(!defaults.bool(forKey: CLIInstaller.declinedKey))
        _ = installer.offerPrivilegedInstallOnPopoverOpen()
        #expect(prompts == 1)
    }

    @Test func cancellationIsRememberedAcrossNewInstallerInstances() {
        let fileSystem = FakeCLIInstallerFileSystem()
        let defaults = preferences()
        var prompts = 0
        let first = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                 defaults: defaults) { _ in
            prompts += 1
            return .cancelled
        }
        #expect(first.offerPrivilegedInstallOnPopoverOpen() == .declined)
        #expect(defaults.bool(forKey: CLIInstaller.declinedKey))
        let second = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                  defaults: defaults) { _ in
            prompts += 1
            return .success
        }
        #expect(second.offerPrivilegedInstallOnPopoverOpen() == .declined)
        #expect(prompts == 1)
    }

    @Test func failedAdminScriptAndReadbackNeverCauseAnotherPrompt() {
        for reportsSuccess in [true, false] {
            let fileSystem = FakeCLIInstallerFileSystem()
            let defaults = preferences()
            var prompts = 0
            let first = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                     defaults: defaults) { _ in
                prompts += 1
                return reportsSuccess ? .success : .failed("Script failed")
            }
            guard case .failed = first.offerPrivilegedInstallOnPopoverOpen() else {
                Issue.record("Expected a privileged installation or readback failure")
                return
            }
            _ = first.offerPrivilegedInstallOnPopoverOpen()
            let second = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                      defaults: defaults) { _ in
                prompts += 1
                return .success
            }
            #expect(second.offerPrivilegedInstallOnPopoverOpen() == .promptAlreadyAttempted)
            #expect(prompts == 1)
        }
    }

    @Test func newlyWritableDirectoryAvoidsAnUnnecessaryAdminPrompt() {
        let fileSystem = FakeCLIInstallerFileSystem()
        let installer = CLIInstaller(executablePath: executable, fileSystem: fileSystem,
                                     defaults: preferences()) { _ in
            Issue.record("A writable directory must avoid prompting")
            return .success
        }
        #expect(installer.installSilentlyIfPossible() == .requiresPrivileges)
        fileSystem.writable = ["/usr/local/bin"]
        #expect(installer.offerPrivilegedInstallOnPopoverOpen() == .installed("/usr/local/bin/redlight"))
    }

    @Test func shellAndAppleScriptQuotesPreserveUntrustedPathText() {
        #expect(CLIInstaller.shellQuote("a'b") == "'a'\\''b'")
        #expect(CLIInstaller.appleScriptQuote("a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\"")
        let path = "/Users/test/Applications/a' $(touch injected); \"quoted\"/Redlight.app/Contents/MacOS/Redlight"
        let source = CLIInstaller.privilegedAppleScript(target: path, replacing: nil)
        #expect(source.contains("/usr/bin/osascript -l JavaScript"))
        #expect(source.contains("$(touch injected)"))
        #expect(!source.contains("ln -sf"))
    }

    @Test func realFileSystemPreservesConflictsAndRepointsOnlyExpectedLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RedlightInstaller-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalCLIInstallerFileSystem()
        let path = root.appendingPathComponent("redlight").path
        let stale = "/Deleted/Redlight.app/Contents/MacOS/Redlight"
        try fileSystem.installLink(at: path, pointingTo: stale, replacing: nil)
        #expect(try fileSystem.entry(at: path) == .symlink(stale))
        try fileSystem.installLink(at: path, pointingTo: executable, replacing: stale)
        #expect(try fileSystem.entry(at: path) == .symlink(executable))
        #expect(throws: (any Error).self) {
            try fileSystem.installLink(at: path, pointingTo: stale, replacing: nil)
        }
        #expect(try fileSystem.entry(at: path) == .symlink(executable))
        #expect(throws: (any Error).self) {
            try fileSystem.installLink(at: path, pointingTo: stale, replacing: "/unexpected")
        }
        try FileManager.default.removeItem(atPath: path)
        try Data("user data".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) {
            try fileSystem.installLink(at: path, pointingTo: executable, replacing: nil)
        }
        #expect(throws: (any Error).self) {
            try fileSystem.installLink(at: path, pointingTo: executable, replacing: stale)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "user data")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["redlight"])
    }

    @Test func actualInstallerShellPreservesFilesAndTreatsPathsAsLiteralText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RedlightInstallerShell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("bin/redlight").path
        let literalTarget = root.appendingPathComponent("a' $(touch injected); \"quoted\" 😀/Redlight.app/Contents/MacOS/Redlight").path
        func run(target: String, replacing: String?) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", CLIInstaller.installationShellScript(target: target, replacing: replacing, path: path)]
            process.currentDirectoryURL = root
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run(target: literalTarget, replacing: nil) == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == literalTarget)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
        #expect(try run(target: executable, replacing: literalTarget) == 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == executable)
        #expect(try run(target: literalTarget, replacing: "/unexpected") != 0)
        #expect(try run(target: literalTarget, replacing: nil) != 0)
        try FileManager.default.removeItem(atPath: path)
        try Data("keep this file".utf8).write(to: URL(fileURLWithPath: path))
        #expect(try run(target: executable, replacing: nil) != 0)
        #expect(try run(target: executable, replacing: literalTarget) != 0)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep this file")
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        #expect(try run(target: executable, replacing: nil) != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
        try FileManager.default.removeItem(atPath: path)
        let foreignDirectory = root.appendingPathComponent("foreign-directory")
        try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: foreignDirectory.path)
        #expect(try run(target: executable, replacing: nil) != 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == foreignDirectory.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: foreignDirectory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("bin").path) == ["redlight"])
    }

    @Test func privilegedRollbackPrimitiveNeverMovesIntoAForeignDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RedlightInstallerRollback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("previous").path
        let destination = root.appendingPathComponent("redlight").path
        try FileManager.default.createSymbolicLink(atPath: source, withDestinationPath: executable)
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CLIInstaller.exclusiveRenameShellCommand(from: source, to: destination)]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source) == executable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination).isEmpty)
    }
}

private final class FakeCLIInstallerFileSystem: CLIInstallerFileSystem {
    var resolvedPath: String?
    var writable: Set<String> = []
    var entries: [String: CLIPathEntry] = [:]
    var installs: [(path: String, target: String, replacing: String?)] = []
    var reads: [String] = []
    var failInstall = false
    var badReadback = false

    func realPath(_ path: String) throws -> String { resolvedPath ?? path }
    func isWritableDirectory(_ path: String) -> Bool { writable.contains(path) }
    func entry(at path: String) throws -> CLIPathEntry {
        reads.append(path)
        return entries[path] ?? .missing
    }
    func installLink(at path: String, pointingTo target: String, replacing: String?) throws {
        installs.append((path, target, replacing))
        if failInstall { throw NSError(domain: "test", code: 1) }
        if !badReadback { entries[path] = .symlink(target) }
    }
}
