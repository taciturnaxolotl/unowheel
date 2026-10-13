import Foundation

/// Decoded `30f` status bitmask. Layout from ponewheel's `DeviceStatus`,
/// confirmed against the official app's bit tests and a 5208 Pint.
public struct BoardStatus: Equatable, Sendable {
    public let raw: UInt16

    public init(raw: UInt16) { self.raw = raw }

    public var riderDetected: Bool { raw & 0x0100 != 0 }
    /// Footpad sensor zone 1, the front half of the pad.
    public var frontPad: Bool { raw & 0x0200 != 0 }
    /// Footpad sensor zone 2, the back half of the pad.
    public var backPad: Bool { raw & 0x0400 != 0 }
    public var charging: Bool { raw & 0x2000 != 0 }

    /// Low byte: the board's current error code, 0 when all is well.
    public var errorCode: UInt8 { UInt8(raw & 0xff) }

    public var error: BoardErrorCode? { errorCode == 0 ? nil : BoardErrorCode(code: errorCode) }

    public var faults: [String] {
        var out: [String] = []
        if raw & 0x0800 != 0 { out.append("Current sensor U") }
        if raw & 0x1000 != 0 { out.append("Current sensor V") }
        if raw & 0x4000 != 0 { out.append("Battery link") }
        if raw & 0x8000 != 0 { out.append("Capacitor") }
        return out
    }
}

/// Battery facts carried on the `31c` diagnostic stream. The board cycles
/// through about 50 one-byte registers, each sent as `register << 8 | value`;
/// the official app decodes these ones (`z1.c` in the Android build).
public struct BatteryDiagnostics: Equatable, Sendable {
    public private(set) var registers: [UInt8: UInt8] = [:]

    public init() {}

    public mutating func record(_ word: UInt16) {
        registers[UInt8(word >> 8)] = UInt8(word & 0xff)
    }

    public var cycles: Int? {
        guard let hi = registers[0xf0], let lo = registers[0xf1] else { return nil }
        return Int(hi) << 8 | Int(lo)
    }

    public var healthPercent: Int? { registers[0xf2].map(Int.init) }

    public var cellType: String? {
        guard let code = registers[0xc0] else { return nil }
        return Self.cellTypes[code] ?? "Unknown (\(code))"
    }

    public var batteryID: UInt32? {
        guard let a = registers[0xd0], let b = registers[0xd1], let c = registers[0xd2], let d = registers[0xd3] else { return nil }
        return UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    public var bootloaderVersion: Int? { registers[0x20].map(Int.init) }

    public var isEmpty: Bool { cycles == nil && healthPercent == nil && cellType == nil && batteryID == nil }

    static let cellTypes: [UInt8: String] = [
        1: "A123 LiFePO4",
        2: "Sony VTC6, 15s2p",
        3: "LG HG2, 15s2p",
        4: "Samsung 30Q, 15s2p",
        5: "Sony VTC5A, 15s1p",
        6: "Sony VTC5D, 15s1p",
        7: "Samsung 30Q6, 15s2p",
        9: "Sony VTC6A, 18s2p",
        10: "Molicel P42A, 18s2p",
        11: "Samsung 40T3, 18s2p",
    ]
}

/// Error codes from the low byte of `30f`. Titles and advice follow the
/// official app (`b2.m` in the Android build), shortened.
public struct BoardErrorCode: Equatable, Sendable {
    public let code: UInt8
    public let title: String
    public let advice: String

    public init(code: UInt8) {
        self.code = code
        let (title, advice) = Self.table[code] ?? ("Error \(code)", "Check the manual or contact support.")
        self.title = title
        self.advice = advice
    }

    static let table: [UInt8: (String, String)] = [
        1: ("Battery low", "Charge the board."),
        2: ("Battery low", "Charge the board."),
        3: ("Battery full", "Avoid steep downhills and hard braking while fully charged."),
        4: ("Start in the ready position", "Put the board flat on the ground, then turn it off and on."),
        5: ("Start in the ready position", "Put the board flat on the ground before you press power."),
        6: ("Overcurrent", "Turn the board off and on."),
        7: ("Battery too hot or cold", "Let the battery reach a normal temperature."),
        8: ("Battery too hot or cold", "Let the battery reach a normal temperature."),
        9: ("Accelerometer check failed", "Turn the board off and on."),
        10: ("Current sensor check failed", "Turn the board off and on."),
        11: ("Motor sensor problem", "Check the motor connection, then turn the board off and on."),
        12: ("Motor check failed", "Turn the board off and on."),
        13: ("Overcurrent", "Turn the board off and on."),
        14: ("Overcurrent", "Turn the board off and on."),
        15: ("Footpad pressed at startup", "Keep off the footpad while turning the board on."),
        16: ("Communication error", "Turn the board off and on. Contact support if it continues."),
        17: ("Battery too hot or cold", "Let the battery reach a normal temperature."),
        18: ("Motor too hot or cold", "Let the motor reach a normal temperature."),
        19: ("Overcharged", "Avoid steep downhills and hard braking while fully charged."),
        20: ("Board disabled", "Contact support."),
        21: ("Charger connected", "Unplug the charger to ride."),
        22: ("New battery detected", "Register the new hardware in the official app."),
        23: ("Incompatible hardware", "Contact support."),
        25: ("New controller detected", "Register the new hardware in the official app."),
    ]
}
