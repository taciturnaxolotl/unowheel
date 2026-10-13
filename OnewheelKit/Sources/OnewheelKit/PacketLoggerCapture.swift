import Foundation

/// Pulls unlock responses out of an iOS PacketLogger capture (`.pklg`) of the
/// official app talking to a board.
public enum PacketLoggerCapture {
    public struct Findings: Equatable, Sendable {
        /// 20-byte writes to the UART write characteristic, oldest first.
        public var responses: [Data] = []
        /// Challenges the board sent on the UART read characteristic.
        public var challenges: [Challenge] = []
    }

    struct Record {
        let type: UInt8
        let payload: Data
    }

    struct ATT {
        let sent: Bool
        let pdu: Data
    }

    public static func findings(in data: Data) -> Findings {
        let atts = attPDUs(records(in: data))
        let handles = characteristicHandles(atts)
        let txHandle = handles[.uartWrite]
        let rxHandle = handles[.uartRead]

        var result = Findings()
        var assembler = ChallengeAssembler()
        for att in atts {
            guard att.pdu.count >= 3 else { continue }
            let opcode = att.pdu[att.pdu.startIndex]
            let handle = UInt16(att.pdu[att.pdu.startIndex + 1]) | UInt16(att.pdu[att.pdu.startIndex + 2]) << 8
            let value = att.pdu.dropFirst(3)

            if att.sent, opcode == 0x12 || opcode == 0x52, value.count == Handshake.frameLength {
                let matchesHandle = txHandle.map { $0 == handle } ?? Handshake.hasValidCheck(Data(value))
                if matchesHandle, !result.responses.contains(Data(value)) {
                    result.responses.append(Data(value))
                }
            }
            if !att.sent, opcode == 0x1b, let rxHandle, handle == rxHandle,
               let challenge = assembler.feed(Data(value)), !result.challenges.contains(challenge) {
                result.challenges.append(challenge)
            }
        }
        return result
    }

    static func records(in data: Data) -> [Record] {
        let bytes = [UInt8](data)
        let littleEndian = looksLittleEndian(bytes)
        var records: [Record] = []
        var i = 0
        while i + 13 <= bytes.count {
            let length = readU32(bytes, at: i, littleEndian: littleEndian)
            let end = i + 4 + Int(length)
            guard length >= 9, end <= bytes.count else { break }
            records.append(Record(type: bytes[i + 12], payload: Data(bytes[(i + 13)..<end])))
            i = end
        }
        return records
    }

    private static func looksLittleEndian(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return true }
        let le = readU32(bytes, at: 0, littleEndian: true)
        return le >= 9 && le < 1 << 20
    }

    private static func readU32(_ b: [UInt8], at i: Int, littleEndian: Bool) -> UInt32 {
        let v = (UInt32(b[i]), UInt32(b[i + 1]), UInt32(b[i + 2]), UInt32(b[i + 3]))
        return littleEndian
            ? v.0 | v.1 << 8 | v.2 << 16 | v.3 << 24
            : v.3 | v.2 << 8 | v.1 << 16 | v.0 << 24
    }

    /// Reassembles HCI ACL fragments (types 2 = sent, 3 = received) into ATT PDUs.
    static func attPDUs(_ records: [Record]) -> [ATT] {
        struct Key: Hashable { let sent: Bool; let handle: UInt16 }
        var pending: [Key: Data] = [:]
        var out: [ATT] = []
        for record in records where record.type == 2 || record.type == 3 {
            let p = [UInt8](record.payload)
            guard p.count >= 4 else { continue }
            let rawHandle = UInt16(p[0]) | UInt16(p[1]) << 8
            let length = Int(UInt16(p[2]) | UInt16(p[3]) << 8)
            let body = Data(p[4..<min(p.count, 4 + length)])
            let key = Key(sent: record.type == 2, handle: rawHandle & 0x0fff)
            if (rawHandle >> 12) & 0x3 == 1 {
                pending[key]?.append(body)
            } else {
                pending[key] = body
            }
            guard let buffer = pending[key], buffer.count >= 4 else { continue }
            let b = [UInt8](buffer)
            let l2capLength = Int(UInt16(b[0]) | UInt16(b[1]) << 8)
            let cid = UInt16(b[2]) | UInt16(b[3]) << 8
            guard b.count >= 4 + l2capLength else { continue }
            if cid == 0x0004 {
                out.append(ATT(sent: key.sent, pdu: Data(b[4..<(4 + l2capLength)])))
            }
            pending[key] = nil
        }
        return out
    }

    /// Maps characteristics to value handles using Read By Type responses
    /// from service discovery, when the capture includes them.
    static func characteristicHandles(_ atts: [ATT]) -> [Characteristic: UInt16] {
        var map: [Characteristic: UInt16] = [:]
        for att in atts where !att.sent {
            let p = [UInt8](att.pdu)
            guard p.count >= 2, p[0] == 0x09, p[1] == 21 else { continue }
            var i = 2
            while i + 21 <= p.count {
                let valueHandle = UInt16(p[i + 3]) | UInt16(p[i + 4]) << 8
                let uuid = Data(p[(i + 5)..<(i + 21)].reversed()).hexString
                if uuid.hasPrefix("e659f"), let c = Characteristic(rawValue: String(Array(uuid)[5..<8])) {
                    map[c] = valueHandle
                }
                i += 21
            }
        }
        return map
    }
}
