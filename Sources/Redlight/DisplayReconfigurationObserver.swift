import CoreGraphics
import Foundation

/// Core Graphics reports hardware mode changes separately from AppKit's desktop updates.
@MainActor
final class DisplayReconfigurationObserver {
    // Core Graphics can invoke the callback on a different thread during teardown.
    // Pass an opaque registration number so an in-flight callback never dereferences
    // a destroyed observer, even if a new one occupies the same address.
    private static var nextID: UInt = 1
    private static let observers = NSMapTable<NSNumber, DisplayReconfigurationObserver>.strongToWeakObjects()
    private let id: UInt
    private let changed: @MainActor @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void

    init(changed: @escaping @MainActor @Sendable (CGDirectDisplayID, CGDisplayChangeSummaryFlags) -> Void) {
        self.changed = changed
        id = Self.nextID
        Self.nextID += 1
        Self.observers.setObject(self, forKey: NSNumber(value: id))
        let result = CGDisplayRegisterReconfigurationCallback(Self.callback, UnsafeMutableRawPointer(bitPattern: id))
        if result != .success {
            NSLog("Redlight: display reconfiguration callback registration failed (%d).", result.rawValue)
        }
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(Self.callback, UnsafeMutableRawPointer(bitPattern: id))
        let removedID = id
        Task { @MainActor in Self.observers.removeObject(forKey: NSNumber(value: removedID)) }
    }

    nonisolated static func isHardwareChange(_ flags: CGDisplayChangeSummaryFlags) -> Bool {
        let hardwareChanges: CGDisplayChangeSummaryFlags = [
            .setModeFlag, .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
            .mirrorFlag, .unMirrorFlag,
        ]
        return !flags.contains(.beginConfigurationFlag) && !flags.intersection(hardwareChanges).isEmpty
    }

    nonisolated private static let callback: CGDisplayReconfigurationCallBack = { display, flags, context in
        guard let context, DisplayReconfigurationObserver.isHardwareChange(flags) else { return }
        let id = UInt(bitPattern: context)
        DispatchQueue.main.async {
            observers.object(forKey: NSNumber(value: id))?.changed(display, flags)
        }
    }
}
