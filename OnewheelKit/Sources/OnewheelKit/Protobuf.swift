import Foundation

/// Just enough protobuf to speak GCM checkin and MCS.
struct ProtoWriter {
    var data = Data()

    static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private mutating func key(_ field: Int, _ wire: UInt64) {
        data.append(Self.encodeVarint(UInt64(field) << 3 | wire))
    }

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, 0)
        data.append(Self.encodeVarint(value))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, 2)
        data.append(Self.encodeVarint(UInt64(value.count)))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ value: ProtoWriter) { bytes(field, value.data) }
}

struct ProtoFields: Sendable {
    enum Value: Sendable { case integer(UInt64), bytes(Data) }
    struct Malformed: Error {}

    private(set) var values: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < bytes.count, shift < 64 else { throw Malformed() }
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                shift += 7
                if b & 0x80 == 0 { return result }
            }
        }
        func fixed(_ n: Int) throws -> UInt64 {
            guard i + n <= bytes.count else { throw Malformed() }
            var result: UInt64 = 0
            for k in 0..<n { result |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
            i += n
            return result
        }
        while i < bytes.count {
            let key = try varint()
            let field = Int(key >> 3)
            let value: Value
            switch key & 7 {
            case 0: value = .integer(try varint())
            case 1: value = .integer(try fixed(8))
            case 5: value = .integer(try fixed(4))
            case 2:
                let n = Int(try varint())
                guard n >= 0, i + n <= bytes.count else { throw Malformed() }
                value = .bytes(Data(bytes[i..<(i + n)]))
                i += n
            default: throw Malformed()
            }
            values[field, default: []].append(value)
        }
    }

    func integer(_ field: Int) -> UInt64? {
        if case .integer(let v) = values[field]?.first { return v }
        return nil
    }

    func bytes(_ field: Int) -> Data? {
        if case .bytes(let v) = values[field]?.first { return v }
        return nil
    }

    func string(_ field: Int) -> String? { bytes(field).map { String(decoding: $0, as: UTF8.self) } }

    func all(_ field: Int) -> [Data] {
        (values[field] ?? []).compactMap { if case .bytes(let v) = $0 { v } else { nil } }
    }
}
