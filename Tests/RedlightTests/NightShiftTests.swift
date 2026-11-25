import Foundation
import Testing
@testable import Redlight

@MainActor
private final class FakeNightShift: NightShiftControlling {
    var isOn = false
    var turnOffCount = 0
    var onChange: (() -> Void)?

    func turnOff() {
        turnOffCount += 1
        isOn = false
    }

    /// Night Shift comes on, as its schedule or the user would make it, and says so.
    func comeOn() {
        isOn = true
        onChange?()
    }
}

/// The guard only ever meets a fake here: the tests never reach the system's Night Shift.
@MainActor @Suite struct NightShiftGuardTests {
    let defaultsRegistry = TestDefaultsRegistry()

    @Test func withoutNightShiftTheSettingIsUnavailableAndCannotBeWritten() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "NightShiftTests")
        let nightShift = NightShiftGuard(defaults: defaults)
        #expect(!nightShift.isAvailable && nightShift.keepsOff)
        nightShift.setKeepsOff(false)
        #expect(nightShift.keepsOff)
        #expect(defaults.object(forKey: NightShiftGuard.key) == nil)
        nightShift.connect(nil)
        #expect(!nightShift.isAvailable)
    }

    @Test func onByDefaultSoNightShiftIsTurnedOffAtLaunchAndWheneverItComesBack() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "NightShiftTests")
        let system = FakeNightShift()
        system.isOn = true
        let nightShift = NightShiftGuard(defaults: defaults)
        #expect(nightShift.keepsOff && system.isOn)        // nothing to act through yet
        nightShift.connect(system)
        #expect(nightShift.isAvailable && nightShift.keepsOff)
        #expect(!system.isOn && system.turnOffCount == 1)
        #expect(defaults.object(forKey: NightShiftGuard.key) == nil)   // the default is not written
        // Its schedule starts it again.
        system.comeOn()
        #expect(!system.isOn && system.turnOffCount == 2)
        // A change that leaves it off is nothing to act on.
        system.onChange?()
        #expect(system.turnOffCount == 2)
    }

    @Test func switchedOffNightShiftIsLeftAloneUntilItIsSwitchedOnAgain() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "NightShiftTests")
        let system = FakeNightShift()
        let nightShift = NightShiftGuard(defaults: defaults)
        nightShift.connect(system)
        nightShift.setKeepsOff(false)
        #expect(defaults.object(forKey: NightShiftGuard.key) as? Bool == false)
        system.comeOn()
        #expect(system.isOn && system.turnOffCount == 0)

        // The choice is remembered: a relaunch leaves Night Shift alone too.
        let relaunched = NightShiftGuard(defaults: defaults)
        #expect(!relaunched.keepsOff)
        relaunched.connect(system)
        #expect(system.isOn && system.turnOffCount == 0)

        // Switched on again, it acts at once.
        relaunched.setKeepsOff(true)
        #expect(defaults.object(forKey: NightShiftGuard.key) as? Bool == true)
        #expect(!system.isOn && system.turnOffCount == 1)
    }

    @Test func aSavedSettingIsEnforcedAtLaunch() {
        let defaults = defaultsRegistry.makeDefaults(prefix: "NightShiftTests")
        defaults.set(true, forKey: NightShiftGuard.key)
        let system = FakeNightShift()
        system.isOn = true
        let nightShift = NightShiftGuard(defaults: defaults)
        #expect(nightShift.keepsOff && system.isOn)        // nothing to act through yet
        nightShift.connect(system)
        #expect(!system.isOn && system.turnOffCount == 1)
    }
}
