import CoreGraphics
import Foundation

/// Core Graphics reports hardware mode changes separately from AppKit's desktop updates.
final class DisplayReconfigurationObserver: @unchecked Sendable {
    private let changed: @MainActor @Sendable (CGDisplayChangeSummaryFlags) -> Void

    init(changed: @escaping @MainActor @Sendable (CGDisplayChangeSummaryFlags) -> Void) {
        self.changed = changed
        CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }

    static func isHardwareChange(_ flags: CGDisplayChangeSummaryFlags) -> Bool {
        let hardwareChanges: CGDisplayChangeSummaryFlags = [
            .setModeFlag, .addFlag, .removeFlag, .enabledFlag, .disabledFlag,
            .mirrorFlag, .unMirrorFlag,
        ]
        return !flags.contains(.beginConfigurationFlag) && !flags.intersection(hardwareChanges).isEmpty
    }

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context, DisplayReconfigurationObserver.isHardwareChange(flags) else { return }
        let observer = Unmanaged<DisplayReconfigurationObserver>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { [weak observer] in
            observer?.changed(flags)
        }
    }
}
