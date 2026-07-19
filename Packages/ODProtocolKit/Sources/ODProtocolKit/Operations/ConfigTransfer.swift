import Foundation

/// Config-blob transport (0x40 read / 0x41-0x42 write). **Transport only** — the raw blob is handed
/// to the retained toolbox/config engine for content encode/decode; this layer never interprets
/// packet fields.
///
/// Read: request `0040`, then collect the unsolicited chunk stream
/// `0040 | chunk_no(u16 LE) | [total(u16 LE) on chunk 0] | data`; complete by byte count; reassemble
/// in chunk-number order. Write: `0041 | total(u16 LE) | first≤200` then `0042 | next≤200`, one
/// per-chunk ACK in flight (`0041`/`0042` echo); `..FE` = auth-required, `FF ..` = failure.
@MainActor
struct ConfigTransfer {
    let router: ODNotificationRouter
    let policy: ODChunkPolicy
    let transmit: (Data) async throws -> Void
    let setExpectedOpcode: (UInt8?) -> Void

    func read(progress: ((Double) -> Void)?) async throws -> Data {
        let lo = UInt8(CMD_CONFIG_READ & 0xFF)
        setExpectedOpcode(lo)
        defer { setExpectedOpcode(nil) }
        try await transmit(ODFrame.command(CMD_CONFIG_READ))

        var chunks: [Int: [UInt8]] = [:]
        var total = -1
        var received = 0
        return try await router.awaitCollected(operation: "configRead") { note in
            guard note.opcode == lo else { return nil }
            if note.status == 0xFF { throw ODProtocolError.deviceRejected(opcode: CMD_CONFIG_READ, code: note.payload.first) }
            guard note.status == 0x00 else { return nil }
            // Auth-required is `00 40 FE` (status 0x00, payload byte 0xFE), not a chunk.
            if note.payload.first == 0xFE { throw ODProtocolError.authRequired }
            let p = note.payload
            guard p.count >= 2 else { throw ODProtocolError.malformedResponse("config chunk header") }
            let chunkNo = Int(ODByteOrder.readU16LE(p, 0))
            let data: [UInt8]
            if chunkNo == 0 {
                guard p.count >= 4 else { throw ODProtocolError.malformedResponse("config chunk-0 header") }
                total = Int(ODByteOrder.readU16LE(p, 2))
                data = Array(p[4...])
            } else {
                data = Array(p[2...])
            }
            if chunks[chunkNo] == nil { received += data.count }
            chunks[chunkNo] = data
            if total >= 0 { progress?(Double(received) / Double(max(1, total))) }
            guard total >= 0, received >= total else { return nil }   // more chunks still coming
            return Data(chunks.keys.sorted().flatMap { chunks[$0]! })
        }
    }

    func write(_ blob: Data, progress: ((Double) -> Void)?) async throws {
        let bytes = [UInt8](blob)
        let chunkSize = policy.configChunkSize     // 200
        let writeLo = UInt8(CMD_CONFIG_WRITE & 0xFF)
        let chunkLo = UInt8(CMD_CONFIG_CHUNK & 0xFF)
        defer { setExpectedOpcode(nil) }

        if bytes.count <= chunkSize {
            setExpectedOpcode(writeLo)
            try await transmit(ODFrame.command(CMD_CONFIG_WRITE, payload: bytes))
            try await awaitAck(CMD_CONFIG_WRITE, operation: "configWrite")
            progress?(1)
            return
        }

        // First chunk: 0041 | total(u16 LE) | first 200 bytes.
        let firstLen = min(chunkSize, bytes.count)
        setExpectedOpcode(writeLo)
        try await transmit(ODFrame.command(CMD_CONFIG_WRITE,
                                           payload: ODByteOrder.u16LE(UInt16(bytes.count)) + Array(bytes[0..<firstLen])))
        try await awaitAck(CMD_CONFIG_WRITE, operation: "configWriteFirst")
        var offset = firstLen
        progress?(Double(offset) / Double(bytes.count))

        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            setExpectedOpcode(chunkLo)
            try await transmit(ODFrame.command(CMD_CONFIG_CHUNK, payload: Array(bytes[offset..<end])))
            try await awaitAck(CMD_CONFIG_CHUNK, operation: "configWriteChunk")
            offset = end
            progress?(Double(offset) / Double(bytes.count))
        }
    }

    private func awaitAck(_ opcode: UInt16, operation: String) async throws {
        let lo = UInt8(opcode & 0xFF)
        let note = try await router.awaitNotification(operation: operation, timeout: 8) { n in
            n.status == 0xFF || (n.status == 0x00 && n.opcode == lo)
        }
        if note.status == 0xFF { throw ODProtocolError.deviceRejected(opcode: opcode, code: note.payload.first) }
        // Auth-required for config write is `00 41 FE` (status 0x00, payload byte 0xFE).
        if note.payload.first == 0xFE { throw ODProtocolError.authRequired }
    }
}
