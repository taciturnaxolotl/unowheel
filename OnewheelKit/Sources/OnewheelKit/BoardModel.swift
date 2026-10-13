import Foundation

public struct RideMode: Hashable, Sendable, Identifiable {
    public let name: String
    public let value: UInt16
    public let summary: String
    public var id: UInt16 { value }

    public init(name: String, value: UInt16, summary: String = "") {
        self.name = name
        self.value = value
        self.summary = summary
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
            return [
                RideMode(name: "Redwood", value: 5, summary: "Gentle and forgiving, lowest top speed. Good for learning."),
                RideMode(name: "Pacific\(x)", value: 6, summary: "The everyday mode: quicker and more responsive."),
                RideMode(name: "Elevated\(x)", value: 7, summary: "Pacific with the nose tilted up, for grass and rough ground."),
                RideMode(name: "Skyline\(x)", value: 8, summary: "The most aggressive and fastest mode."),
            ]
        case .gt, .gts:
            return [
                RideMode(name: "Bay", value: 3, summary: "Softest and slowest. Good for learning."),
                RideMode(name: "Roam", value: 4, summary: "Relaxed cruising."),
                RideMode(name: "Flow", value: 5, summary: "Balanced, the all-rounder."),
                RideMode(name: "Highline", value: 6, summary: "Firm and quick."),
                RideMode(name: "Elevated", value: 7, summary: "Nose tilted up, for trails."),
                RideMode(name: "Apex", value: 8, summary: "Most aggressive, highest top speed."),
            ]
        case .xrc:
            return [
                RideMode(name: "Sequoia", value: 3, summary: "Gentle and slow."),
                RideMode(name: "Cruz", value: 4, summary: "Relaxed cruising."),
                RideMode(name: "Mission", value: 5, summary: "Balanced, the all-rounder."),
                RideMode(name: "Session", value: 6, summary: "Loose and playful."),
                RideMode(name: "Elevated", value: 7, summary: "Nose tilted up, for trails."),
                RideMode(name: "Delirium", value: 8, summary: "Most aggressive, highest top speed."),
            ]
        case .plus, .xr:
            return [
                RideMode(name: "Sequoia", value: 4, summary: "Gentle and slow."),
                RideMode(name: "Cruz", value: 5, summary: "Relaxed cruising."),
                RideMode(name: "Mission", value: 6, summary: "Balanced, the all-rounder."),
                RideMode(name: "Elevated", value: 7, summary: "Nose tilted up, for trails."),
                RideMode(name: "Delirium", value: 8, summary: "Most aggressive, highest top speed."),
                RideMode(name: "Custom", value: 9, summary: "Your own shaping, set in the official app."),
            ]
        case .v1:
            return [
                RideMode(name: "Classic", value: 1, summary: "The original feel."),
                RideMode(name: "Extreme", value: 2, summary: "Faster and stiffer."),
                RideMode(name: "Elevated", value: 3, summary: "Nose tilted up."),
            ]
        case .unknown:
            return []
        }
    }

    public func rideModeName(_ value: UInt16) -> String {
        rideModes.first { $0.value == value }?.name ?? "Mode \(value)"
    }
}
