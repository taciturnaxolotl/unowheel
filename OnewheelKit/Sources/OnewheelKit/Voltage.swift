import Foundation

/// Works out pack voltage on firmware that no longer reports it.
///
/// The board still reports power (`304`, watts) and counts charge in and
/// out (`313` and `314`, 0.18 mAh per unit; charging counts as regen).
/// Watts over amps is volts. Measured while charging a 5208 Pint, this gave
/// 59.6 V at 57% rising to 63.5 V when the charger switched to constant
/// voltage, which is 4.2 V per cell on a 15s pack.
public struct PackVoltageEstimator: Sendable {
    struct Point {
        let date: Date
        let amphourUnits: Int
        let watts: Double
        let discharging: Bool
    }

    private var points: [Point] = []
    public private(set) var volts: Double?

    /// Window long enough for the counters to move many units.
    static let window: TimeInterval = 30
    static let minimumWatts = 60.0

    public init() {}

    public mutating func record(_ t: Telemetry, at date: Date = .now) {
        guard t.usesModernTelemetry, let watts = t.powerWatts,
              let used = t.tripAmpHoursRaw, let regen = t.tripRegenAmpHoursRaw else { return }
        // Discharging moves 313, charging and regen move 314. Use whichever
        // matches the direction of power flow.
        let units = watts >= 0 ? used : regen
        if let last = points.last, last.discharging != (watts >= 0) { points.removeAll() }
        points.append(Point(date: date, amphourUnits: units, watts: abs(watts), discharging: watts >= 0))
        points.removeAll { date.timeIntervalSince($0.date) > Self.window * 2 }

        guard let first = points.first, date.timeIntervalSince(first.date) >= Self.window else { return }
        // A 16-bit counter wrapped or reset; start over.
        guard units >= first.amphourUnits else {
            points = [points.last!]
            return
        }
        let window = points
        let averageWatts = window.map(\.watts).reduce(0, +) / Double(window.count)
        let amphours = Double(units - first.amphourUnits) * 0.00018
        let hours = date.timeIntervalSince(first.date) / 3600
        guard averageWatts >= Self.minimumWatts, amphours > 0, hours > 0 else { return }
        let estimate = averageWatts / (amphours / hours)
        // Only accept values a Onewheel pack could have.
        guard (40...80).contains(estimate) else { return }
        volts = volts.map { $0 * 0.7 + estimate * 0.3 } ?? estimate
    }
}
