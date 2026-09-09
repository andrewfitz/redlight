import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import Redlight

@Suite struct AppLifecycleTests {
    /// `DisplaySessionRecovery` calls `synchronize()`, which writes a real plist under
    /// ~/Library/Preferences. Clean it up afterwards so test runs leave no litter.
    func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let name = "RedlightLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer {
            defaults.removePersistentDomain(forName: name)
            defaults.synchronize()
        }
        body(defaults)
    }

    @Test func cleanSessionDoesNotTriggerRecoveryButUncleanSessionDoes() {
        withFreshDefaults { defaults in
            var restoreCount = 0

            DisplaySessionRecovery.begin(defaults: defaults) { restoreCount += 1 }
            #expect(restoreCount == 0)       // first launch has nothing stale to recover
            DisplaySessionRecovery.finish(defaults: defaults)

            DisplaySessionRecovery.begin(defaults: defaults) { restoreCount += 1 }
            #expect(restoreCount == 0)       // previous session exited cleanly

            // Beginning again without `finish` simulates a crash/kill during the prior session.
            DisplaySessionRecovery.begin(defaults: defaults) { restoreCount += 1 }
            #expect(restoreCount == 1)
        }
    }

    @Test @MainActor func pendingLoginItemApprovalStillCountsAsRegistered() {
        #expect(LaunchAtLogin.isRegistered(.enabled))
        #expect(LaunchAtLogin.isRegistered(.requiresApproval))
        #expect(!LaunchAtLogin.isRegistered(.notRegistered))
        #expect(!LaunchAtLogin.isRegistered(.notFound))
    }

    @Test @MainActor func terminationCoordinatorDefersOnceAndRepliesOnce() {
        let coordinator = TerminationCoordinator()
        var prepareCount = 0
        var replyCount = 0
        var pendingCompletion: (() -> Void)?
        let prepare: TerminationCoordinator.Prepare = { completion in
            prepareCount += 1
            pendingCompletion = completion
        }

        let first = coordinator.request(prepare: prepare) { replyCount += 1 }
        let repeated = coordinator.request(prepare: prepare) { replyCount += 1 }
        #expect(first == .terminateLater)
        #expect(repeated == .terminateLater)
        #expect(prepareCount == 1)
        #expect(replyCount == 0)

        pendingCompletion?()
        pendingCompletion?()                    // a bad duplicate callback is harmless
        #expect(replyCount == 1)

        let approved = coordinator.request(prepare: prepare) { replyCount += 1 }
        #expect(approved == .terminateNow)
        #expect(prepareCount == 1)
        #expect(replyCount == 1)

        let noOpCoordinator = TerminationCoordinator()
        var noOpReplyCount = 0
        let noOp = noOpCoordinator.request(prepare: { $0() }) {
            noOpReplyCount += 1
        }
        #expect(noOp == .terminateNow)
        #expect(noOpReplyCount == 0)             // no reply is needed before returning now
    }
}
