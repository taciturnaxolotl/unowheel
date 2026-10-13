import Foundation

/// GATT layout of the Onewheel service. Every characteristic shares the
/// `e659fXXX-ea98-11e3-ac10-0800200c9a66` template, so the short code is the
/// three hex digits in the middle.
public enum Characteristic: String, CaseIterable, Sendable {
    case serialNumber = "301"
    case rideMode = "302"
    case batteryPercent = "303"
    case batteryLow5 = "304"
    case batteryLow20 = "305"
    case batterySerial = "306"
    case pitch = "307"
    case roll = "308"
    case yaw = "309"
    case tripOdometer = "30a"
    case rpm = "30b"
    case lightingMode = "30c"
    case lightsFront = "30d"
    case lightsBack = "30e"
    case statusError = "30f"
    case temperature = "310"
    case firmwareRevision = "311"
    case currentAmps = "312"
    case tripAmpHours = "313"
    case tripRegenAmpHours = "314"
    case batteryTemperature = "315"
    case batteryVoltage = "316"
    case safetyHeadroom = "317"
    case hardwareRevision = "318"
    case lifetimeOdometer = "319"
    case lifetimeAmpHours = "31a"
    case batteryCells = "31b"
    case lastErrorCode = "31c"
    case unknown31d = "31d"
    case unknown31e = "31e"
    case rsaChannel = "31f"
    case unknown320 = "320"
    case uartRead = "3fe"
    case uartWrite = "3ff"

    public static let serviceUUIDString = uuidString(for: "300")

    public static func uuidString(for code: String) -> String {
        "E659F\(code.uppercased())-EA98-11E3-AC10-0800200C9A66"
    }

    public var uuidString: String { Self.uuidString(for: rawValue) }

    public init?(uuidString: String) {
        let upper = uuidString.uppercased()
        guard upper.hasPrefix("E659F"), upper.hasSuffix("-EA98-11E3-AC10-0800200C9A66") else { return nil }
        let code = upper.dropFirst(5).prefix(3).lowercased()
        self.init(rawValue: String(code))
    }

    /// Characteristics worth subscribing to once the board is unlocked.
    public static let telemetry: [Characteristic] = [
        .rideMode, .batteryPercent, .pitch, .roll, .yaw, .tripOdometer, .rpm,
        .lightingMode, .statusError, .temperature, .currentAmps, .tripAmpHours,
        .tripRegenAmpHours, .batteryTemperature, .batteryVoltage, .safetyHeadroom,
        .lifetimeOdometer, .lifetimeAmpHours, .batteryCells, .batteryLow5,
    ]
}

public enum WireValue {
    /// Board values are big-endian unsigned 16-bit.
    public static func u16(_ data: Data) -> UInt16? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data.prefix(2))
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    public static func encode(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xff)])
    }
}
