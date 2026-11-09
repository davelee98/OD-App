import Foundation

/// Refresh mode carried in the 0x72 / 0x82 END command.
public enum ODRefreshMode: UInt8 {
    case full = 0
    case fast = 1
    case partial = 2
}

public enum ODProtocolError: Error, Equatable {
    case busy                          // an operation is already in flight
    case notConnected
    case disconnected
    case timeout(operation: String)
    case deviceRejected(opcode: UInt16, code: UInt8?)   // an FF <opcode> [err] notification
    case authRequired                  // 0x..FE
    case authFailed(String)            // handshake rejected, or device's mutual-auth proof mismatched
    case encryptionNotConfigured       // 0x50 answered NOT_CONFIG: the device has no key at all
    case malformedResponse(String)
    case sizeMismatch(expected: Int, actual: Int)
}

extension ODProtocolError: LocalizedError {
    /// User-facing text. Without this, SwiftUI surfaces the bridged default
    /// ("The operation couldn't be completed. (ODProtocolKit.ODProtocolError error 5.)").
    public var errorDescription: String? {
        switch self {
        case .busy: return "Another operation is still running on the display."
        case .notConnected: return "The display is not connected."
        case .disconnected: return "The display disconnected."
        case .timeout(let operation): return "The display stopped responding (\(operation))."
        case .deviceRejected(let opcode, let code):
            let detail = code.map { String(format: ", code 0x%02X", $0) } ?? ""
            return String(format: "The display rejected command 0x%04X", opcode) + detail + "."
        case .authRequired: return "This display is encrypted. Enter its key to continue."
        case .authFailed(let reason): return "Authentication failed: \(reason)."
        case .encryptionNotConfigured: return "This display has no encryption key configured."
        case .malformedResponse(let what): return "The display sent an unexpected response (\(what))."
        case .sizeMismatch(let expected, let actual):
            return "Image size mismatch: expected \(expected) bytes, got \(actual)."
        }
    }
}

/// High-level events the client surfaces out-of-band (not tied to a specific awaited call).
public enum ODClientEvent {
    case refreshCompleted              // 0x73 after an image END
    case refreshTimedOut               // 0x74
    case log(String)
}

/// Upload progress, mapped by `ODDevice` onto its `@Published` state / composer overlay.
public struct ODUploadProgress {
    public enum Phase { case compressing, sending, awaitingRefresh }
    public let bytesSent: Int
    public let bytesTotal: Int
    public let phase: Phase
}

/// Direction of a wire packet, for logging parity with the existing BLE log.
public enum ODWireDirection { case sent, received }

/// Fire-and-forget device controls (no ACK is awaited — the device may reboot/sleep and drop BLE).
public enum ODSimpleCommand {
    case reboot                        // 0x0F
    case enterDFU                      // 0x51
    case deepSleep(seconds: UInt16?)   // 0x52 [| seconds(u16 BE) wake override]
    case powerOff                      // 0x53 (protocol 2.1)
    case raw(opcode: UInt16, payload: [UInt8])

    var frame: Data {
        switch self {
        case .reboot:   return ODFrame.command(CMD_REBOOT)
        case .enterDFU: return ODFrame.command(CMD_ENTER_DFU)
        case .deepSleep(let seconds):
            let payload = (seconds ?? 0) > 0 ? ODByteOrder.u16BE(seconds!) : []
            return ODFrame.command(CMD_DEEP_SLEEP, payload: payload)
        case .powerOff: return ODFrame.command(CMD_POWER_OFF)
        case .raw(let opcode, let payload): return ODFrame.command(opcode, payload: payload)
        }
    }
}
