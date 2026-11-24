import Foundation

/// The preference domains tests use, kept out of `~/Library/Preferences`.
///
/// A domain whose name is an absolute path is stored at `<name>.plist`, so every domain
/// here is named inside one temporary directory that belongs to this process. They are
/// real domains: the preferences daemon writes them, `synchronize()` reports its result,
/// and a second `UserDefaults` or `CFPreferences` call with the same name reads what the
/// first wrote. Emptying a domain leaves an empty file behind rather than deleting it,
/// which is why the directory, not the domain, is what gets removed.
///
/// The daemon writes a path-named domain as each value is set, where it writes a domain
/// in `~/Library/Preferences` seconds later. That costs about a millisecond per `set`,
/// and it is what lets the directory be removed at exit with nothing still to arrive.
///
/// A domain goes back to the pool when its registry is released and is handed out again,
/// emptied, so a run opens as many domains as it has in use at once, not one per test.
final class TestDefaultsPool: @unchecked Sendable {
    static let shared = TestDefaultsPool()
    private static let directoryPrefix = "RedlightTestDefaults-"

    let directory: URL
    private let lock = NSLock()
    private var idle: [String] = []
    private var created = 0

    private init() {
        let temporary = FileManager.default.temporaryDirectory
        Self.removeAbandonedDirectories(in: temporary)
        directory = temporary.appendingPathComponent(
            "\(Self.directoryPrefix)\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        atexit { TestDefaultsPool.shared.removeDirectory() }
    }

    func lease() -> (name: String, defaults: UserDefaults) {
        while true {
            let name = lock.withLock {
                if !idle.isEmpty { return idle.removeFirst() }
                created += 1
                return directory.appendingPathComponent("domain-\(created)").path
            }
            let defaults = UserDefaults(suiteName: name)!
            // Values here were written after the domain was handed back, by something that
            // outlived its registry and may write again. Leave the domain to it.
            if defaults.persistentDomain(forName: name)?.isEmpty == false { continue }
            return (name, defaults)
        }
    }

    func release(_ lease: (name: String, defaults: UserDefaults)) {
        lease.defaults.removePersistentDomain(forName: lease.name)
        lock.withLock { idle.append(lease.name) }
    }

    /// The daemon creates the directory when it writes, so one more write would bring it
    /// back: stop once it has stayed away for a tenth of a second.
    private func removeDirectory() {
        var quietChecks = 0
        for _ in 0..<50 where quietChecks < 5 {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
                quietChecks = 0
            } else {
                quietChecks += 1
            }
            usleep(20_000)
        }
    }

    /// A run that was killed never reached its exit handler. Its directory is named by a
    /// process that no longer exists.
    private static func removeAbandonedDirectories(in temporary: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(directoryPrefix) {
            guard let process = pid_t(name.dropFirst(directoryPrefix.count)), process > 0,
                  getpgid(process) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }
}

/// Retained by each suite fixture, so its domains are emptied and handed back after the
/// test's managers are released.
final class TestDefaultsRegistry {
    private var leases: [(name: String, defaults: UserDefaults)] = []

    /// `prefix` says who is asking. It is no longer part of the domain's name.
    func makeDefaults(prefix _: String = "RedlightTests") -> UserDefaults {
        makeDomain().defaults
    }

    /// For code that addresses the domain by name, such as `RedlightControlPreferences`.
    func makeDomain() -> (name: String, defaults: UserDefaults) {
        let lease = TestDefaultsPool.shared.lease()
        leases.append(lease)
        return lease
    }

    deinit {
        for lease in leases { TestDefaultsPool.shared.release(lease) }
    }
}
