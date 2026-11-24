/// Discrete popover actions carry their actual payload into the shared command layer.
/// Slider tracking and range-limit previews remain direct model interactions. Opening
/// the save-target picker and cancelling it only change local presentation state; the
/// selected overwrite target dispatches `savePreset` below. About and Settings links
/// are the documented navigation exceptions, not display-control actions.
enum PopoverAction: Equatable {
    case master(CommandSwitch)
    case pause(CommandSwitch)
    case pauseFor(CommandPauseLength)
    case reset(CommandChannel)
    /// Auto's range for one channel, in percent. The range card's Reset sends the defaults:
    /// unlike `reset`, it leaves the value and any Auto adjustment alone.
    case limits(CommandChannel, min: Double, max: Double)
    case preset(CommandPreset)
    case savePreset(CommandPreset)
    case adaptive(CommandSwitch)
    case display(CommandDisplaySelector, CommandSwitch)
    case invert(CommandDisplaySelector, CommandSwitch)
    case appearance(CommandAppearance)
    case login(Bool)
    case location(CommandLocation)
    case bedtime(CommandBedtime)
    case apps(CommandApps)
    case update
    case quit

    var command: RedlightCommand {
        switch self {
        case .master(let state): .master(state)
        case .pause(let state): .pause(state)
        case .pauseFor(let length): .pauseFor(length)
        case .reset(let channel): .reset(channel)
        case .limits(let channel, let min, let max): .limits(channel, min: min, max: max)
        case .preset(let preset): .preset(preset)
        case .savePreset(let preset): .savePreset(preset)
        case .adaptive(let state): .adaptive(state)
        case .display(let display, let state): .display(display, state)
        case .invert(let display, let state): .invert(display, state)
        case .appearance(let appearance): .appearance(appearance)
        case .login(let enabled): .login(enabled)
        case .location(let location): .location(location)
        case .bedtime(let bedtime): .bedtime(bedtime)
        case .apps(let change): .apps(change)
        case .update: .update
        case .quit: .quit
        }
    }

    var descriptor: PopoverActionDescriptor {
        switch self {
        case .master: .master
        case .pause: .pause
        case .pauseFor: .pauseFor
        case .reset: .reset
        case .limits: .limits
        case .preset: .preset
        case .savePreset: .savePreset
        case .adaptive: .adaptive
        case .display: .display
        case .invert: .invert
        case .appearance: .appearance
        case .login: .login
        case .location: .location
        case .bedtime: .bedtime
        case .apps: .apps
        case .update: .update
        case .quit: .quit
        }
    }
}

/// A finite catalogue avoids pretending that the associated display keys and numeric
/// payloads are enumerable. Parity tests use real representative actions for every kind.
enum PopoverActionDescriptor: CaseIterable {
    case master, pause, pauseFor, reset, limits, preset, savePreset, adaptive, display, invert, appearance, login,
         location, bedtime, apps, update, quit
}
