import Foundation
import Testing
@testable import Redlight

@MainActor @Suite struct ControlHandoffTests {
    func url(_ on: Bool, _ id: UUID) -> URL {
        URL(string: "redlight://\(on ? "on" : "off")?request=\(id.uuidString)")!
    }

    @Test func rejectsUnrecognizedURLsAndQueuesUntilReady() {
        var receipts: [UUID: ControlReceipt] = [:]
        var state = false
        var executed = 0
        let handoff = ControlHandoff(read: { receipts[$0] }, record: { receipts[$0.request] = $0 }, publish: { state = $0 })
        let id = UUID()
        #expect(handoff.handle(url: url(true, id)))
        #expect(handoff.handle(url: url(true, id)))
        #expect(receipts.isEmpty)
        for invalid in [
            "other://on?request=\(id)", "redlight://toggle?request=\(id)",
            "redlight://on/extra?request=\(id)", "redlight://on?request=bad",
            "redlight://on?request=\(id)&request=\(id)", "redlight://on?request=\(id)#bad",
            "redlight://user@on?request=\(id)", "redlight://on:42?request=\(id)",
        ] { #expect(!handoff.handle(url: URL(string: invalid)!)) }
        handoff.install(setOn: { executed += 1; return $0 })
        #expect(state && executed == 1)
        #expect(receipts[id]?.on == true)
        #expect(receipts[id]?.error == nil)
        #expect(handoff.handle(url: url(true, id)))
        #expect(executed == 1)
    }

    @Test(arguments: [false, true]) func nilBridgeRouteWaitsForCompletionWhetherAppIsStoppedOrRunning(running: Bool) async throws {
        var receipts: [UUID: ControlReceipt] = [:]
        var state = false
        let handoff = ControlHandoff(read: { receipts[$0] }, record: { receipts[$0.request] = $0 }, publish: { state = $0 })
        if running { handoff.install(setOn: { $0 }) }
        var opens = 0
        var client = ControlHandoffClient()
        client.open = { url in
            opens += 1
            #expect(handoff.handle(url: url))
            if !running { handoff.install(setOn: { $0 }) }
        }
        client.read = { receipts[$0] }
        try await client.setOn(true)
        #expect(opens == 1 && state)
    }

    @Test func concurrentRequestsRetainIndependentResults() async throws {
        var receipts: [UUID: ControlReceipt] = [:]
        var state = false
        let handoff = ControlHandoff(read: { receipts[$0] }, record: { receipts[$0.request] = $0 }, publish: { state = $0 })
        handoff.install(setOn: { $0 })
        let first = UUID(), second = UUID()
        var onClient = ControlHandoffClient()
        onClient.open = { _ in
            #expect(handoff.handle(url: url(true, first)))
            #expect(handoff.handle(url: url(false, second)))
        }
        onClient.read = { receipts[$0] }
        onClient.requestID = { first }
        var offClient = onClient
        offClient.open = { _ in }
        offClient.requestID = { second }
        async let onResult: Void = onClient.setOn(true)
        async let offResult: Void = offClient.setOn(false)
        _ = try await (onResult, offResult)
        #expect(receipts[first]?.on == true)
        #expect(receipts[second]?.on == false)
        #expect(!state) // Current state may reflect the later request when the first returns.
    }

    @Test func launchErrorsCommandErrorsAndTimeoutNeverReportSuccess() async {
        let id = UUID()
        var client = ControlHandoffClient()
        client.requestID = { id }
        client.open = { _ in throw ControlHandoffError.failed("launch failed") }
        client.read = { _ in Issue.record("Receipt must not be read after a launch failure"); return nil }
        await #expect(throws: (any Error).self) { try await client.setOn(true) }
        client.open = { _ in }
        client.read = { _ in ControlReceipt(request: id, on: true, error: "command failed", completedAt: Date()) }
        await #expect(throws: (any Error).self) { try await client.setOn(true) }
        client.read = { _ in nil }
        var instant = Date(timeIntervalSince1970: 0)
        var sleeps = 0
        client.now = { instant }
        client.sleep = { instant = instant.addingTimeInterval(1); sleeps += 1 }
        await #expect(throws: (any Error).self) { try await client.setOn(true) }
        #expect(sleeps == 5)
    }

    @Test func appRecordsCommandFailureAndRefreshesPreferences() throws {
        var receipt: ControlReceipt?
        let handoff = ControlHandoff(read: { _ in nil }, record: { receipt = $0 }, publish: { _ in Issue.record("Failed command cannot publish successful state") })
        handoff.install(setOn: { _ in throw ControlHandoffError.failed("command rejected") })
        #expect(handoff.handle(url: url(true, UUID())))
        #expect(receipt?.error == "command rejected")
        let domain = "RedlightControlTests-\(UUID().uuidString)"
        defer {
            for key in [RedlightControlPreferences.stateKey, RedlightControlPreferences.receiptsKey] {
                CFPreferencesSetValue(key as CFString, nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        #expect(!RedlightControlPreferences.currentValue(domain: domain))
        #expect(RedlightControlPreferences.publish(true, domain: domain))
        #expect(RedlightControlPreferences.currentValue(domain: domain))
        let now = Date()
        let expired = ControlReceipt(request: UUID(), on: false, error: nil, completedAt: now.addingTimeInterval(-121))
        try RedlightControlPreferences.record(expired, domain: domain, now: expired.completedAt)
        let recent = ControlReceipt(request: UUID(), on: true, error: nil, completedAt: now)
        try RedlightControlPreferences.record(recent, domain: domain, now: now)
        #expect(RedlightControlPreferences.receipt(expired.request, domain: domain) == nil)
        #expect(RedlightControlPreferences.receipt(recent.request, domain: domain) == recent)
        let seeded = (0..<129).map { offset in
            ControlReceipt(request: UUID(), on: true, error: nil, completedAt: now.addingTimeInterval(-Double(offset) / 10))
        }
        let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: seeded.map { ($0.request.uuidString, $0) }))
        CFPreferencesSetValue(RedlightControlPreferences.receiptsKey as CFString, data as CFData,
                              domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        try RedlightControlPreferences.record(recent, domain: domain, now: now)
        #expect(RedlightControlPreferences.receipts(domain: domain).count == 128)
        #expect(RedlightControlPreferences.receipt(seeded.last!.request, domain: domain) == nil)
    }

    @Test func launchWaitIsBoundedAndCancellableEvenWhenOpenerIgnoresCancellation() async {
        var pending: CheckedContinuation<Void, Never>?
        var client = ControlHandoffClient()
        client.timeout = 0.01
        client.open = { _ in await withCheckedContinuation { pending = $0 } }
        client.read = { _ in Issue.record("Timed out launch cannot read receipts"); return nil }
        await #expect(throws: (any Error).self) { try await client.setOn(true) }
        pending?.resume()
        pending = nil
        client.timeout = 5
        let task = Task { try await client.setOn(false) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        guard pending != nil else { task.cancel(); Issue.record("Opener never started"); return }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        pending?.resume()
    }
}
