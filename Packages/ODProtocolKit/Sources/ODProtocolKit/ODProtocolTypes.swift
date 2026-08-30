import Foundation

/// Refresh mode carried in the 0x72 / 0x82 END command.
public enum ODRefreshMode: UInt8 {
    case full = 0
    case fast = 1
    case partial = 2
}

/// Why a 0x50 handshake was rejected.
///
/// Typed rather than a string so callers can act on the distinction: a `.wrongKey` means the stored
/// credential is provably bad and should be forgotten, `.rateLimited` means the key may well be fine
/// and retrying is exactly what caused the problem, and `.notConfigured` means the display has no
/// encryption at all — not a user-facing failure. Sniffing substrings out of an error message to
/// recover that is the anti-pattern this type exists to remove.
public enum ODAuthFailureReason: Error, Equatable, Sendable {
    /// AUTH_STATUS_FAILED — the device rejected our proof. The only reason that condemns the key.
    case wrongKey
    /// AUTH_STATUS_NOT_CONFIG — the display has no encryption configured.
    case notConfigured
    /// AUTH_STATUS_RATE_LIMIT — too many attempts; back off rather than retry.
    case rateLimited
    /// The device's own proof didn't verify. This happens *after* it accepted ours, so it means a
    /// corrupt response, a protocol mismatch, a defective device, or a hostile peer — NOT a wrong key.
    case proofMismatch
    /// Two consecutive ALREADY replies: a stale session on the device, retryable after a reconnect.
    case noFreshChallenge
    /// Any other 0x50 status byte, including AUTH_STATUS_ERROR (0xFF).
    case deviceError(UInt8)

    /// The user-visible reason clause, matching the strings previously inlined in `Authenticator`.
    public var message: String {
        switch self {
        case .wrongKey:            return "wrong key"
        case .notConfigured:       return "encryption not configured on device"
        case .rateLimited:         return "rate limited (too many attempts)"
        case .proofMismatch:       return "server proof mismatch"
        case .noFreshChallenge:    return "no fresh challenge (session busy)"
        case .deviceError(let s):  return "device error 0x\(String(s, radix: 16))"
        }
    }
}

public enum ODProtocolError: Error, Equatable {
    case busy                          // an operation is already in flight
    case notConnected
    case disconnected
    case timeout(operation: String)
    case deviceRejected(opcode: UInt16, code: UInt8?)   // an FF <opcode> [err] notification
    case authRequired                  // 0x..FE
    case authFailed(ODAuthFailureReason)   // handshake rejected, or the device's proof didn't verify
    case malformedResponse(String)
    case sizeMismatch(expected: Int, actual: Int)
}

/// Human-readable messages. Without this, `.localizedDescription` renders as the Foundation default
/// ("The operation couldn't be completed. (ODProtocolKit.ODProtocolError error 5.)"), which is what
/// every one of these errors used to show the user once it reached `ODDevice.lastError`.
extension ODProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .busy:
            return "Another operation is already in progress."
        case .notConnected:
            return "The display is not connected."
        case .disconnected:
            return "The display disconnected."
        case .timeout(let operation):
            return "The display stopped responding (\(operation))."
        case .deviceRejected(let opcode, let code):
            let suffix = code.map { " (error 0x\(String($0, radix: 16)))" } ?? ""
            return "The display rejected command 0x\(String(format: "%04X", opcode))\(suffix)."
        case .authRequired:
            return "This display is password protected."
        case .authFailed(let reason):
            return "Authentication failed: \(reason.message)."
        case .malformedResponse(let what):
            return "The display sent an unexpected response (\(what))."
        case .sizeMismatch(let expected, let actual):
            return "Size mismatch: expected \(expected) bytes, got \(actual)."
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
