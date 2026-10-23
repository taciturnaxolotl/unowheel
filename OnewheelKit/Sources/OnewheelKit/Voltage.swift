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
        let used: Int
        let regen: Int
        let watts: Double
    }

    private var points: [Point] = []
    public private(set) var volts: Double?

    /// Window long enough for the counters to move many units.
    static let window: TimeInterval = 30
    static let minimumWatts = 60.0
    static let ampHoursPerUnit = 0.00018

    public init() {}

    /// Riding flips between drawing power and regen every few seconds, so
    /// both counters are summed: energy moved either way over charge moved
    /// either way is still volts.
    public mutating func record(_ t: Telemetry, at date: Date = .now) {
        guard t.usesModernTelemetry, let watts = t.powerWatts,
              let used = t.tripAmpHoursRaw, let regen = t.tripRegenAmpHoursRaw else { return }
        points.append(Point(date: date, used: used, regen: regen, watts: abs(watts)))
        points.removeAll { date.timeIntervalSince($0.date) > Self.window * 2 }

        guard let first = points.first, date.timeIntervalSince(first.date) >= Self.window else { return }
        // A 16-bit counter wrapped or reset; start over.
        guard used >= first.used, regen >= first.regen else {
            points = [points.last!]
            return
        }
        let hours = date.timeIntervalSince(first.date) / 3600
        let wattHours = zip(points, points.dropFirst()).reduce(0.0) { total, pair in
            total + (pair.0.watts + pair.1.watts) / 2 * pair.1.date.timeIntervalSince(pair.0.date) / 3600
        }
        let ampHours = Double(used - first.used + regen - first.regen) * Self.ampHoursPerUnit
        guard wattHours / hours >= Self.minimumWatts, ampHours > 0 else { return }
        let estimate = wattHours / ampHours
        // Only accept what this pack could read, 3.0 to 4.25 V per cell.
        let cells = Double(t.model.cellCount)
        guard (cells * 3.0...cells * 4.25).contains(estimate) else { return }
        volts = volts.map { $0 * 0.7 + estimate * 0.3 } ?? estimate
    }
}
