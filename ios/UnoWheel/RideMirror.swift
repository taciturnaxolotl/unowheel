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
    /// Alerts already shown during this activity, so each fires once.
    private var alertsFired: Set<String> = []
    private var lastPushbackAlert = Date.distantPast
    private var rideStartedAt: Date?
    private var rideTrip = ""
    private var reportedDisabled = false
    private var lastError: String?
    var log: (String) -> Void = { _ in }

    init() {
        // A crash or force-quit can leave an activity behind; nothing will
        // ever update it again, so clear it out on launch.
        Task {
            for leftover in Activity<RideAttributes>.activities {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private var useMetric: Bool {
        UserDefaults.standard.object(forKey: "useMetric") as? Bool ?? (Locale.current.measurementSystem == .metric)
    }

    func sync(name: String?, telemetry t: Telemetry, unlocked: Bool,
              rangeKm: Double?, rangeLearned: Bool, startedAt: Date?, charge: ChargeSession?, ride: Ride?) {
        guard let name else {
            finish()
            return
        }
        let range = rangeKm.map(formatRange)
        let toppingOff = ChargeSession.isToppingOff(percent: t.batteryPercent, watts: t.chargingWatts)
        let fullAt = toppingOff ? nil : charge?.secondsToFull(packWattHours: t.model.packWattHours).map { Self.minute(.now + $0) }
        if unlocked, !t.isCharging, let speed = currentSpeed(t), speed > 0 {
            topSpeed = max(topSpeed, speed)
            if rideStartedAt == nil { rideStartedAt = .now }
            rideTrip = formattedTrip(t)
        }
        updateSnapshot(name: name, telemetry: t, connected: unlocked, range: range, fullAt: fullAt, toppingOff: toppingOff)
        if unlocked {
            updateActivity(name: name, telemetry: t, range: range, rangeLearned: rangeLearned,
                           startedAt: startedAt ?? .now, fullAt: fullAt, toppingOff: toppingOff, ride: ride)
        } else {
            endActivity()
        }
    }

    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    private func currentSpeed(_ t: Telemetry) -> Int? {
        (useMetric ? t.speedKPH : t.speedMPH).map { Int($0.rounded()) }
    }

    private func formattedTrip(_ t: Telemetry) -> String {
        (useMetric ? t.tripKilometres : t.tripMiles).map { String(format: "%.1f %@", $0, useMetric ? "km" : "mi") } ?? ""
    }

    /// Saves the ride that just ended for the widgets, if there was one.
    private func closeRide() {
        defer {
            topSpeed = 0
            rideStartedAt = nil
            rideTrip = ""
        }
        guard topSpeed > 0, let started = rideStartedAt, var snapshot = lastSnapshot ?? BoardSnapshot.load() else { return }
        snapshot.lastRide = RideSummary(topSpeed: topSpeed, unit: useMetric ? "km/h" : "mph", trip: rideTrip,
                                        minutes: max(1, Int(Date.now.timeIntervalSince(started) / 60)), endedAt: .now)
        write(snapshot, force: true)
    }

    private func formatRange(_ km: Double) -> String {
        let value = useMetric ? km : km * 0.621371
        let unit = useMetric ? "km" : "mi"
        return value < 10 ? String(format: "%.1f %@", value, unit) : String(format: "%.0f %@", value, unit)
    }

    func finish() {
        closeRide()
        if var snapshot = lastSnapshot, snapshot.connected {
            snapshot.connected = false
            snapshot.updatedAt = .now
            write(snapshot, force: true)
        }
        endActivity()
    }

    private func updateSnapshot(name: String, telemetry t: Telemetry, connected: Bool, range: String?, fullAt: Date?, toppingOff: Bool) {
        let previous = lastSnapshot ?? BoardSnapshot.load()
        var snapshot = BoardSnapshot(
            name: name,
            model: t.model.displayName,
            batteryPercent: t.batteryPercent ?? previous?.batteryPercent,
            voltage: t.batteryVoltage ?? previous?.voltage,
            rideMode: t.rideMode.map(t.model.rideModeName) ?? previous?.rideMode,
            lifetime: t.lifetimeMiles.map { useMetric ? "\(Int(Double($0) * 1.60934)) km" : "\($0) mi" } ?? previous?.lifetime,
            range: range ?? previous?.range,
            charging: t.status.map(\.charging) ?? previous?.charging,
            chargeWatts: t.chargingWatts.map { Int(($0 / 5).rounded()) * 5 },
            fullAt: t.isCharging ? fullAt : nil,
            toppingOff: t.isCharging && toppingOff,
            lastRide: previous?.lastRide,
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

    private func updateActivity(name: String, telemetry t: Telemetry, range: String?, rangeLearned: Bool,
                                startedAt: Date, fullAt: Date?, toppingOff: Bool, ride: Ride?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            if !reportedDisabled {
                reportedDisabled = true
                log("Live Activities are off in Settings")
            }
            return
        }
        let metric = useMetric
        let speed = currentSpeed(t) ?? 0
        let rideState: RideState = t.status?.charging == true ? .charging
            : speed < 1 ? .stopped : t.isRegenerating ? .braking : .riding
        let state = RideAttributes.ContentState(
            speed: speed,
            unit: metric ? "km/h" : "mph",
            batteryPercent: t.batteryPercent ?? 0,
            rideMode: t.rideMode.map(t.model.rideModeName) ?? "",
            trip: formattedTrip(t),
            range: range ?? "",
            rangeLearned: rangeLearned,
            state: rideState,
            topSpeed: topSpeed,
            speedMax: Int((t.model.topSpeedMPH(mode: t.rideMode) * (metric ? 1.609344 : 1)).rounded()),
            chargeWatts: Int(((t.chargingWatts ?? 0) / 5).rounded()) * 5,
            fullAt: t.isCharging ? fullAt : nil,
            toppingOff: t.isCharging && toppingOff,
            lightsOn: t.lightsOn ?? false,
            rideDistance: ride.map { formatDistance($0.distanceKm, metric: metric) } ?? "",
            rideMinutes: ride.map { Int($0.movingTime / 60) } ?? 0
        )
        guard state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: .now.addingTimeInterval(60))

        if let activity, activity.activityState == .active {
            let id = activity.id
            let alert = alert(for: t, speed: speed, max: state.speedMax)
            Task {
                if let alert {
                    await Self.find(id)?.update(content, alertConfiguration: alert)
                } else {
                    await Self.find(id)?.update(content)
                }
            }
            return
        }
        // iOS only lets an app start a Live Activity from the foreground, so a
        // board that auto-connects in the background gets one next time you
        // open UnoWheel.
        do {
            activity = try Activity.request(attributes: RideAttributes(boardName: name, startedAt: startedAt), content: content)
            log("Live Activity started")
        } catch {
            // Forget the state so the next tick tries again.
            lastState = nil
            let message = error.localizedDescription
            if message != lastError {
                lastError = message
                log("Live Activity failed: \(message)")
            }
        }
    }

    /// One-off alerts that light up the lock screen. Each fires once per
    /// activity, except pushback, which can repeat after a minute.
    private func alert(for t: Telemetry, speed: Int, max: Int) -> AlertConfiguration? {
        func once(_ key: String, _ title: String, _ body: String) -> AlertConfiguration? {
            guard !alertsFired.contains(key) else { return nil }
            alertsFired.insert(key)
            return AlertConfiguration(title: LocalizedStringResource(stringLiteral: title),
                                      body: LocalizedStringResource(stringLiteral: body), sound: .default)
        }
        if let error = t.status?.error {
            return once("error\(error.code)", error.title, error.advice)
        }
        let battery = t.batteryPercent ?? 100
        if t.isCharging {
            if battery >= 90 { return once("charged", "Charged to 90%", "Unplug now, or leave it to top off.") }
            return nil
        }
        if battery <= 10 { return once("battery10", "Battery 10%", "Head home soon.") }
        if battery <= 20 { return once("battery20", "Battery 20%", "Range is getting short.") }
        if max > 0, Double(speed) >= Double(max) * 0.9, Date.now.timeIntervalSince(lastPushbackAlert) > 60 {
            lastPushbackAlert = .now
            return AlertConfiguration(title: "Near top speed", body: "Pushback is close.", sound: .default)
        }
        return nil
    }

    private func endActivity() {
        alertsFired = []
        guard let activity else { return }
        self.activity = nil
        let id = activity.id
        let final = lastState.map { ActivityContent(state: $0, staleDate: nil) }
        lastState = nil
        Task { await Self.find(id)?.end(final, dismissalPolicy: .after(.now.addingTimeInterval(120))) }
    }

    private nonisolated static func find(_ id: String) -> Activity<RideAttributes>? {
        Activity<RideAttributes>.activities.first { $0.id == id }
    }
}
