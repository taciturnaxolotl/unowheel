import Foundation

public struct RideMode: Hashable, Sendable, Identifiable {
    public let name: String
    public let value: UInt16
    public let summary: String
    /// Where this mode caps speed, in mph.
    public let topSpeedMPH: Double
    public var id: UInt16 { value }

    public init(name: String, value: UInt16, summary: String = "", topSpeedMPH: Double = 20) {
        self.name = name
        self.value = value
        self.summary = summary
        self.topSpeedMPH = topSpeedMPH
    }
}

/// Board family, derived from the hardware revision the same way the official
/// app does (`n3.a.t` in the decompiled Android build).
public enum BoardModel: String, Sendable {
    case v1, plus, xr, pint, gt, pintX, gts, xrc, unknown

    public init(hardwareRevision hw: Int) {
        switch hw {
        case ..<3000: self = .v1
        case 3000..<4000: self = .plus
        case 4000..<5000: self = .xr
        case 5000..<6000: self = .pint
        case 6000..<7000: self = .gt
        case 7000..<8000: self = .pintX
        case 8000..<9000: self = .gts
        case 9000..<10000: self = .xrc
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .v1: "Onewheel V1"
        case .plus: "Onewheel+"
        case .xr: "Onewheel+ XR"
        case .pint: "Pint"
        case .gt: "GT"
        case .pintX: "Pint X"
        case .gts: "GT-S"
        case .xrc: "XR Classic"
        case .unknown: "Onewheel"
        }
    }

    /// Tire circumference in millimetres (OWCE: 10.5" for Pints, 11.5" otherwise).
    public var wheelCircumferenceMM: Double {
        switch self {
        case .pint, .pintX: 837.86
        default: 917.66
        }
    }

    /// Series cells in the pack (OWCE: XR and Pint report a 16th slot that isn't a real cell).
    public var cellCount: Int {
        switch self {
        case .v1, .plus: 16
        case .gt, .gts: 18
        default: 15
        }
    }

    /// Future Motion's published top speed in mph. Pushback starts near it.
    public var topSpeedMPH: Double {
        switch self {
        case .v1: 15
        case .pint: 16
        case .pintX: 18
        case .plus, .xr, .xrc: 19
        case .gt: 20
        case .gts: 25
        case .unknown: 20
        }
    }

    public var topSpeedKPH: Double { topSpeedMPH * 1.609344 }

    /// Top speed in the given ride mode, falling back to the board's top speed.
    /// Per-mode limits are from TrailWheel's table of Future Motion presets.
    public func topSpeedMPH(mode: UInt16?) -> Double {
        rideModes.first { $0.value == mode }?.topSpeedMPH ?? topSpeedMPH
    }

    /// Amps per raw unit on `312`.
    public var currentScale: Double {
        switch self {
        case .v1: 0.0009
        case .plus: 0.0018
        default: 0.002
        }
    }

    /// Ride modes as written to `302`. Names and values are the official
    /// app's table (`o3.a.T` in the Android build); summaries are ours.
    public var rideModes: [RideMode] {
        switch self {
        case .pint, .pintX:
            let x = self == .pintX ? " X" : ""
            let top = topSpeedMPH
            return [
                RideMode(name: "Redwood", value: 5, summary: "Gentle and forgiving, lowest top speed. Good for learning.", topSpeedMPH: 12),
                RideMode(name: "Pacific\(x)", value: 6, summary: "The everyday mode: quicker and more responsive.", topSpeedMPH: top),
                RideMode(name: "Elevated\(x)", value: 7, summary: "Pacific with the nose tilted up, for grass and rough ground.", topSpeedMPH: top),
                RideMode(name: "Skyline\(x)", value: 8, summary: "The most aggressive and fastest mode.", topSpeedMPH: top),
            ]
        case .gt, .gts:
            let top = topSpeedMPH
            return [
                RideMode(name: "Bay", value: 3, summary: "Softest and slowest. Good for learning.", topSpeedMPH: 12),
                RideMode(name: "Roam", value: 4, summary: "Relaxed cruising.", topSpeedMPH: 18),
                RideMode(name: "Flow", value: 5, summary: "Balanced, the all-rounder.", topSpeedMPH: top),
                RideMode(name: "Highline", value: 6, summary: "Firm and quick.", topSpeedMPH: top),
                RideMode(name: "Elevated", value: 7, summary: "Nose tilted up, for trails.", topSpeedMPH: top),
                RideMode(name: "Apex", value: 8, summary: "Most aggressive, highest top speed.", topSpeedMPH: top),
            ]
        case .xrc:
            return [
                RideMode(name: "Sequoia", value: 3, summary: "Gentle and slow.", topSpeedMPH: 12),
                RideMode(name: "Cruz", value: 4, summary: "Relaxed cruising.", topSpeedMPH: 15),
                RideMode(name: "Mission", value: 5, summary: "Balanced, the all-rounder.", topSpeedMPH: 19),
                RideMode(name: "Session", value: 6, summary: "Loose and playful.", topSpeedMPH: 19),
                RideMode(name: "Elevated", value: 7, summary: "Nose tilted up, for trails.", topSpeedMPH: 19),
                RideMode(name: "Delirium", value: 8, summary: "Most aggressive, highest top speed.", topSpeedMPH: 19),
            ]
        case .plus, .xr:
            return [
                RideMode(name: "Sequoia", value: 4, summary: "Gentle and slow.", topSpeedMPH: 12),
                RideMode(name: "Cruz", value: 5, summary: "Relaxed cruising.", topSpeedMPH: 15),
                RideMode(name: "Mission", value: 6, summary: "Balanced, the all-rounder.", topSpeedMPH: 19),
                RideMode(name: "Elevated", value: 7, summary: "Nose tilted up, for trails.", topSpeedMPH: 19),
                RideMode(name: "Delirium", value: 8, summary: "Most aggressive, highest top speed.", topSpeedMPH: 19),
                RideMode(name: "Custom", value: 9, summary: "Your own shaping, set in the official app.", topSpeedMPH: 19),
            ]
        case .v1:
            return [
                RideMode(name: "Classic", value: 1, summary: "The original feel.", topSpeedMPH: 12),
                RideMode(name: "Extreme", value: 2, summary: "Faster and stiffer.", topSpeedMPH: 15),
                RideMode(name: "Elevated", value: 3, summary: "Nose tilted up.", topSpeedMPH: 15),
            ]
        case .unknown:
            return []
        }
    }

    public func rideModeName(_ value: UInt16) -> String {
        rideModes.first { $0.value == value }?.name ?? "Mode \(value)"
    }
}
