import AppIntents
import AppKit
import Foundation
import WidgetKit

/// Compiled unchanged into the app and the control extension.
enum RedlightControlPreferences {
    static let domain = "com.redlight.app"
    static let stateKey = "redlight.isOn"
    static let kind = "com.redlight.app.control"
    static let receiptsKey = "redlight.controlReceipts"

    static func refreshedValue(_ key: String, domain: String = domain) -> Any? {
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, domain as CFString,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func currentValue(domain: String = domain) -> Bool {
        refreshedValue(stateKey, domain: domain) as? Bool ?? false
    }

    @discardableResult
    static func publish(_ value: Bool, domain: String = domain) -> Bool {
        CFPreferencesSetValue(stateKey as CFString, value as CFBoolean, domain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    static func receipts(domain: String = domain) -> [String: ControlReceipt] {
        guard let data = refreshedValue(receiptsKey, domain: domain) as? Data,
              let receipts = try? JSONDecoder().decode([String: ControlReceipt].self, from: data) else { return [:] }
        return receipts
    }

    static func receipt(_ request: UUID, domain: String = domain) -> ControlReceipt? {
        receipts(domain: domain)[request.uuidString]
    }

    static func record(_ receipt: ControlReceipt, domain: String = domain, now: Date = Date()) throws {
        var recent = receipts(domain: domain).filter { now.timeIntervalSince($0.value.completedAt) < 120 }
        recent[receipt.request.uuidString] = receipt
        if recent.count > 128 {
            let retained = recent.values.sorted { $0.completedAt > $1.completedAt }.prefix(128)
            recent = Dictionary(uniqueKeysWithValues: retained.map { ($0.request.uuidString, $0) })
        }
        let data = try JSONEncoder().encode(recent)
        CFPreferencesSetValue(receiptsKey as CFString, data as CFData, domain as CFString,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ControlHandoffError.failed("Could not publish Redlight's completion receipt.")
        }
    }
}

struct ControlReceipt: Codable, Sendable, Equatable {
    let request: UUID
    let on: Bool
    let error: String?
    let completedAt: Date
}

enum ControlHandoffError: Error, LocalizedError, Sendable {
    case failed(String)
    case timeout
    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .timeout: "Redlight did not complete the command within 5 seconds."
        }
    }
}

@MainActor enum IntentBridge {
    static var setOn: ((Bool) throws -> Bool)?
    static var handoff: (Bool) async throws -> Void = { try await ControlHandoffClient().setOn($0) }
}

/// App-side URL requests may arrive before the command handler is installed.
@MainActor final class ControlHandoff {
    static let shared = ControlHandoff()
    struct Request: Equatable { let id: UUID; let on: Bool }
    private var pending: [Request] = []
    private var execute: ((Bool) throws -> Bool)?
    private let read: (UUID) -> ControlReceipt?
    private let record: (ControlReceipt) throws -> Void
    private let publish: @MainActor (Bool) throws -> Void
    private let now: () -> Date
    private var completed: [UUID] = []

    init(read: @escaping (UUID) -> ControlReceipt? = { RedlightControlPreferences.receipt($0) },
         record: @escaping (ControlReceipt) throws -> Void = { try RedlightControlPreferences.record($0) },
         publish: @escaping @MainActor (Bool) throws -> Void = {
             let changed = RedlightControlPreferences.currentValue() != $0
             guard RedlightControlPreferences.publish($0) else {
                 throw ControlHandoffError.failed("Could not publish Redlight's state.")
             }
             if changed { reloadRedlightControls() }
         }, now: @escaping () -> Date = Date.init) {
        self.read = read; self.record = record; self.publish = publish; self.now = now
    }

    static func parse(_ url: URL) -> Request? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "redlight", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, parts.path.isEmpty,
              let host = parts.host, host == "on" || host == "off",
              let queries = parts.queryItems, queries.count == 1,
              queries[0].name == "request", let value = queries[0].value,
              let id = UUID(uuidString: value) else { return nil }
        return Request(id: id, on: host == "on")
    }

    @discardableResult func handle(url: URL) -> Bool {
        guard let request = Self.parse(url) else { return false }
        guard !completed.contains(request.id), read(request.id) == nil,
              !pending.contains(where: { $0.id == request.id }) else { return true }
        if execute != nil { complete(request) } else { pending.append(request) }
        return true
    }

    func install(setOn: @escaping (Bool) throws -> Bool) {
        execute = setOn
        let requests = pending
        pending.removeAll()
        for request in requests { complete(request) }
    }

    private func complete(_ request: Request) {
        guard let execute else { return }
        var on = request.on
        var error: String?
        do {
            on = try execute(request.on)
            try publish(on)
        } catch let failure { error = failure.localizedDescription }
        let receipt = ControlReceipt(request: request.id, on: on, error: error, completedAt: now())
        do {
            try record(receipt)
            completed.append(request.id)
            if completed.count > 128 { completed.removeFirst(completed.count - 128) }
        } catch {
            NSLog("Redlight control receipt failed: %@", error.localizedDescription)
        }
    }
}

@MainActor struct ControlHandoffClient {
    var open: (URL) async throws -> Void = Self.openURL
    var read: (UUID) -> ControlReceipt? = { RedlightControlPreferences.receipt($0) }
    var now: () -> Date = Date.init
    var sleep: () async throws -> Void = { try await Task.sleep(for: .milliseconds(50)) }
    var requestID: () -> UUID = UUID.init
    var timeout: TimeInterval = 5

    func setOn(_ on: Bool) async throws {
        let id = requestID()
        let url = URL(string: "redlight://\(on ? "on" : "off")?request=\(id.uuidString)")!
        let deadline = now().addingTimeInterval(timeout)
        let opener = open
        try await Self.awaitCompletion(timeout: timeout) { completion in
            let task = Task { @MainActor in
                do { try await opener(url); completion(.success(())) }
                catch { completion(.failure(error)) }
            }
            return { task.cancel() }
        }
        while true {
            try Task.checkCancellation()
            if let receipt = read(id) {
                guard receipt.request == id else { throw ControlHandoffError.failed("Redlight returned an invalid receipt.") }
                if let error = receipt.error { throw ControlHandoffError.failed(error) }
                guard receipt.on == on else { throw ControlHandoffError.failed("Redlight could not apply the requested state.") }
                return
            }
            guard now() < deadline else { throw ControlHandoffError.timeout }
            try await sleep()
        }
    }

    static func openURL(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        let owner = NSRunningApplication.runningApplications(withBundleIdentifier: RedlightControlPreferences.domain).first
        let launchURL = owner?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: RedlightControlPreferences.domain)
        try await awaitCompletion(timeout: 5) { complete in
            let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
                if let error { complete(.failure(error)) }
                else if app == nil { complete(.failure(ControlHandoffError.failed("Could not launch Redlight."))) }
                else { complete(.success(())) }
            }
            if let launchURL {
                NSWorkspace.shared.open([url], withApplicationAt: launchURL, configuration: configuration, completionHandler: completion)
            } else {
                NSWorkspace.shared.open(url, configuration: configuration, completionHandler: completion)
            }
            return nil
        }
    }

    /// Unstructured work lets cancellation/timeout return even if an external callback never arrives.
    private static func awaitCompletion(
        timeout: TimeInterval,
        start: (@escaping @Sendable (Result<Void, Error>) -> Void) -> (() -> Void)?
    ) async throws {
        let waiter = HandoffCallbackWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                if Task.isCancelled { waiter.finish(.failure(CancellationError())); return }
                waiter.cancelOperation = start { result in
                    Task { @MainActor in waiter.finish(result) }
                }
                waiter.timer = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(max(0, timeout))) }
                    catch { return }
                    waiter.finish(.failure(ControlHandoffError.timeout))
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor private final class HandoffCallbackWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    var timer: Task<Void, Never>?
    var cancelOperation: (() -> Void)?
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        if let result { continuation.resume(with: result) }
        else { self.continuation = continuation }
    }
    func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timer?.cancel(); timer = nil
        cancelOperation?(); cancelOperation = nil
        continuation?.resume(with: result); continuation = nil
    }
}

@available(macOS 15.0, *)
struct SetRedlightIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Redlight"
    static let openAppWhenRun = false
    @Parameter(title: "Enabled") var value: Bool
    init() {}
    init(_ value: Bool) { self.value = value }
    @MainActor func perform() async throws -> some IntentResult {
        if let setOn = IntentBridge.setOn {
            guard try setOn(value) == value else {
                throw ControlHandoffError.failed("Redlight could not apply the requested state.")
            }
        }
        else { try await IntentBridge.handoff(value) }
        return .result()
    }
}

@MainActor func reloadRedlightControls() {
    if #available(macOS 26.0, *) { ControlCenter.shared.reloadControls(ofKind: RedlightControlPreferences.kind) }
}

@MainActor func publishStopped() {
    if RedlightControlPreferences.publish(false) { reloadRedlightControls() }
}
