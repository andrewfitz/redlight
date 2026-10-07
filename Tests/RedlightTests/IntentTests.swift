import AppIntents
import CoreGraphics
import Foundation
import Testing
@testable import Redlight

@MainActor @Suite(.serialized) struct IntentTests {
    @Test func everyIntentExecutesThroughTheHandler() async throws {
        let domain = "RedlightIntentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); IntentBridge.uninstall() }
        let gamma = MockGammaController()
        let manager = DisplayManager(
            gamma: gamma, getDisplayIDs: { [1, 2] }, getDisplayName: { "Display \($0)" },
            getDisplayPersistenceKey: { "stable-\($0)" }, defaults: defaults,
            location: FakeLocationProvider(), adaptiveTransitionDuration: 0, displayTransitionDuration: 0
        )
        var dark = false
        var login = false
        var updated = false
        var quit = false
        let services = CommandServices(
            appearance: { dark }, setAppearance: { dark = $0 },
            login: { Status.Login(enabled: login, requiresApproval: false) }, setLogin: { login = $0 },
            update: { updated = true }, quit: { quit = true }, version: { "test-version" },
            deferAction: { $0() }
        )
        let handler = CommandHandler(manager: manager, services: services)
        var received: [RedlightCommand] = []
        IntentBridge.install(execute: { command in
            received.append(command)
            return try handler.execute(command)
        }, snapshot: { handler.snapshot() })
        _ = try await TurnOnRedlightIntent().perform()
        _ = try await TurnOffRedlightIntent().perform()
        _ = try await SetRedlightStateIntent(mode: .toggle).perform()
        _ = try await SetRedlightColorIntent(value: 55).perform()
        _ = try await SetRedlightWhitepointIntent(value: 65).perform()
        _ = try await ResetRedlightLevelIntent(channel: .color).perform()
        _ = try await ResetRedlightLevelIntent(channel: .whitepoint).perform()
        _ = try await SetRedlightPresetIntent(preset: .night).perform()
        _ = try await SaveRedlightPresetIntent(preset: .warm).perform()
        _ = try await TurnOnRedlightAdaptiveIntent().perform()
        _ = try await SetRedlightAdaptiveIntent(mode: .off).perform()
        _ = try await SetRedlightLimitsIntent(channel: .color, minimum: 10, maximum: 90).perform()
        _ = try await SetRedlightLimitsIntent(channel: .whitepoint, minimum: 35, maximum: 95).perform()
        let display = DisplayEntity(id: "stable-2", name: "Display 2")
        _ = try await SetRedlightDisplayIntent(display: display, mode: .on).perform()
        _ = try await SetRedlightInvertIntent(display: .all, mode: .toggle).perform()
        _ = try await SetRedlightAppearanceIntent(appearance: .dark).perform()
        _ = try await SetRedlightLoginIntent(enabled: true).perform()
        let statusResult = try await GetRedlightStatusIntent().perform()
        #expect(statusResult.value?.contains("test-version") == true)
        let displayResult = try await ListRedlightDisplaysIntent().perform()
        #expect(displayResult.value?.map(\.id) == ["stable-1", "stable-2"])
        if #available(macOS 15.0, *) { _ = try await SetRedlightIntent(false).perform() }
        _ = try await UpdateRedlightIntent().perform()
        _ = try await QuitRedlightIntent().perform()
        var expected: [RedlightCommand] = [
            .master(.on), .master(.off), .master(.toggle), .color(55), .whitepoint(65),
            .reset(.color), .reset(.whitepoint), .preset(.night), .savePreset(.warm),
            .adaptive(.on), .adaptive(.off), .limits(.color, min: 10, max: 90),
            .limits(.whitepoint, min: 35, max: 95), .display(.key("stable-2"), .on),
            .invert(.all, .toggle), .appearance(.dark), .login(true), .status, .displayList,
        ]
        if #available(macOS 15.0, *) { expected.append(.master(.off)) }
        expected += [.update, .quit]
        #expect(received == expected)
        #expect(dark && login && updated && quit)
        #expect(!gamma.applyCalls.isEmpty)
    }

    @Test func enumsEntitiesAndFourShortcutsMatchCommands() async throws {
        #expect(RedlightPreset.allCases.map(\.rawValue) == CommandPreset.allCases.map(\.rawValue))
        #expect(RedlightMode.allCases.map(\.rawValue) == CommandSwitch.allCases.map(\.rawValue))
        #expect(RedlightChannel.allCases.map(\.rawValue) == CommandChannel.allCases.map(\.rawValue))
        #expect(RedlightAppearance.allCases.map(\.rawValue) == CommandAppearance.allCases.map(\.rawValue))
        #expect(RedlightShortcuts.appShortcuts.count == 4)
        let status = Status(displays: [Status.Display(key: "monitor-uuid", number: 1, name: "Studio Display", enabled: true, inverted: false)])
        IntentBridge.install(execute: { _ in status }, snapshot: { status })
        defer { IntentBridge.uninstall() }
        let query = DisplayEntityQuery()
        let suggestions = try await query.suggestedEntities()
        #expect(suggestions.map(\.id) == [DisplayEntity.allID, "monitor-uuid"])
        #expect(try await query.entities(for: ["monitor-uuid", "disconnected"]).map(\.id) == ["monitor-uuid"])
        #expect(try await query.entities(matching: "studio").map(\.id) == ["monitor-uuid"])
        #expect(suggestions[0].selector == .all)
        #expect(suggestions[1].selector == .key("monitor-uuid"))
    }

    @Test func handlerValidationErrorsReachTheIntent() async throws {
        IntentBridge.install(execute: { _ in throw CommandError.invalidInput("rejected") }, snapshot: { Status() })
        defer { IntentBridge.uninstall() }
        await #expect(throws: CommandError.invalidInput("rejected")) {
            _ = try await SetRedlightColorIntent(value: 101).perform()
        }
    }

    @Test(arguments: [false, true]) func controlIntentWithoutBridgeUsesHandoff(running: Bool) async throws {
        guard #available(macOS 15.0, *) else { return }
        IntentBridge.uninstall()
        defer { IntentBridge.uninstall() }
        var receipts: [UUID: ControlReceipt] = [:]
        let coordinator = ControlHandoff(read: { receipts[$0] }, record: { receipts[$0.request] = $0 }, publish: { _ in })
        if running { coordinator.install(setOn: { $0 }) }
        var client = ControlHandoffClient()
        client.open = { url in
            #expect(coordinator.handle(url: url))
            if !running { coordinator.install(setOn: { $0 }) }
        }
        client.read = { receipts[$0] }
        IntentBridge.handoff = { try await client.setOn($0) }
        _ = try await SetRedlightIntent(true).perform()
        #expect(receipts.values.first?.on == true)
        IntentBridge.setOn = { _ in false }
        await #expect(throws: (any Error).self) { _ = try await SetRedlightIntent(true).perform() }
    }
}
