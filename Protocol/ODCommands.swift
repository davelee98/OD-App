import Foundation

enum ODCommands {

    // `ble-common.js` owns core commands, authentication, config transfer, and image transfer.
    // These payload helpers remain for controls not exposed as first-class methods by the web library.

    static func deepSleep() -> Data { OD.Cmd.deepSleep.header }

    // MARK: - NFC
    // Single  (≤120 bytes): 0x0082 0x01 type lenHi lenLo payload
    // Chunked: 0x0082 0x10 type lenHi lenLo  →  0x0082 0x11 chunk…  →  0x0082 0x12

    static func nfcWriteSingle(type: UInt8, payload: Data) -> Data {
        var p = OD.Cmd.nfc.header
        p.append(0x01)
        p.append(type)
        p.appendUInt16BE(UInt16(payload.count))
        p.append(payload)
        return p
    }

    static func nfcWriteStart(type: UInt8, totalLength: UInt16) -> Data {
        var p = OD.Cmd.nfc.header
        p.append(0x10)
        p.append(type)
        p.appendUInt16BE(totalLength)
        return p
    }

    static func nfcWriteChunk(_ data: Data) -> Data {
        var p = OD.Cmd.nfc.header; p.append(0x11); p.append(data); return p
    }

    static func nfcWriteEnd() -> Data {
        var p = OD.Cmd.nfc.header; p.append(0x12); return p
    }
}

// MARK: - Data Helpers

extension Data {
    func chunked(size: Int) -> [Data] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            self[$0 ..< Swift.min($0 + size, count)]
        }
    }

    mutating func appendUInt16LE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendUInt16BE(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendUInt32LE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }

    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    init?(hexString: String) {
        let hex = hexString.replacingOccurrences(of: " ", with: "")
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte); idx = next
        }
        self.init(bytes)
    }
}
