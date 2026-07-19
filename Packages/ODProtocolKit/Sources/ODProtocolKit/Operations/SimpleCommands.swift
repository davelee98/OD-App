import Foundation

/// Single-exchange reads and fire-and-forget controls.
/// Firmware `0043 → major | minor | sha_len | sha`; MSD `0044 → msd(16)`. Both never encrypted.
@MainActor
struct SimpleCommands {
    let router: ODNotificationRouter
    let transmit: (Data) async throws -> Void
    let setExpectedOpcode: (UInt8?) -> Void

    func firmwareVersion() async throws -> (major: Int, minor: Int, sha: String?) {
        let note = try await request(CMD_FIRMWARE_VERSION, operation: "firmware", minPayload: 3)
        let p = note.payload
        let shaLen = Int(p[2])
        var sha: String?
        if shaLen > 0, p.count >= 3 + shaLen {
            sha = String(bytes: p[3 ..< 3 + shaLen], encoding: .ascii)
        }
        return (Int(p[0]), Int(p[1]), sha)
    }

    func readMSD() async throws -> Data {
        let note = try await request(CMD_READ_MSD, operation: "msd", minPayload: 16)
        return Data(note.payload.prefix(16))
    }

    /// Send a fire-and-forget control (reboot/DFU/sleep/power-off/raw). No response is awaited.
    func send(_ command: ODSimpleCommand) async throws {
        try await transmit(command.frame)
    }

    /// Request/response for a single-frame reply: send `opcode`, await its `00 <opcode>` (or abort on FF).
    private func request(_ opcode: UInt16, operation: String, minPayload: Int) async throws -> ODFrame.Notification {
        let lo = UInt8(opcode & 0xFF)
        setExpectedOpcode(lo)
        defer { setExpectedOpcode(nil) }
        try await transmit(ODFrame.command(opcode))
        let note = try await router.awaitNotification(operation: operation, timeout: 8) { n in
            n.status == 0xFF || (n.status == 0x00 && n.opcode == lo)
        }
        if note.status == 0xFF { throw ODProtocolError.deviceRejected(opcode: opcode, code: note.payload.first) }
        guard note.payload.count >= minPayload else {
            throw ODProtocolError.malformedResponse("\(operation) response too short")
        }
        return note
    }
}
