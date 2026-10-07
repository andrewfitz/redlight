import AppKit
import Darwin
import Foundation

enum CLIInstallationResult: Equatable {
    case installed(String)
    case alreadyInstalled(String)
    case ineligibleLocation
    case requiresPrivileges
    case conflict(String)
    case declined
    case promptAlreadyAttempted
    case failed(String)
}

enum CLIPathEntry: Equatable {
    case missing
    case symlink(String)
    case other
}

/// File operations are injected so tests never write to PATH or present an admin prompt.
protocol CLIInstallerFileSystem {
    func realPath(_ path: String) throws -> String
    func isWritableDirectory(_ path: String) -> Bool
    func entry(at path: String) throws -> CLIPathEntry
    func installLink(at path: String, pointingTo target: String, replacing: String?) throws
}

enum CLIPrivilegedResult {
    case success
    case cancelled
    case failed(String)
}

@MainActor
final class CLIInstaller {
    static let declinedKey = "redlight.cliInstallDeclined"
    static let attemptedKey = "redlight.cliInstallPromptAttempted"
    private static let directories = ["/opt/homebrew/bin", "/usr/local/bin"]

    private let executablePath: String?
    private let homeDirectory: String
    private let fileSystem: any CLIInstallerFileSystem
    private let defaults: UserDefaults
    private let privilegedExecutor: @MainActor (String) -> CLIPrivilegedResult
    private var silentAttempted = false
    private(set) var lastResult: CLIInstallationResult?

    init(
        executablePath: String? = Bundle.main.executableURL?.path,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fileSystem: any CLIInstallerFileSystem = LocalCLIInstallerFileSystem(),
        defaults: UserDefaults = .standard,
        privilegedExecutor: @escaping @MainActor (String) -> CLIPrivilegedResult = CLIInstaller.executePrivileged
    ) {
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
        self.fileSystem = fileSystem
        self.defaults = defaults
        self.privilegedExecutor = privilegedExecutor
    }

    @discardableResult
    func installSilentlyIfPossible() -> CLIInstallationResult {
        // Startup and the first popover can both ask. Do not repeat a failed filesystem action.
        if silentAttempted, let lastResult { return lastResult }
        silentAttempted = true
        let result: CLIInstallationResult
        do {
            guard let target = try eligibleExecutable() else {
                return record(.ineligibleLocation)
            }
            guard let directory = Self.directories.first(where: fileSystem.isWritableDirectory) else {
                return record(.requiresPrivileges)
            }
            let path = directory + "/redlight"
            switch try fileSystem.entry(at: path) {
            case .missing:
                try fileSystem.installLink(at: path, pointingTo: target, replacing: nil)
            case let .symlink(existing):
                guard Self.isRedlightLink(existing, at: path) else { return record(.conflict(path)) }
                if Self.absoluteLinkTarget(existing, at: path) == target {
                    return record(.alreadyInstalled(path))
                }
                try fileSystem.installLink(at: path, pointingTo: target, replacing: existing)
            case .other:
                return record(.conflict(path))
            }
            result = try verifiedResult(path: path, target: target)
        } catch {
            result = .failed(error.localizedDescription)
        }
        return record(result)
    }

    /// Called only when the owner app's popover first opens; launch itself never prompts.
    @discardableResult
    func offerPrivilegedInstallOnPopoverOpen() -> CLIInstallationResult {
        let silentResult = installSilentlyIfPossible()
        guard silentResult == .requiresPrivileges else { return silentResult }
        // A directory may have become writable since launch (for example Homebrew was
        // installed). Re-evaluate that changed external state before asking for privilege.
        if Self.directories.contains(where: fileSystem.isWritableDirectory) {
            silentAttempted = false
            return installSilentlyIfPossible()
        }
        if defaults.bool(forKey: Self.declinedKey) { return record(.declined) }
        if defaults.bool(forKey: Self.attemptedKey) { return record(.promptAlreadyAttempted) }

        do {
            guard let target = try eligibleExecutable() else { return record(.ineligibleLocation) }
            let path = "/usr/local/bin/redlight"
            let existing: String?
            switch try fileSystem.entry(at: path) {
            case .missing: existing = nil
            case let .symlink(link):
                guard Self.isRedlightLink(link, at: path) else { return record(.conflict(path)) }
                if Self.absoluteLinkTarget(link, at: path) == target {
                    return record(.alreadyInstalled(path))
                }
                existing = link
            case .other: return record(.conflict(path))
            }

            // Persist before prompting. A failed script is also a completed attempt, not an
            // invitation to prompt on every future launch. Manual installation remains possible.
            defaults.set(true, forKey: Self.attemptedKey)
            defaults.synchronize()
            switch privilegedExecutor(Self.privilegedAppleScript(target: target, replacing: existing)) {
            case .success:
                return record(try verifiedResult(path: path, target: target))
            case .cancelled:
                defaults.set(true, forKey: Self.declinedKey)
                defaults.synchronize()
                return record(.declined)
            case let .failed(message): return record(.failed(message))
            }
        } catch {
            return record(.failed(error.localizedDescription))
        }
    }

    private func record(_ result: CLIInstallationResult) -> CLIInstallationResult {
        lastResult = result
        return result
    }

    private func verifiedResult(path: String, target: String) throws -> CLIInstallationResult {
        guard case let .symlink(link) = try fileSystem.entry(at: path),
              Self.absoluteLinkTarget(link, at: path) == target else {
            return .failed("The redlight link could not be verified at \(path).")
        }
        return .installed(path)
    }

    private func eligibleExecutable() throws -> String? {
        guard let executablePath, Self.isSafeLocation(executablePath, homeDirectory: homeDirectory) else {
            return nil
        }
        let resolved = try fileSystem.realPath(executablePath)
        guard Self.isSafeLocation(resolved, homeDirectory: homeDirectory) else { return nil }
        return resolved
    }

    static func isSafeLocation(_ path: String, homeDirectory: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardized.pathComponents
        guard !components.contains("AppTranslocation"), !components.starts(with: ["/", "Volumes"]),
              components.count >= 6,
              components.suffix(4) == ["Redlight.app", "Contents", "MacOS", "Redlight"] else { return false }
        let applications = ["/Applications", homeDirectory + "/Applications"]
        return applications.contains { directory in
            let root = URL(fileURLWithPath: directory).standardized.path
            return URL(fileURLWithPath: path).standardized.path.hasPrefix(root + "/")
        }
    }

    nonisolated static func absoluteLinkTarget(_ link: String, at path: String) -> String {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        return URL(fileURLWithPath: link, relativeTo: directory).standardized.path
    }

    nonisolated static func isRedlightLink(_ link: String, at path: String) -> Bool {
        URL(fileURLWithPath: absoluteLinkTarget(link, at: path)).pathComponents.suffix(4)
            == ["Redlight.app", "Contents", "MacOS", "Redlight"]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// C symlink and RENAME_EXCL operations address the final component exclusively. The
    /// command-line `ln` and `mv` utilities instead treat an existing destination directory
    /// as a container, which would alter another writer's directory during a race.
    static func privilegedAppleScript(target: String, replacing existing: String?) -> String {
        "do shell script " + appleScriptQuote(installationShellScript(target: target, replacing: existing))
            + " with administrator privileges"
    }

    /// The destination injection lets tests execute the exact shell logic in a temporary
    /// directory, as their own user, without AppleScript or a privileged PATH write.
    static func installationShellScript(
        target: String,
        replacing existing: String?,
        path: String = "/usr/local/bin/redlight"
    ) -> String {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let qPath = shellQuote(path)
        var script = "set -eu\n/bin/mkdir -p " + shellQuote(directory) + "\n"
        if let existing {
            script += """
            [ -L \(qPath) ] && [ "$(/usr/bin/readlink \(qPath))" = \(shellQuote(existing)) ] || exit 1
            stage=$(/usr/bin/mktemp -d \(shellQuote(directory + "/.redlight-link.XXXXXX")))
            cd "$stage"
            trap '/bin/rmdir "$stage" 2>/dev/null || :' EXIT
            \(exclusiveRenameShellCommand(from: path, to: "./previous"))
            [ ! -e \(qPath) ] && [ ! -L \(qPath) ] || exit 1
            if [ ! -L ./previous ] || [ "$(/usr/bin/readlink ./previous)" != \(shellQuote(existing)) ]; then
                \(exclusiveRenameShellCommand(from: "./previous", to: path))
                exit 1
            fi
            if \(exclusiveSymlinkShellCommand(target: target, path: path)); then
                /bin/rm ./previous
            else
                \(exclusiveRenameShellCommand(from: "./previous", to: path))
                exit 1
            fi
            """
        } else {
            script += exclusiveSymlinkShellCommand(target: target, path: path) + "\n"
        }
        return script
    }

    static func exclusiveSymlinkShellCommand(target: String, path: String) -> String {
        let source = "ObjC.bindFunction('symlink', ['int', ['char *', 'char *']]); "
            + "if ($.symlink(\(javaScriptQuote(target)), \(javaScriptQuote(path))) !== 0) "
            + "throw Error('Could not create the redlight link; the destination may be occupied.');"
        return "/usr/bin/osascript -l JavaScript -e " + shellQuote(source)
    }

    static func exclusiveRenameShellCommand(from source: String, to destination: String) -> String {
        // RENAME_EXCL = 0x4 in Darwin's sys/stdio.h. JXA's C bridge avoids depending on a
        // separately installed scripting language while retaining the native syscall's
        // no-overwrite semantics, including destination directories and directory symlinks.
        let script = "ObjC.bindFunction('renamex_np', ['int', ['char *', 'char *', 'unsigned int']]); "
            + "if ($.renamex_np(\(javaScriptQuote(source)), \(javaScriptQuote(destination)), 4) !== 0) "
            + "throw Error('Could not move the redlight link without replacing an existing file.');"
        return "/usr/bin/osascript -l JavaScript -e " + shellQuote(script)
    }

    private static func javaScriptQuote(_ value: String) -> String {
        // Encoding a String cannot fail; the JSON string literal is also a JS literal.
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func executePrivileged(_ source: String) -> CLIPrivilegedResult {
        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not create the CLI installation script.")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return .success }
        if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "CLI installation failed.")
    }
}

struct LocalCLIInstallerFileSystem: CLIInstallerFileSystem {
    func realPath(_ path: String) throws -> String {
        guard let result = Darwin.realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(result) }
        return String(cString: result)
    }

    func isWritableDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: path)
    }

    func entry(at path: String) throws -> CLIPathEntry {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return .missing }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            return .symlink(try FileManager.default.destinationOfSymbolicLink(atPath: path))
        }
        return .other
    }

    func installLink(at path: String, pointingTo target: String, replacing existing: String?) throws {
        guard let existing else {
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
            return
        }
        guard CLIInstaller.isRedlightLink(existing, at: path), try entry(at: path) == .symlink(existing) else {
            throw NSError(domain: "Redlight.CLIInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The existing redlight link changed during installation."])
        }
        let backup = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".redlight-link-" + UUID().uuidString).path
        // RENAME_EXCL never overwrites a backup or a concurrently created destination.
        try moveExclusively(from: path, to: backup)
        do {
            guard try entry(at: backup) == .symlink(existing) else {
                throw NSError(domain: "Redlight.CLIInstaller", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The existing redlight file changed during installation."])
            }
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        } catch {
            // Preserve both objects if another writer has occupied the destination. The
            // old object remains at the backup; never remove somebody else's new file.
            try? moveExclusively(from: backup, to: path)
            throw error
        }
        try FileManager.default.removeItem(atPath: backup)
    }

    private func moveExclusively(from source: String, to destination: String) throws {
        if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
