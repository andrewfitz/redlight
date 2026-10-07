import CoreGraphics
import Foundation

/// System services are injected so command tests never alter macOS appearance,
/// register a login item, start Sparkle, or terminate the test runner.
@MainActor
struct CommandServices {
    var appearance: () -> Bool
    var setAppearance: (Bool) throws -> Void
    var login: () -> Status.Login
    var setLogin: (Bool) throws -> Void
    var update: @MainActor @Sendable () -> Void
    var quit: @MainActor @Sendable () -> Void
    var version: () -> String
    var deferAction: (@escaping @MainActor @Sendable () -> Void) -> Void = { action in
        DispatchQueue.main.async { action() }
    }
    var canUpdate: () -> Bool = { true }
}

@MainActor
final class CommandHandler {
    private let manager: DisplayManager
    private let services: CommandServices

    init(manager: DisplayManager, services: CommandServices) {
        self.manager = manager
        self.services = services
    }

    func execute(_ command: RedlightCommand) throws -> Status {
        if command.isReadOnly { return snapshot() }
        guard !manager.isTerminating else {
            throw CommandError.system("Redlight is quitting; wait for it to stop before changing settings.")
        }

        // Resolve every display and validate every argument before touching a drag,
        // preferences, gamma, or a system service.
        let addressed: [CGDirectDisplayID]
        switch command {
        case .color(let value):
            try validate(value, channel: .color)
            addressed = []
        case .whitepoint(let value):
            try validate(value, channel: .whitepoint)
            addressed = []
        case .limits(let channel, let min, let max):
            try validate(min, channel: channel)
            try validate(max, channel: channel)
            guard min < max else {
                throw CommandError.invalidInput("\(channel.rawValue) limits require min < max.")
            }
            addressed = []
        case .display(let selector, _), .invert(let selector, _):
            addressed = try resolve(selector)
        case .preset(let preset), .savePreset(let preset):
            guard manager.presets.indices.contains(preset.index) else {
                throw CommandError.system("The \(preset.rawValue) preset is unavailable.")
            }
            addressed = []
        case .update:
            guard services.canUpdate() else {
                throw CommandError.system("The update service is unavailable for this copy of Redlight.")
            }
            addressed = []
        default:
            addressed = []
        }

        manager.interruptSliderInteraction()
        do {
            switch command {
            case .master(let state):
                manager.setAll(on: state.resolve(current: manager.isOn))
            case .color(let value):
                manager.intensity = value / 100
            case .whitepoint(let value):
                manager.whitepoint = value / 100
            case .reset(.color):
                manager.resetIntensity()
            case .reset(.whitepoint):
                manager.resetWhitepoint()
            case .preset(let preset):
                manager.applyPreset(preset.index)
            case .savePreset(let preset):
                manager.saveToPreset(preset.index)
            case .adaptive(let state):
                manager.adaptiveEnabled = state.resolve(current: manager.adaptiveEnabled)
            case .limits(.color, let min, let max):
                manager.adaptiveMin = min / 100
                manager.adaptiveMax = max / 100
                manager.flushBandRefresh()
            case .limits(.whitepoint, let min, let max):
                manager.adaptiveWpMin = min / 100
                manager.adaptiveWpMax = max / 100
                manager.flushBandRefresh()
            case .display(_, let state):
                let anyEnabled = manager.displays.contains { addressed.contains($0.id) && $0.isEnabled }
                let enabled = state.resolve(current: anyEnabled)
                for id in addressed { manager.setEnabled(enabled, for: id) }
            case .invert(_, let state):
                let anyInverted = manager.displays.contains { addressed.contains($0.id) && $0.isInverted }
                let inverted = state.resolve(current: anyInverted)
                for id in addressed { manager.setInverted(inverted, for: id) }
            case .appearance(let appearance):
                let dark = switch appearance {
                case .light: false
                case .dark: true
                case .toggle: !services.appearance()
                }
                try services.setAppearance(dark)
                guard services.appearance() == dark else {
                    throw CommandError.system("macOS did not apply the requested appearance.")
                }
            case .login(let enabled):
                try services.setLogin(enabled)
                let login = services.login()
                guard !login.requiresApproval else {
                    throw CommandError.system("Launch at Login needs approval in System Settings → Login Items.")
                }
                guard login.enabled == enabled else {
                    throw CommandError.system("macOS did not apply Launch at Login; check System Settings → Login Items.")
                }
            case .update:
                services.deferAction(services.update)
            case .quit:
                services.deferAction(services.quit)
            case .status, .displayList:
                break
            }
        } catch let error as CommandError {
            throw error
        } catch {
            throw CommandError.system(error.localizedDescription)
        }
        return snapshot()
    }

    func snapshot() -> Status {
        let target = manager.commandTargetOutput
        let preset = manager.activePresetIndex.flatMap { index in
            CommandPreset.allCases.first { $0.index == index }
        }
        return Status(
            on: manager.isOn,
            displays: manager.displays.enumerated().map { index, display in
                Status.Display(key: display.persistenceKey, number: index + 1, name: display.name,
                               enabled: display.isEnabled, inverted: display.isInverted)
            },
            color: Status.Level(set: manager.intensity * 100, target: target.intensity * 100),
            whitepoint: Status.Level(set: manager.whitepoint * 100, target: target.whitepoint * 100),
            activePreset: preset, adaptive: manager.adaptiveEnabled,
            elevation: manager.commandElevation, statusLine: manager.adaptiveStatusText,
            limits: Status.Limits(
                color: Status.Band(min: manager.intensityBand.lowerBound * 100,
                                   max: manager.intensityBand.upperBound * 100),
                whitepoint: Status.Band(min: manager.whitepointBand.lowerBound * 100,
                                        max: manager.whitepointBand.upperBound * 100)
            ),
            appearance: services.appearance() ? .dark : .light,
            login: services.login(), version: services.version(), fading: manager.commandIsFading
        )
    }

    private func validate(_ value: Double, channel: CommandChannel) throws {
        let range: ClosedRange<Double> = channel == .color ? 0...100 : 25...100
        guard value.isFinite, range.contains(value) else {
            throw CommandError.invalidInput("\(channel.rawValue) must be a finite percentage from \(Int(range.lowerBound)) to 100.")
        }
    }

    private func resolve(_ selector: CommandDisplaySelector) throws -> [CGDirectDisplayID] {
        let matches: [DisplayManager.DisplayInfo]
        switch selector {
        case .all:
            matches = manager.displays
        case .number(let number):
            guard number > 0, number <= manager.displays.count else {
                throw CommandError.invalidInput("Display number must be from 1 to \(manager.displays.count); use display list.")
            }
            matches = [manager.displays[number - 1]]
        case .name(let input):
            let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw CommandError.invalidInput("Display name must be a unique nonempty substring; use display list.")
            }
            matches = manager.displays.filter { $0.name.range(of: name, options: .caseInsensitive) != nil }
        case .key(let key):
            matches = manager.displays.filter { $0.persistenceKey == key }
        }
        guard !matches.isEmpty else {
            throw CommandError.invalidInput("No connected display matches; use display list.")
        }
        guard selector == .all || matches.count == 1 else {
            throw CommandError.invalidInput("Display name is ambiguous; use a display number from display list.")
        }
        return matches.map(\.id)
    }
}
