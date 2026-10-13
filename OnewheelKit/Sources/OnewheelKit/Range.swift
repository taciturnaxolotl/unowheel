import Foundation

extension BoardModel {
    /// Usable pack energy in watt-hours, from the official app's range model
    /// (`n3.a.i` in the Android build).
    public var packWattHours: Double {
        switch self {
        case .pint: 139
        case .pintX, .xr: 330
        case .gt: 468
        case .gts: 393.3
        case .xrc: 354.6
        default: 132
        }
    }

    /// Future Motion's rated range on a full charge, in kilometres. Used as
    /// the estimate before we've learned anything, and as a ceiling after.
    public var ratedRangeKm: Double {
        switch self {
        case .pint: 13
        case .pintX, .xr: 25
        case .gt: 50
        case .gts, .xrc: 38
        default: 11
        }
    }
}

/// Learns how many watt-hours per kilometre you use, and turns the battery
/// percentage into a distance.
///
/// Energy comes from power on newer firmware (`304`) or current times voltage
/// on older boards. Only samples while moving count. Regen is credited at a
/// quarter of its value, as the official app does, since the pack doesn't
/// recover it all.
public struct RangeEstimator: Codable, Equatable, Sendable {
    /// Long-running average, carried between rides.
    public private(set) var whPerKm: Double?
    /// Distance the long-running average is based on.
    public private(set) var learnedKm: Double = 0

    private var rideWh: Double = 0
    private var rideKm: Double = 0

    /// Distance needed before learned efficiency replaces the rated guess.
    public static let minimumKm = 0.5
    static let minimumSpeedKPH = 2.0

    public init() {}

    /// Feeds one telemetry sample covering `seconds` of riding.
    public mutating func record(_ t: Telemetry, seconds: TimeInterval) {
        guard seconds > 0, seconds < 10, let speed = t.speedKPH, speed >= Self.minimumSpeedKPH,
              let watts = Self.watts(t) else { return }
        let hours = seconds / 3600
        rideKm += speed * hours
        rideWh += (watts < 0 ? watts * 0.25 : watts) * hours
        if rideKm >= 0.1 { fold() }
    }

    /// Merges the current ride's numbers into the long-running average,
    /// weighting by distance so one short hill can't swing it.
    mutating func fold() {
        guard rideKm > 0 else { return }
        let rideRate = max(rideWh, 0) / rideKm
        let total = learnedKm + rideKm
        whPerKm = ((whPerKm ?? rideRate) * learnedKm + rideRate * rideKm) / total
        // Cap memory at ~50 km so the estimate keeps adapting to new terrain.
        learnedKm = min(total, 50)
        rideWh = 0
        rideKm = 0
    }

    public func rangeKm(for t: Telemetry) -> Double? {
        guard let percent = t.batteryPercent, percent > 0 else { return nil }
        let model = t.model
        let rated = model.ratedRangeKm * Double(percent) / 100
        guard let whPerKm, whPerKm > 0, learnedKm >= Self.minimumKm else { return rated }
        let remainingWh = model.packWattHours * Double(percent) / 100
        return min(remainingWh / whPerKm, model.ratedRangeKm * 1.25)
    }

    public var isLearned: Bool { (whPerKm ?? 0) > 0 && learnedKm >= Self.minimumKm }

    static func watts(_ t: Telemetry) -> Double? {
        if t.usesModernTelemetry { return t.powerWatts }
        guard let amps = t.currentAmps, let volts = t.batteryVoltage else { return nil }
        return amps * volts
    }
}
