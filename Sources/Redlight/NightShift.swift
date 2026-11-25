import Foundation

/// Night Shift, as far as Redlight needs it: is it on, turn it off, say when it changes.
@MainActor
protocol NightShiftControlling: AnyObject {
    var isOn: Bool { get }
    func turnOff()
    /// Called on the main actor whenever Night Shift's status changes.
    var onChange: (() -> Void)? { get set }
}

/// "Keep Night Shift off", in Settings, on unless the user switches it off. Night Shift adds
/// its own tint on top of Redlight's, so Redlight turns Night Shift off whenever it comes on: at launch,
/// when the setting is switched on, and when Night Shift's schedule or the user starts it.
/// Night Shift's own schedule is not changed, so it returns at its next start once the
/// setting is off or Redlight has quit.
@MainActor
@Observable
final class NightShiftGuard {
    static let shared = NightShiftGuard()
    static let key = "redlight.keepNightShiftOff"

    private(set) var keepsOff: Bool
    /// False until `connect` is given the system's Night Shift, which only the app does:
    /// tests and renders never reach the real setting, and Settings hides the switch.
    private(set) var isAvailable = false
    @ObservationIgnored private var nightShift: NightShiftControlling?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepsOff = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    /// Nil where this Mac or this macOS has no Night Shift that Redlight can reach.
    func connect(_ nightShift: NightShiftControlling?) {
        self.nightShift?.onChange = nil
        self.nightShift = nightShift
        isAvailable = nightShift != nil
        nightShift?.onChange = { [weak self] in self?.enforce() }
        enforce()
    }

    /// Does nothing until `connect` has a Night Shift, so a render's stand-in switch cannot
    /// write the setting.
    func setKeepsOff(_ keepsOff: Bool) {
        guard isAvailable, keepsOff != self.keepsOff else { return }
        self.keepsOff = keepsOff
        defaults.set(keepsOff, forKey: Self.key)
        enforce()
    }

    private func enforce() {
        guard keepsOff, let nightShift, nightShift.isOn else { return }
        nightShift.turnOff()
    }
}

/// The system's Night Shift, through CoreBrightness's `CBBlueLightClient`. That class is
/// private, so every selector is checked against the exact signature Redlight was written
/// for before anything is called: on a macOS that changes one, `init` fails and the setting
/// disappears instead of misreading the status structure.
@MainActor
final class SystemNightShift: NightShiftControlling {
    var onChange: (() -> Void)?

    // nonisolated(unsafe): set once in init; read again only in deinit to drop the block.
    nonisolated(unsafe) private let client: NSObject

    private typealias GetStatus = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabled = @convention(c) (NSObject, Selector, Bool) -> Bool
    private typealias SetBlock = @convention(c) (NSObject, Selector, AnyObject?) -> Void
    private typealias Supports = @convention(c) (AnyClass, Selector) -> Bool

    private nonisolated static let getStatus = NSSelectorFromString("getBlueLightStatus:")
    private nonisolated static let setEnabled = NSSelectorFromString("setEnabled:")
    private nonisolated static let setBlock = NSSelectorFromString("setStatusNotificationBlock:")
    private nonisolated static let supports = NSSelectorFromString("supportsBlueLightReduction")

    /// The Objective-C type encodings of the three methods, as macOS 14 through 27 have
    /// them. The status is `{BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode;
    /// {{int,int},{int,int}} schedule; unsigned long long disableFlags; BOOL available}`.
    private static let signatures: [(Selector, String)] = [
        (getStatus, "B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16"),
        (setEnabled, "B20@0:8B16"),
        (setBlock, "v24@0:8@?16"),
    ]
    /// `enabled`, the second BOOL of the status: Night Shift is tinting the display now.
    private static let enabledOffset = 1
    /// Room for the 40-byte status, with slack.
    private static let statusSize = 64

    init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        for (selector, signature) in Self.signatures {
            guard let method = class_getInstanceMethod(type, selector),
                  let encoding = method_getTypeEncoding(method),
                  String(cString: encoding) == signature else { return nil }
        }
        // Macs whose display cannot do Night Shift say so here.
        guard let supports = class_getClassMethod(type, Self.supports) else { return nil }
        let isSupported = unsafeBitCast(method_getImplementation(supports), to: Supports.self)
        guard isSupported(type, Self.supports) else { return nil }

        client = type.init()
        // The block's one argument, a pointer to the new status, is ignored: the status is
        // read again on the main actor, where the answer is acted on.
        let block: @convention(block) (UnsafeRawPointer?) -> Void = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange?() } }
        }
        Self.call(client, Self.setBlock, as: SetBlock.self)(client, Self.setBlock, block as AnyObject)
    }

    deinit {
        Self.call(client, Self.setBlock, as: SetBlock.self)(client, Self.setBlock, nil)
    }

    var isOn: Bool {
        let status = UnsafeMutableRawPointer.allocate(byteCount: Self.statusSize, alignment: 8)
        defer { status.deallocate() }
        status.initializeMemory(as: UInt8.self, repeating: 0, count: Self.statusSize)
        guard Self.call(client, Self.getStatus, as: GetStatus.self)(client, Self.getStatus, status) else { return false }
        return status.load(fromByteOffset: Self.enabledOffset, as: UInt8.self) != 0
    }

    func turnOff() {
        _ = Self.call(client, Self.setEnabled, as: SetEnabled.self)(client, Self.setEnabled, false)
    }

    private nonisolated static func call<Function>(_ object: NSObject, _ selector: Selector, as _: Function.Type) -> Function {
        unsafeBitCast(object.method(for: selector), to: Function.self)
    }
}
