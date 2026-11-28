import CoreGraphics
import Foundation

/// System services are injected so command tests never alter macOS appearance,
/// register a login item, start Sparkle, or terminate the test runner.
@MainActor
struct CommandServices {
    var appearance: () -> Bool
    var refreshAppearance: () -> Void = {}
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
    /// The apps with a rule, in the order chosen.
    var appRules: () -> [Status.App] = { [] }
    var changeApps: (CommandApps) throws -> Void = { _ in
        throw CommandError.system("App rules are unavailable in this copy of Redlight.")
    }
}

@MainActor
final class CommandHandler {
    private struct PeekLease {
        let pauseWasActive: Bool
        let expiresAt: ContinuousClock.Instant
    }

    private let manager: DisplayManager
    private let services: CommandServices
    private let peekNow: () -> ContinuousClock.Instant
    private var commandPeek: PeekLease?
    private var commandPeekLeaseTimer: Timer?
    private static let commandPeekLease = ShortcutController.untrackedHoldLimit

    init(manager: DisplayManager, services: CommandServices,
         peekNow: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.manager = manager
        self.services = services
        self.peekNow = peekNow
    }

    isolated deinit { endCommandPeek() }

    func execute(_ command: RedlightCommand) throws -> Status {
        if command.isReadOnly { return snapshot() }
        // Kelvin is Color temp's percent on the display the popover reads it from.
        switch command {
        case .colorKelvin(let kelvin):
            return try execute(.color(try kelvinPercent(kelvin)))
        case .limitsKelvin(let low, let high):
            let a = try kelvinPercent(low), b = try kelvinPercent(high)
            return try execute(.limits(.color, min: min(a, b), max: max(a, b)))
        default:
            break
        }
        guard !manager.isTerminating else {
            throw CommandError.system("Redlight is quitting; wait for it to stop before changing settings.")
        }
        if case .peek(let action) = command { return try executePeek(action) }

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
        case .saturation(let value):
            try validateSaturation(value)
            addressed = []
        case .learn(.restore):
            guard manager.learningBackupCount > 0 else {
                throw CommandError.invalidInput("There is no earlier learning to restore.")
            }
            addressed = []
        case .step(_, let delta):
            guard delta.isFinite, delta != 0, abs(delta) <= 100 else {
                throw CommandError.invalidInput("A step must be a nonzero percentage up to 100.")
            }
            addressed = []
        case .saturationStep(let delta):
            guard delta.isFinite, delta != 0, abs(delta) <= 100 else {
                throw CommandError.invalidInput("A saturation step must be a nonzero percentage up to 100.")
            }
            addressed = []
        case .pause(let state):
            if state.resolve(current: manager.isPaused), !manager.isPaused, !manager.isOn {
                throw CommandError.invalidInput("Turn Redlight on before pausing.")
            }
            addressed = []
        case .pauseFor(let length):
            return try pause(for: length)
        case .location(.manual(let latitude, let longitude)):
            try ManualLocation.validate(latitude: latitude, longitude: longitude)
            addressed = []
        case .bedtime(.at(let hour, let minute)):
            guard Bedtime(hour: hour, minute: minute) != nil else {
                throw CommandError.invalidInput(Bedtime.invalidMessage)
            }
            addressed = []
        case .wake(.at(let hour, let minute)):
            guard Bedtime(hour: hour, minute: minute) != nil else {
                throw CommandError.invalidInput(Bedtime.invalidWakeMessage)
            }
            addressed = []
        case .apps(.set(let bundleID, let rule)):
            _ = try AppBundleID.validate(bundleID)
            _ = try rule.validated()
            addressed = []
        case .apps(.remove(let bundleID)):
            guard services.appRules().contains(where: { AppBundleID.matches($0.bundleID, bundleID) }) else {
                throw CommandError.invalidInput("\(bundleID) has no rule; use redlight apps list.")
            }
            addressed = []
        case .limits(let channel, let min, let max):
            try validate(min, channel: channel)
            try validate(max, channel: channel)
            guard min <= max else {
                throw CommandError.invalidInput("\(channel.displayName) limits require min ≤ max.")
            }
            addressed = []
        case .display(let selector, _), .invert(let selector, _):
            addressed = try resolve(selector)
        case .preset(let preset), .savePreset(let preset):
            guard manager.presets.indices.contains(preset.index) else {
                throw CommandError.system("The \(preset.cliName) preset is unavailable.")
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
            case .colorKelvin, .limitsKelvin:
                break  // Turned into percents above.
            case .master(let state):
                // Paused reads as off, so toggling or turning on resumes.
                manager.setAll(on: state.resolve(current: manager.isFiltering))
            case .color(let value):
                manager.intensity = value / 100
            case .whitepoint(let value):
                manager.whitepoint = WhitepointScale.output(percent: value)
            case .saturation(let value):
                manager.saturation = value / 100
            case .saturationStep(let delta):
                if delta.rounded() != 0 { manager.saturation = (Double(manager.saturationPercent) + delta.rounded()) / 100 }
            case .saturationEnabled(let state):
                manager.saturationEnabled = state.resolve(current: manager.saturationEnabled)
            case .step(.color, let delta):
                if delta.rounded() != 0 { manager.intensity = (Double(manager.colorPercent) + delta.rounded()) / 100 }
            case .step(.whitepoint, let delta):
                if delta.rounded() != 0 {
                    manager.whitepoint = WhitepointScale.output(percent: Double(manager.whitepointPercent) + delta.rounded())
                }
            case .pause(let state):
                if state.resolve(current: manager.isPaused) {
                    if !manager.isPaused { manager.pause() }
                } else {
                    manager.resume()
                }
            case .location(.automatic):
                manager.setManualLocation(nil)
            case .location(.manual(let latitude, let longitude)):
                manager.setManualLocation((latitude, longitude))
            case .bedtime(.off):
                manager.setBedtime(nil)
            case .bedtime(.at(let hour, let minute)):
                manager.setBedtime(Bedtime(hour: hour, minute: minute))
            case .wake(.off):
                manager.setWakeTime(nil)
            case .wake(.at(let hour, let minute)):
                manager.setWakeTime(Bedtime(hour: hour, minute: minute))
            case .learn(.reset):
                manager.resetLearning()
            case .learn(.restore):
                manager.restoreLearning()
            case .learn(let change):
                manager.setLearning(change == .toggle ? !manager.learningEnabled : change == .on)
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
                manager.adaptiveWpMin = WhitepointScale.output(percent: min)
                manager.adaptiveWpMax = WhitepointScale.output(percent: max)
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
                if appearance == .toggle { services.refreshAppearance() }
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
            case .apps(let change):
                try services.changeApps(change)
            case .pauseFor, .status, .displayList, .appsList, .peek:
                break
            }
        } catch let error as CommandError {
            throw error
        } catch {
            throw CommandError.system(error.localizedDescription)
        }
        return snapshot()
    }

    /// The display kelvin is read on: the first one tinted, as in the popover.
    private var kelvinScale: KelvinScale {
        let display = manager.displays.first { $0.isEnabled }?.id ?? manager.displays.first?.id ?? CGMainDisplayID()
        return KelvinScale.forDisplay(display)
    }

    private func kelvinPercent(_ kelvin: Double) throws -> Double {
        let scale = kelvinScale
        guard let percent = scale.percent(forKelvin: kelvin) else {
            let range = scale.bounds.map {
                "from \(KelvinScale.text(kelvin: $0.lowerBound)) to \(KelvinScale.text(kelvin: $0.upperBound))"
            } ?? "not available"
            throw CommandError.invalidInput("Color temp in kelvin is \(range) on this display.")
        }
        return percent
    }

    func snapshot() -> Status {
        expireCommandPeekIfNeeded()
        let target = manager.commandTargetOutput
        let preset = manager.activePresetIndex.flatMap { index in
            CommandPreset.allCases.first { $0.index == index }
        }
        // Off shows no tint, so no rule is shaping it.
        let activeApp = manager.isOn ? manager.activeApp.map {
            Status.App(bundleID: $0.bundleID, name: $0.name, rule: $0.rule)
        } : nil
        return Status(
            on: manager.isFiltering,
            displays: manager.displays.enumerated().map { index, display in
                Status.Display(key: display.persistenceKey, number: index + 1, name: display.name,
                               enabled: display.isEnabled, inverted: display.isInverted)
            },
            color: Status.Level(set: manager.colorPercent, target: SliderPercent.whole(target.intensity * 100)),
            whitepoint: Status.Level(set: manager.whitepointPercent,
                                     target: SliderPercent.whole(WhitepointScale.percent(target.whitepoint))),
            activePreset: preset,
            saturation: Status.Level(set: manager.saturationPercent, target: SliderPercent.whole(manager.effectiveTarget.saturation * 100)),
            saturationEnabled: manager.saturationEnabled,
            adaptive: manager.adaptiveEnabled,
            elevation: manager.commandElevation,
            statusLine: Self.statusLine(manager.adaptiveStatusText, activeApp: activeApp),
            limits: Status.Limits(
                color: Status.Band(min: manager.intensityBand.lowerBound * 100,
                                   max: manager.intensityBand.upperBound * 100),
                whitepoint: Status.Band(min: WhitepointScale.percent(manager.whitepointBand.lowerBound),
                                        max: WhitepointScale.percent(manager.whitepointBand.upperBound))
            ),
            appearance: services.appearance() ? .dark : .light,
            login: services.login(), version: services.version(), fading: manager.commandIsFading,
            pausedUntil: manager.pausedUntil,
            peeking: manager.isPeeking,
            locationSource: manager.manualLocation != nil ? .manual
                : manager.isLocationApproximate ? .timeZone : .auto,
            bedtime: manager.bedtime?.text,
            wake: manager.wakeTime?.text,
            learning: Status.Learning(
                enabled: manager.learningEnabled, anchors: manager.learnedAnchorCount,
                summary: manager.learningSummary,
                colorAnchors: manager.learnedAnchorCounts.color,
                whitepointAnchors: manager.learnedAnchorCounts.whitepoint,
                backups: manager.learningBackupCount),
            activeApp: activeApp,
            appRules: services.appRules(),
            colorKelvin: Status.Kelvin(set: kelvinScale.kelvin(manager.intensity),
                                       target: kelvinScale.kelvin(target.intensity))
        )
    }

    /// Auto's line with " · Photoshop: hold" after it while an app in front has a rule. In
    /// Manual, where Auto has nothing to say, the app's part stands alone.
    nonisolated static func statusLine(_ adaptive: String, activeApp: Status.App?) -> String {
        guard let activeApp else { return adaptive }
        let app = "\(activeApp.name): \(activeApp.rule.kind.rawValue)"
        return adaptive.isEmpty ? app : "\(adaptive) · \(app)"
    }

    /// Both channels are set in percent of their own scale, 0 to 100; see `WhitepointScale`.
    private func validate(_ value: Double, channel: CommandChannel) throws {
        guard value.isFinite, (0...100).contains(value) else {
            throw CommandError.invalidInput("\(channel.displayName) must be a finite percentage from 0 to 100.")
        }
    }

    private func validateSaturation(_ value: Double) throws {
        guard value.isFinite, (0...100).contains(value) else {
            throw CommandError.invalidInput("Saturation must be a finite percentage from 0 to 100.")
        }
    }

    /// Validate the requested pause before interrupting a drag or replacing an active pause.
    private func pause(for length: CommandPauseLength) throws -> Status {
        guard manager.isOn else { throw CommandError.invalidInput("Turn Redlight on before pausing.") }
        switch length {
        case .minutes(let minutes):
            guard CommandPauseLength.minuteRange.contains(minutes) else {
                throw CommandError.invalidInput("A pause must be a whole number of minutes from 1 to 1440 (24 hours).")
            }
            manager.interruptSliderInteraction()
            manager.pause(for: TimeInterval(minutes * 60))
        case .untilSunrise:
            guard manager.hasLocation else {
                throw CommandError.invalidInput("Redlight has no location to find sunrise from. Set one under Adaptive or with redlight location.")
            }
            guard let sunrise = manager.nextSunrise() else {
                throw CommandError.invalidInput("The sun does not rise here in the next 25 hours, so Redlight cannot pause until sunrise.")
            }
            manager.interruptSliderInteraction()
            guard manager.pause(until: sunrise) else {
                throw CommandError.invalidInput("The sunrise deadline passed before Redlight could pause. Try again.")
            }
        }
        return snapshot()
    }

    private func executePeek(_ action: CommandPeek) throws -> Status {
        expireCommandPeekIfNeeded()
        switch action {
        case .on:
            guard manager.isOn else {
                throw CommandError.invalidInput("Turn Redlight on before peeking.")
            }
            let pauseWasActive = commandPeek?.pauseWasActive ?? manager.isPaused
            manager.setPeeking(true, source: .command)
            armCommandPeekLease(pauseWasActive: pauseWasActive)
        case .renew:
            if let lease = commandPeek {
                armCommandPeekLease(pauseWasActive: lease.pauseWasActive)
            }
        case .off:
            endCommandPeek()
        case .tap:
            guard let lease = commandPeek else { return snapshot() }
            manager.interruptSliderInteraction()
            if lease.pauseWasActive {
                endCommandPeek()
                manager.resume()
            } else {
                manager.pause()
                endCommandPeek()
            }
        }
        return snapshot()
    }

    private func armCommandPeekLease(pauseWasActive: Bool) {
        commandPeek = PeekLease(pauseWasActive: pauseWasActive,
                                expiresAt: peekNow().advanced(by: .seconds(Self.commandPeekLease)))
        commandPeekLeaseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.commandPeekLease, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCommandPeek() }
        }
        RunLoop.main.add(timer, forMode: .common)
        commandPeekLeaseTimer = timer
    }

    private func expireCommandPeekIfNeeded() {
        guard let lease = commandPeek else { return }
        if lease.expiresAt <= peekNow() || !manager.isPeeking(source: .command) {
            endCommandPeek()
        }
    }

    private func endCommandPeek() {
        guard commandPeek != nil else { return }
        commandPeekLeaseTimer?.invalidate()
        commandPeekLeaseTimer = nil
        commandPeek = nil
        manager.setPeeking(false, source: .command)
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
