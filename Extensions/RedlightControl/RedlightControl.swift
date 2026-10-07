import AppIntents
import SwiftUI
import WidgetKit

@main struct RedlightControlBundle: WidgetBundle {
    var body: some Widget { RedlightControl() }
}

struct RedlightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: RedlightControlPreferences.kind, provider: RedlightValueProvider()) { value in
            ControlWidgetToggle(isOn: value, action: SetRedlightIntent()) {
                Text("Redlight")
                    .foregroundStyle(.primary)
            } valueLabel: { on in
                Label(on ? "On" : "Off", systemImage: "sun.max.fill")
                    .foregroundStyle(on ? Color.red : Color.primary)
            }
            .tint(.clear)
        }
        .displayName("Redlight")
        .description("Turn Redlight's display filters on or off.")
    }
}

struct RedlightValueProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { RedlightControlPreferences.currentValue() }
}
