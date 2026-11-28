import AppKit
import CoreGraphics
import IOKit.pwr_mgt

/// Whether anyone can be looking at the screen. Learning counts time at the screen as
/// evidence, and ends its day only when nobody is there to see a change.
@MainActor
protocol PresenceMonitoring: AnyObject {
    /// The screens are asleep, the Mac is asleep or going to sleep, the screen is locked, or
    /// another user's session is in front.
    var isAway: Bool { get }
    /// Seconds since the last key, pointer or scroll input.
    func idleSeconds() -> TimeInterval
    /// The screen is locked, asked of the system now: a lock notification can arrive late.
    var isLocked: Bool { get }
    /// The screens or the Mac are asleep: a change made now is not seen.
    var areScreensAsleep: Bool { get }
    /// Something holds the displays awake on purpose, as a video playing does.
    var isVideoKeepingDisplayAwake: Bool { get }
    /// Called when `isAway` becomes true.
    var onAway: (@MainActor () -> Void)? { get set }
    /// Called when `isAway` becomes false.
    var onReturn: (@MainActor () -> Void)? { get set }
}

/// Presence from the system's own notifications. The lock notifications are not documented
/// API; without them a locked screen still counts as away once the displays sleep or input
/// has been idle for ten minutes.
@MainActor
final class SystemPresence: PresenceMonitoring {
    private var screensAsleep = false
    private var systemAsleep = false
    private var locked = false
    private var sessionInactive = false
    // nonisolated(unsafe): written on the main actor; read in deinit for cleanup.
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var distributedObservers: [NSObjectProtocol] = []

    var onAway: (@MainActor () -> Void)?
    var onReturn: (@MainActor () -> Void)?

    var isAway: Bool { screensAsleep || systemAsleep || locked || sessionInactive }

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        func watch(_ name: Notification.Name, _ change: @escaping @MainActor (SystemPresence) -> Void) {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update(change) }
            })
        }
        watch(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        watch(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        watch(NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        watch(NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        watch(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        watch(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }

        let distributed = DistributedNotificationCenter.default()
        func watchLock(_ name: String, _ value: Bool) {
            distributedObservers.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update { $0.locked = value } }
            })
        }
        watchLock("com.apple.screenIsLocked", true)
        watchLock("com.apple.screenIsUnlocked", false)
    }

    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func update(_ change: @MainActor (SystemPresence) -> Void) {
        let wasAway = isAway
        change(self)
        if isAway, !wasAway { onAway?() }
        if !isAway, wasAway { onReturn?() }
    }

    func idleSeconds() -> TimeInterval {
        // Any input event type: the raw value is the "any event" wildcard CoreGraphics accepts.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    var isLocked: Bool {
        // Not documented API either; a missing key reads as unlocked.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    var areScreensAsleep: Bool { screensAsleep || systemAsleep }

    var isVideoKeepingDisplayAwake: Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let assertions = status?.takeRetainedValue() as? [String: Any] else { return false }
        // `kIOPMAssertPreventUserIdleDisplaySleep`, a CFSTR macro Swift does not import.
        return (assertions["PreventUserIdleDisplaySleep"] as? Int ?? 0) > 0
    }
}
