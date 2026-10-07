/// Discrete popover actions carry their actual payload into the shared command layer.
/// Slider tracking and band-marker previews remain direct model interactions. Opening
/// the save-target picker and cancelling it only change local presentation state; the
/// selected overwrite target dispatches `savePreset` below. About and Settings links
/// are the documented navigation exceptions, not display-control actions.
enum PopoverAction: Equatable {
    case master(CommandSwitch)
    case reset(CommandChannel)
    case preset(CommandPreset)
    case savePreset(CommandPreset)
    case adaptive(CommandSwitch)
    case display(CommandDisplaySelector, CommandSwitch)
    case invert(CommandDisplaySelector, CommandSwitch)
    case appearance(CommandAppearance)
    case login(Bool)
    case update
    case quit

    var command: RedlightCommand {
        switch self {
        case .master(let state): .master(state)
        case .reset(let channel): .reset(channel)
        case .preset(let preset): .preset(preset)
        case .savePreset(let preset): .savePreset(preset)
        case .adaptive(let state): .adaptive(state)
        case .display(let display, let state): .display(display, state)
        case .invert(let display, let state): .invert(display, state)
        case .appearance(let appearance): .appearance(appearance)
        case .login(let enabled): .login(enabled)
        case .update: .update
        case .quit: .quit
        }
    }

    var descriptor: PopoverActionDescriptor {
        switch self {
        case .master: .master
        case .reset: .reset
        case .preset: .preset
        case .savePreset: .savePreset
        case .adaptive: .adaptive
        case .display: .display
        case .invert: .invert
        case .appearance: .appearance
        case .login: .login
        case .update: .update
        case .quit: .quit
        }
    }
}

/// A finite catalogue avoids pretending that the associated display keys and numeric
/// payloads are enumerable. Parity tests use real representative actions for every kind.
enum PopoverActionDescriptor: CaseIterable {
    case master, reset, preset, savePreset, adaptive, display, invert, appearance, login, update, quit
}
