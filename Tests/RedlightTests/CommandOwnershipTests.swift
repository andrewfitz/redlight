import Darwin
import Foundation
import Testing
@testable import Redlight

private final class OwnershipBundleLocator: NSObject {}

/// This is a test-runner worker, not a production entry-point environment hook. Its
/// injectable lifecycle callbacks record effects without touching real gamma/preferences.
@Suite struct OwnershipWorkerSuite {
    @Test @MainActor func worker() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["REDLIGHT_OWNERSHIP_WORKER_DIRECTORY"],
              let portName = environment["REDLIGHT_OWNERSHIP_WORKER_PORT"] else { return }
        let folder = URL(fileURLWithPath: directory)
        func record(_ name: String) { try? "called".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let code = EntryRouter.run(arguments: ["Redlight"], reserveOwner: {
            try CommandServer.reserve(name: portName)
        }, runApplication: { server in
            // Models, recovery, preference writes and gamma writes are represented by
            // distinct injected callbacks. A duplicate cannot enter any of them.
            for name in ["recovery", "manager", "preferences", "gamma", "entered"] { record(name) }
            while !FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            record("termination")
            withExtendedLifetime(server) {}
        }, runCLI: { _ in
            record("cli")
            return 3
        }, reportError: { _ in })
        try String(code).write(to: folder.appendingPathComponent("result"), atomically: true, encoding: .utf8)
        exit(code)
    }
}

@Suite(.serialized) struct CommandOwnershipTests {
    @MainActor
    private func worker(directory: URL, portName: String) throws -> Process {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        let host = try CommandClient.realExecutableURL()
        process.executableURL = host
        process.arguments = ["--testing-library", "swift-testing", "--filter", "OwnershipWorkerSuite.worker"]
        if host.lastPathComponent == "swiftpm-testing-helper" {
            // The Xcode backend loads a Mach-O test bundle into this helper; simply
            // relaunching the host runs no tests unless the bundle is supplied again.
            process.arguments?.append(contentsOf: ["--test-bundle-path", Bundle(for: OwnershipBundleLocator.self).bundlePath])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["REDLIGHT_OWNERSHIP_WORKER_DIRECTORY"] = directory.path
        environment["REDLIGHT_OWNERSHIP_WORKER_PORT"] = portName
        process.environment = environment
        let logURL = directory.appendingPathComponent("worker.log")
        let invocation = "Host: \(host.path)\nArguments: \(process.arguments ?? [])\n"
        FileManager.default.createFile(atPath: logURL.path, contents: Data(invocation.utf8))
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        return process
    }

    @MainActor
    private func waitUntil(diagnostics: [URL] = [], _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                let logs = diagnostics.map { directory in
                    (try? String(contentsOf: directory.appendingPathComponent("worker.log"), encoding: .utf8)) ?? "no worker log"
                }.joined(separator: "\n")
                throw CommandError.system("Ownership worker did not complete within ten seconds. \(logs.prefix(4000))")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func exists(_ directory: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    @Test @MainActor func simultaneousProcessesHaveOneOwnerAndDuplicateHasNoLifecycleEffects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RedlightOwnership-\(UUID().uuidString)")
        let a = directory.appendingPathComponent("a")
        let b = directory.appendingPathComponent("b")
        let name = "com.redlight.test.\(UUID().uuidString)"
        let first = try worker(directory: a, portName: name)
        let second = try worker(directory: b, portName: name)
        defer {
            for process in [first, second] where process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        try await waitUntil(diagnostics: [a, b]) {
            (exists(a, "entered") && exists(b, "result")) || (exists(b, "entered") && exists(a, "result"))
        }
        let ownerFolder = exists(a, "entered") ? a : b
        let duplicateFolder = exists(a, "entered") ? b : a
        let duplicate = exists(a, "entered") ? second : first
        let owner = exists(a, "entered") ? first : second
        #expect(try String(contentsOf: duplicateFolder.appendingPathComponent("result"), encoding: .utf8) == "2")
        for effect in ["recovery", "manager", "preferences", "gamma", "termination", "cli"] {
            #expect(!exists(duplicateFolder, effect))
        }
        #expect(exists(ownerFolder, "gamma"))
        try await waitUntil(diagnostics: [duplicateFolder]) { !duplicate.isRunning }
        try "stop".write(to: ownerFolder.appendingPathComponent("stop"), atomically: true, encoding: .utf8)
        try await waitUntil(diagnostics: [ownerFolder]) { !owner.isRunning }
        #expect(owner.terminationStatus == 0 && duplicate.terminationStatus == 2)
        #expect(exists(ownerFolder, "termination"))
        let newOwner = try CommandServer.reserve(name: name)
        withExtendedLifetime(newOwner) {}
    }

    @Test @MainActor func abruptProcessExitReleasesOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RedlightOwnership-\(UUID().uuidString)")
        let name = "com.redlight.test.\(UUID().uuidString)"
        let owner = try worker(directory: directory, portName: name)
        defer {
            if owner.isRunning { kill(owner.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: directory)
        }
        try await waitUntil(diagnostics: [directory]) { exists(directory, "entered") }
        kill(owner.processIdentifier, SIGKILL)
        try await waitUntil(diagnostics: [directory]) { !owner.isRunning }
        #expect(!exists(directory, "termination"))
        let replacement = try CommandServer.reserve(name: name)
        withExtendedLifetime(replacement) {}
    }
}
