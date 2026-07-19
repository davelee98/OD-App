import Foundation

/// Wire framing + notification classification.
///
/// Commands are `[00][opcode_lo][payload…]` (the opcode's high byte is 0x00 for host→device).
/// Notifications are `[status][opcode][payload…]`: `status == 0x00` = ACK/data, `0xFF` = error,
/// `0xFE` = auth-required. Some firmware emits the two header bytes in the opposite order
/// (`[opcode][00]`), so classification tolerates both.
enum ODFrame {

    /// Build a host→device command: `[00][opcode_lo][payload]`.
    static func command(_ opcode: UInt16, payload: [UInt8] = []) -> Data {
        Data([0x00, UInt8(opcode & 0xFF)] + payload)
    }

    struct Notification {
        let status: UInt8       // 0x00 ack/data, 0xFF error, 0xFE auth-required
        let opcode: UInt8       // the low opcode byte
        let payload: [UInt8]    // bytes after the 2-byte header
        let raw: [UInt8]
    }

    /// Classify an incoming notification, tolerating `[status][opcode]` and `[opcode][status]`
    /// header orderings. `expectedOpcode` (the low byte of the op currently in flight) disambiguates
    /// the byte order and resolves the 0x73 collision (refresh-complete vs LED-ack) by context.
    static func classify(_ data: [UInt8], expectedOpcode: UInt8?) -> Notification? {
        guard data.count >= 2 else { return nil }
        let b0 = data[0], b1 = data[1]
        let statusBytes: Set<UInt8> = [0x00, 0xFF, 0xFE]

        // Preferred order: [status][opcode].
        if statusBytes.contains(b0), (expectedOpcode == nil || b1 == expectedOpcode) {
            return Notification(status: b0, opcode: b1, payload: Array(data[2...]), raw: data)
        }
        // Swapped order: [opcode][status].
        if statusBytes.contains(b1), (expectedOpcode == nil || b0 == expectedOpcode) {
            return Notification(status: b1, opcode: b0, payload: Array(data[2...]), raw: data)
        }
        // Fall back to the preferred order even if the opcode doesn't match the expectation
        // (lets callers still see unexpected ACKs / generic 0x63 / 0xFFFF frames).
        if statusBytes.contains(b0) {
            return Notification(status: b0, opcode: b1, payload: Array(data[2...]), raw: data)
        }
        return nil
    }
}
