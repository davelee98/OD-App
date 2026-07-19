import Foundation

/// CRC16-CCITT (poly `OD_CONFIG_CRC_POLY` 0x1021, init `OD_CONFIG_CRC_INIT` 0xFFFF), used to verify
/// the config blob trailer on 0x40 reads. Constants come from the generated structs header.
enum ODCRC16 {
    static func compute(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc = OD_CONFIG_CRC_INIT
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ OD_CONFIG_CRC_POLY : (crc << 1)
            }
        }
        return crc
    }

    static func compute(_ bytes: [UInt8]) -> UInt16 { compute(bytes[...]) }
}
