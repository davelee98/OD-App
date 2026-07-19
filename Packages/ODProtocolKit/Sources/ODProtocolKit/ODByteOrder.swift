import Foundation

/// Endianness helpers for wire (de)serialization. The OpenDisplay protocol mixes byte order
/// deliberately (config lengths/chunk numbers + pipe headers are little-endian; etags, partial-rect
/// fields, and the CCM/KDF counters are big-endian), so every multi-byte field goes through here or
/// through a generated `ODPackedStruct` — never hand-shifted in operation code.
enum ODByteOrder {
    static func u16LE(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func u16BE(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func u32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
    static func u32BE(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    static func u64BE(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> (8 * (7 - $0))) & 0xFF) }
    }

    static func readU16LE(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
    static func readU16BE(_ b: [UInt8], _ o: Int) -> UInt16 { (UInt16(b[o]) << 8) | UInt16(b[o + 1]) }
    static func readU32LE(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}

extension Data {
    var odHex: String { map { String(format: "%02x", $0) }.joined() }
    var odBytes: [UInt8] { [UInt8](self) }
}
