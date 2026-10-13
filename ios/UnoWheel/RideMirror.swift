import ActivityKit
import Foundation
import OnewheelKit
import WidgetKit

/// Pushes board state out of the app: a snapshot for the home and lock screen
/// widgets, and a Live Activity while a board is unlocked.
@MainActor
final class RideMirror {
    private var activity: Activity<RideAttributes>?
    private var lastSnapshot: BoardSnapshot?
    private var lastState: RideAttributes.ContentState?
    private var lastWidgetReload = Date.distantPast
    private var topSpeed = 0

    private var useMetric: Bool {
        UserDefaults.standard.object(forKey: "useMetric") as? Bool ?? (Locale.current.measurementSystem == .metric)
    }

    func sync(name: String?, telemetry t: Telemetry, unlocked: Bool,
              rangeKm: Double?, rangeLearned: Bool, startedAt: Date?) {
        guard let name else {
            finish()
            return
        }
        let range = rangeKm.map(formatRange)
        updateSnapshot(name: name, telemetry: t, connected: unlocked, range: range)
        if unlocked {
            updateActivity(name: name, telemetry: t, range: range, rangeLearned: rangeLearned,
                           startedAt: startedAt ?? .now)
        } else {
            endActivity()
        }
    }

    private func formatRange(_ km: Double) -> String {
        let value = useMetric ? km : km * 0.621371
        let unit = useMetric ? "km" : "mi"
        return value < 10 ? String(format: "%.1f %@", value, unit) : String(format: "%.0f %@", value, unit)
    }

    func finish() {
        if var snapshot = lastSnapshot, snapshot.connected {
            snapshot.connected = false
            snapshot.updatedAt = .now
            write(snapshot, force: true)
        }
        endActivity()
    }

    private func updateSnapshot(name: String, telemetry t: Telemetry, connected: Bool, range: String?) {
        let previous = lastSnapshot ?? BoardSnapshot.load()
        var snapshot = BoardSnapshot(
            name: name,
            model: t.model.displayName,
            batteryPercent: t.batteryPercent ?? previous?.batteryPercent,
            voltage: t.batteryVoltage ?? previous?.voltage,
            rideMode: t.rideMode.map(t.model.rideModeName) ?? previous?.rideMode,
            lifetime: t.lifetimeMiles.map { useMetric ? "\(Int(Double($0) * 1.60934)) km" : "\($0) mi" } ?? previous?.lifetime,
            range: range ?? previous?.range,
            connected: connected,
            updatedAt: previous?.updatedAt ?? .now
        )
        // Only values that matter on a widget decide whether we write.
        var comparable = snapshot
        comparable.voltage = previous?.voltage
        comparable.updatedAt = previous?.updatedAt ?? .now
        guard comparable != previous || Date.now.timeIntervalSince(lastWidgetReload) > 300 else { return }
        snapshot.updatedAt = .now
        write(snapshot, force: previous?.connected != connected)
    }

    private func write(_ snapshot: BoardSnapshot, force: Bool) {
        snapshot.save()
        lastSnapshot = snapshot
        guard force || Date.now.timeIntervalSince(lastWidgetReload) > 60 else { return }
        lastWidgetReload = .now
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func updateActivity(name: String, telemetry t: Telemetry, range: String?, rangeLearned: Bool, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let metric = useMetric
        let speed = Int((metric ? t.speedKPH : t.speedMPH)?.rounded() ?? 0)
        topSpeed = max(topSpeed, speed)
        let rideState: RideState = speed < 1 ? .stopped : t.isRegenerating ? .braking : .riding
        let state = RideAttributes.ContentState(
            speed: speed,
            unit: metric ? "km/h" : "mph",
            batteryPercent: t.batteryPercent ?? 0,
            rideMode: t.rideMode.map(t.model.rideModeName) ?? "",
            trip: (metric ? t.tripKilometres : t.tripMiles).map { String(format: "%.1f %@", $0, metric ? "km" : "mi") } ?? "",
            range: range ?? "",
            rangeLearned: rangeLearned,
            state: rideState,
            topSpeed: topSpeed
        )
        guard state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(60))

        if let activity, activity.activityState == .active {
            let id = activity.id
            Task { await Self.find(id)?.update(content) }
            return
        }
        // iOS only lets an app start a Live Activity from the foreground, so a
        // board that auto-connects in the background gets one next time you
        // open UnoWheel.
        activity = try? Activity.request(attributes: RideAttributes(boardName: name, startedAt: startedAt), content: content)
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        topSpeed = 0
        let id = activity.id
        let final = lastState.map { ActivityContent(state: $0, staleDate: nil) }
        lastState = nil
        Task { await Self.find(id)?.end(final, dismissalPolicy: .after(.now.addingTimeInterval(120))) }
    }

    private nonisolated static func find(_ id: String) -> Activity<RideAttributes>? {
        Activity<RideAttributes>.activities.first { $0.id == id }
    }
}
