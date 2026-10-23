import Foundation

/// Live board state, decoded from characteristic values. Scaling follows
/// OWCE's `OWBoard.SetValue`, adjusted for the board's big-endian wire order.
public struct Telemetry: Equatable, Sendable, Codable {
    public var firmwareRevision: Int?
    public var hardwareRevision: Int?
    public var serialNumber: Int?
    public var rideMode: UInt16?
    public var batteryPercent: Int?
    public var batteryVoltage: Double?
    public var batteryTemperatureC: Int?
    public var batteryCells: [Int: Double] = [:]
    public var motorTemperatureC: Int?
    public var controllerTemperatureC: Int?
    public var rpm: Int?
    public var pitch: Double?
    public var roll: Double?
    public var yaw: Double?
    public var currentAmps: Double?
    /// Signed motor power in watts; negative while regenerating. Only newer
    /// firmware reports it (on `304`), and those boards stop reporting current.
    public var powerWatts: Double?
    public var tripAmpHours: Double?
    public var tripRegenAmpHours: Double?
    /// Raw `313` and `314` counters, 0.18 mAh per unit.
    public var tripAmpHoursRaw: Int?
    public var tripRegenAmpHoursRaw: Int?
    public var tripRevolutions: Int?
    public var lifetimeMiles: Int?
    public var lifetimeAmpHours: Int?
    public var statusError: UInt16?
    public var lightsOn: Bool?
    public var battery = BatteryDiagnostics()

    public var status: BoardStatus? { statusError.map(BoardStatus.init(raw:)) }

    public init() {}

    public var model: BoardModel {
        hardwareRevision.map(BoardModel.init(hardwareRevision:)) ?? .unknown
    }

    public var speedKPH: Double? {
        rpm.map { Double($0) * model.wheelCircumferenceMM * 60 / 1_000_000 }
    }

    public var speedMPH: Double? { speedKPH.map { $0 * 0.621371 } }

    public var tripKilometres: Double? {
        tripRevolutions.map { Double($0) * model.wheelCircumferenceMM / 1_000_000 }
    }

    public var tripMiles: Double? { tripKilometres.map { $0 * 0.621371 } }

    public var isCharging: Bool { status?.charging == true }

    /// While charging, the board reports charge power as negative motor
    /// power on `304` (about -170 W on a Pint), so it isn't regen.
    public var isRegenerating: Bool {
        guard !isCharging else { return false }
        return usesModernTelemetry ? (powerWatts ?? 0) < 0 : (currentAmps ?? 0) < 0
    }

    /// Watts going into the pack while charging, when the board reports it.
    public var chargingWatts: Double? {
        guard isCharging, let watts = powerWatts, watts < 0 else { return nil }
        return -watts
    }

    /// Newer firmware repurposes and retires several characteristics. The
    /// cut-offs are the official app's (`q3.c.h` in the Android build).
    public var usesModernTelemetry: Bool {
        let fw = firmwareRevision ?? 0
        switch model {
        case .pint: return fw >= 5056
        case .pintX: return fw >= 5076
        case .xr: return fw >= 4153
        case .gt: return fw >= 6000
        case .gts, .xrc: return true
        default: return false
        }
    }

    /// Modern firmware never sends cell voltages; `31b` stays silent.
    public var reportsCellVoltages: Bool { !usesModernTelemetry }

    /// True once the board is serving real values. Locked boards read zero
    /// for everything except the revisions.
    public var batteryCellsComplete: Bool { batteryCells.count >= model.cellCount }

    public var looksUnlocked: Bool {
        (rideMode ?? 0) > 0 || (batteryPercent ?? 0) > 0
    }

    public mutating func apply(_ characteristic: Characteristic, data: Data) {
        guard data.count >= 2, let value = WireValue.u16(data) else { return }
        let hi = data[data.startIndex]
        let lo = data[data.startIndex + 1]

        switch characteristic {
        case .firmwareRevision: firmwareRevision = Int(value)
        case .hardwareRevision: hardwareRevision = Int(value)
        case .serialNumber: serialNumber = Int(value)
        case .rideMode: rideMode = value
        case .batteryPercent: batteryPercent = Int(lo > 0 ? lo : hi)
        case .batteryVoltage: batteryVoltage = value > 0 ? Double(value) * 0.1 : nil
        case .batteryTemperature:
            batteryTemperatureC = Int(model == .v1 || model == .plus ? hi : lo)
        case .temperature:
            motorTemperatureC = Int(lo)
            controllerTemperatureC = Int(hi)
        case .rpm: rpm = Int(value)
        case .pitch: pitch = angle(value)
        case .roll: roll = angle(value)
        case .yaw: yaw = angle(value)
        case .currentAmps:
            guard !usesModernTelemetry else { return }
            currentAmps = Double(Int16(bitPattern: value)) * model.currentScale
        case .batteryLow5:
            if usesModernTelemetry { powerWatts = Double(Int16(bitPattern: value)) }
        case .tripAmpHours: tripAmpHours = Double(value) * ampHourScale
            tripAmpHoursRaw = Int(value)
        case .tripRegenAmpHours: tripRegenAmpHours = Double(value) * ampHourScale
            tripRegenAmpHoursRaw = Int(value)
        case .tripOdometer: tripRevolutions = Int(value)
        case .lifetimeOdometer: lifetimeMiles = Int(value)
        case .lifetimeAmpHours: lifetimeAmpHours = Int(value)
        case .statusError: statusError = value
        case .lastErrorCode: battery.record(value)
        case .lightingMode: lightsOn = value == 1
        case .batteryCells:
            // The board streams one cell per notification. A plain read (or an
            // idle board) yields 0, which would otherwise decode as cell 0 at 0 V.
            guard value != 0 else { return }
            let modern = (firmwareRevision ?? 0) >= 4141
            let cell = modern ? Int(value >> 12) : Int(lo)
            let volts = modern ? Double(value & 0x0fff) * 0.0011 : Double(hi) * 0.02
            guard cell < model.cellCount, volts > 0 else { return }
            batteryCells[cell] = volts
        default: break
        }
    }

    private var ampHourScale: Double { model == .v1 ? 0.00009 : 0.00018 }

    private func angle(_ raw: UInt16) -> Double { 0.1 * (1800 - Double(raw)) }
}
