import Foundation

/// The legacy direct-write image upload (0x70 start / 0x71 data / 0x72 end).
///
/// Compression gate: compress iff `TransmissionModes` bit0 (streaming decompression) is set, with
/// `deflate(level 9, windowBits 9)`. Start frame is bare `0070` (uncompressed) or
/// `0070 | uncompressed_size(u32 LE) | leading compressed bytes` (compressed). Data chunks are
/// `0071 | chunk`, strict **stop-and-wait** (one ACK in flight). End is `0072 | refresh_mode [| etag BE]`.
/// Refresh (0x73/0x74) is not awaited here — the caller completes at the last data ACK and receives
/// refresh completion via `ODClientEvent`.
@MainActor
struct DirectWriteUploader {
    let policy: ODChunkPolicy
    let router: ODNotificationRouter
    /// Encryption seam: plaintext `link.send` in Phase 1; wraps in CCM once a session exists.
    let transmit: (Data) async throws -> Void
    let setExpectedOpcode: (UInt8?) -> Void

    func run(packed: Data,
             modes: TransmissionModes,
             refresh: ODRefreshMode,
             etag: UInt32?,
             progress: ((ODUploadProgress) -> Void)?) async throws {

        // 1. Compression gate.
        let compress = modes.contains(.streamingDecompression)
        let wire: Data
        if compress {
            progress?(ODUploadProgress(bytesSent: 0, bytesTotal: packed.count, phase: .compressing))
            wire = try ODDeflate.deflate(packed, level: 9, windowBits: 9)
        } else {
            wire = packed
        }

        // 2. Build the 0x70 start; split leading bytes vs. the chunked remainder.
        let startLo = UInt8(CMD_DIRECT_WRITE_START & 0xFF)
        var remainder: [UInt8]
        let startPayload: [UInt8]
        if compress {
            var p = ODByteOrder.u32LE(UInt32(packed.count))          // uncompressed size header
            let lead = min(wire.count, policy.directWriteStartCompressedLeading)
            p += [UInt8](wire.prefix(lead))
            startPayload = p
            remainder = [UInt8](wire.suffix(from: lead))
        } else {
            startPayload = []
            remainder = [UInt8](wire)
        }

        // 3. Start → wait 0x70 ACK.
        setExpectedOpcode(startLo)
        try await transmit(ODFrame.command(CMD_DIRECT_WRITE_START, payload: startPayload))
        try await awaitAck(CMD_DIRECT_WRITE_START, operation: "imageStart", timeout: 8)

        // 4. Chunk the remainder, stop-and-wait.
        let chunkSize = policy.directWriteChunkSize
        let chunks = stride(from: 0, to: remainder.count, by: chunkSize).map {
            Array(remainder[$0 ..< min($0 + chunkSize, remainder.count)])
        }
        let dataLo = UInt8(CMD_DIRECT_WRITE_DATA & 0xFF)
        var sent = startPayload.count
        for (i, chunk) in chunks.enumerated() {
            setExpectedOpcode(dataLo)
            try await transmit(ODFrame.command(CMD_DIRECT_WRITE_DATA, payload: chunk))
            try await awaitAck(CMD_DIRECT_WRITE_DATA, operation: "imageData", timeout: 8)
            sent += chunk.count
            if i % 10 == 0 || i == chunks.count - 1 {
                progress?(ODUploadProgress(bytesSent: sent, bytesTotal: wire.count, phase: .sending))
            }
        }
        // Ensure a final 100% tick (covers the fits-entirely-in-start case).
        progress?(ODUploadProgress(bytesSent: wire.count, bytesTotal: wire.count, phase: .sending))

        // 5. End (0x72 | refresh [| etag BE]) → wait 0x72 ACK, then return (refresh via event).
        var endPayload: [UInt8] = [refresh.rawValue]
        if let etag { endPayload += ODByteOrder.u32BE(etag) }
        setExpectedOpcode(UInt8(CMD_DIRECT_WRITE_END & 0xFF))
        try await transmit(ODFrame.command(CMD_DIRECT_WRITE_END, payload: endPayload))
        try await awaitAck(CMD_DIRECT_WRITE_END, operation: "imageEnd", timeout: 8)
        setExpectedOpcode(nil)
        progress?(ODUploadProgress(bytesSent: wire.count, bytesTotal: wire.count, phase: .awaitingRefresh))
    }

    /// Await a `00 <opcode>` ACK; any `FF <opcode>` aborts, any `FE` is auth-required.
    private func awaitAck(_ opcode: UInt16, operation: String, timeout: TimeInterval) async throws {
        let lo = UInt8(opcode & 0xFF)
        let note = try await router.awaitNotification(operation: operation, timeout: timeout) { n in
            n.status == 0xFF || (n.status == 0x00 && n.opcode == lo) || (n.status == 0xFE && n.opcode == lo)
        }
        if note.status == 0xFF { throw ODProtocolError.deviceRejected(opcode: opcode, code: note.payload.first) }
        if note.status == 0xFE { throw ODProtocolError.authRequired }
    }
}
