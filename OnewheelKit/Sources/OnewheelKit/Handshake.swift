import CryptoKit
import Foundation

public enum Handshake {
    public static let frameLength = 20

    /// Gemini-era static key, recovered by ponewheel and still served by the
    /// official app's native `getChallengeResponsePassword`.
    public static let geminiKey = Data([
        0xD9, 0x25, 0x5F, 0x0F, 0x23, 0x35, 0x4E, 0x19,
        0xBA, 0x73, 0x9C, 0xCD, 0xC4, 0xA9, 0x17, 0x65,
    ])

    public static func xor(_ bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(0, ^)
    }

    public static func hasValidCheck(_ frame: Data) -> Bool {
        let bytes = [UInt8](frame)
        return bytes.count == frameLength && xor(bytes[0..<19]) == bytes[19]
    }

    /// How a board with this firmware expects to be unlocked.
    public enum Strategy: Equatable, Sendable {
        /// Pre-Gemini boards serve data without a handshake.
        case none
        /// Response computed locally with the static MD5 key (fw 4034..<4141).
        case gemini
        /// Response issued once per board by Future Motion's server (fw >= 4141).
        case serverIssued
    }

    public static func strategy(firmware: Int) -> Strategy {
        switch firmware {
        case ..<4034: .none
        case 4034..<4141: .gemini
        default: .serverIssued
        }
    }

    public struct KeepAlive: Equatable, Sendable {
        public let characteristic: Characteristic
        public let payload: Data
        public let interval: TimeInterval
    }

    /// The official app writes `01 01` to `30b` every 1.5 s on server-issued
    /// firmware. Older boards want the firmware revision written back to itself.
    /// Without either, a 5208 Pint relocks between 11 and 16 s.
    public static func keepAlive(firmware: Int) -> KeepAlive {
        if strategy(firmware: firmware) == .serverIssued {
            return KeepAlive(characteristic: .rpm, payload: Data([0x01, 0x01]), interval: 1.5)
        }
        return KeepAlive(characteristic: .firmwareRevision, payload: WireValue.encode(UInt16(clamping: firmware)), interval: 10)
    }

    public static func geminiResponse(for challenge: Challenge) -> Data {
        let digest = Insecure.MD5.hash(data: challenge.nonce + geminiKey)
        return sealed(challenge.header + Data(digest))
    }

    /// Appends the XOR check byte to a 19-byte body.
    public static func sealed(_ body: Data) -> Data {
        body + Data([xor(body)])
    }

    /// Checks that a response has the shape the board expects for this
    /// challenge: 20 bytes, same 3-byte header, valid check byte.
    public static func isPlausibleResponse(_ response: Data, for challenge: Challenge) -> Bool {
        hasValidCheck(response) && response.prefix(3) == challenge.header
    }

    public static func parseHex(_ text: String) -> Data? {
        let hex = text.filter(\.isHexDigit)
        guard hex.count.isMultiple(of: 2), !hex.isEmpty else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

public struct Challenge: Equatable, Hashable, Sendable {
    public let bytes: Data

    public init?(_ bytes: Data) {
        guard Handshake.hasValidCheck(bytes) else { return nil }
        self.bytes = Data(bytes)
    }

    /// First three bytes. `CRX` on Gemini firmware; board-specific on Hydrus.
    public var header: Data { bytes.prefix(3) }

    /// The 16 bytes the server (or the Gemini MD5) works from.
    public var nonce: Data { bytes.subdata(in: 3..<19) }

    public var usesLegacyHeader: Bool { header == Data("CRX".utf8) }

    public var hex: String { bytes.hexString }
}

/// Collects UART notifications until a full challenge frame has arrived.
/// The board splits the 20 bytes over many 1 to 3 byte notifications.
public struct ChallengeAssembler: Sendable {
    public private(set) var buffer = Data()

    public init() {}

    public mutating func reset() { buffer.removeAll() }

    public mutating func feed(_ chunk: Data) -> Challenge? {
        buffer.append(chunk)
        if let crx = buffer.range(of: Data("CRX".utf8)), buffer.count - crx.lowerBound >= Handshake.frameLength {
            let start = crx.lowerBound
            let frame = buffer.subdata(in: start..<(start + Handshake.frameLength))
            if let challenge = Challenge(frame) {
                buffer.removeAll()
                return challenge
            }
        }
        guard buffer.count >= Handshake.frameLength else { return nil }
        for start in 0...(buffer.count - Handshake.frameLength) {
            let frame = buffer.subdata(in: start..<(start + Handshake.frameLength))
            if let challenge = Challenge(frame) {
                buffer.removeAll()
                return challenge
            }
        }
        if buffer.count > 4 * Handshake.frameLength {
            buffer.removeFirst(buffer.count - Handshake.frameLength)
        }
        return nil
    }
}

extension Data {
    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
    public var spacedHex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
