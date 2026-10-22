import ActivityKit
import AppIntents
import Foundation

/// Sets the board's lights from the Live Activity. Used with
/// `Toggle(isOn:intent:)`, so iOS flips the button the moment it's tapped
/// and fills in `value`. Live Activity intents run in the app's process,
/// where the app installs the handler at launch.
struct ToggleLightsIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Lights"
    static let isDiscoverable = false

    @Parameter(title: "On") var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        await Self.showOptimistically(value)
        await LightsBridge.set(value)
        return .result()
    }

    /// Puts the new state on the lock screen straight away, before the
    /// board has answered; the app corrects it if the write fails.
    private static func showOptimistically(_ on: Bool) async {
        for activity in Activity<RideAttributes>.activities {
            var state = activity.content.state
            guard state.lightsOn != on else { continue }
            state.lightsOn = on
            await activity.update(ActivityContent(state: state, staleDate: activity.content.staleDate))
        }
    }
}

@MainActor
enum LightsBridge {
    static var handler: ((Bool) async -> Void)?

    static func set(_ on: Bool) async { await handler?(on) }
}
