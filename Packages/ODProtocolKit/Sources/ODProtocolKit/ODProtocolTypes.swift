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
    case malformedResponse(String)
    case sizeMismatch(expected: Int, actual: Int)
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
