import Foundation

/// Legacy single-rectangle partial write (0x76 START → 0x71 DATA → 0x72 END). **Transport only** —
/// the caller supplies the fully-built region stream (`old_rect ‖ new_rect`, 1bpp-packed, optionally
/// level-6/window-9 deflated with `flags` bit0 set) and the rectangle; region diffing / etag tracking
/// live in the app composer, which owns the last-displayed image.
///
/// Wire (ported from py `device.py:_maybe_upload_partial` legacy branch): the 0x76 START carries the
/// 17-byte **big-endian** `PartialWriteStartHeader` plus leading stream bytes; the remainder streams via
/// 0x71 (stop-and-wait, same as direct-write); the transfer ends with `0x72 [refresh=PARTIAL(2)]`. A
/// pre-refresh NACK (`FF 76 <OD_ERR_PARTIAL_*>`) surfaces as `deviceRejected` so the caller can fall
/// back to a full upload (and reset its etag, since the device clears its displayed etag on rejection).
@MainActor
struct PartialWriteUploader {
    let policy: ODChunkPolicy
    let router: ODNotificationRouter
    let transmit: (Data) async throws -> Void
    let setExpectedOpcode: (UInt8?) -> Void

    struct Rect { var x: UInt16; var y: UInt16; var width: UInt16; var height: UInt16 }

    /// `flags` bit0 = PARTIAL_FLAG_COMPRESSED (stream is zlib, level 6 / window 9). `stream` is the
    /// full region payload; this method splits its leading bytes into the START and chunks the rest.
    func run(flags: UInt8, oldEtag: UInt32, newEtag: UInt32, rect: Rect, stream: Data,
             progress: ((ODUploadProgress) -> Void)? = nil) async throws {
        let header = PartialWriteStartHeader(flags: flags, oldEtag: oldEtag, newEtag: newEtag,
                                             x: rect.x, y: rect.y, width: rect.width, height: rect.height).serialize()
        let bytes = [UInt8](stream)

        // START payload = 17-byte header + leading stream (bounded by the start budget minus the header).
        let leadBudget = max(0, policy.directWriteStartPayload - header.count)
        let lead = min(leadBudget, bytes.count)
        let startPayload = header + Array(bytes[0..<lead])
        var remainder = Array(bytes[lead...])

        setExpectedOpcode(UInt8(CMD_PARTIAL_WRITE_START & 0xFF))
        try await transmit(ODFrame.command(CMD_PARTIAL_WRITE_START, payload: startPayload))
        try await awaitAck(CMD_PARTIAL_WRITE_START, operation: "partialStart", timeout: 8)
        var sent = lead
        progress?(ODUploadProgress(bytesSent: sent, bytesTotal: bytes.count, phase: .sending))

        // Remaining stream via 0x71 stop-and-wait (identical framing to direct-write DATA).
        let chunkSize = policy.directWriteChunkSize
        let dataLo = UInt8(CMD_DIRECT_WRITE_DATA & 0xFF)
        let chunks = stride(from: 0, to: remainder.count, by: chunkSize).map {
            Array(remainder[$0 ..< min($0 + chunkSize, remainder.count)])
        }
        remainder = []
        for (i, chunk) in chunks.enumerated() {
            setExpectedOpcode(dataLo)
            try await transmit(ODFrame.command(CMD_DIRECT_WRITE_DATA, payload: chunk))
            try await awaitAck(CMD_DIRECT_WRITE_DATA, operation: "partialData", timeout: 8)
            sent += chunk.count
            if i % 10 == 0 || i == chunks.count - 1 {
                progress?(ODUploadProgress(bytesSent: sent, bytesTotal: bytes.count, phase: .sending))
            }
        }

        // END with the PARTIAL refresh selector (0x72 | 0x02).
        setExpectedOpcode(UInt8(CMD_DIRECT_WRITE_END & 0xFF))
        try await transmit(ODFrame.command(CMD_DIRECT_WRITE_END, payload: [ODRefreshMode.partial.rawValue]))
        try await awaitAck(CMD_DIRECT_WRITE_END, operation: "partialEnd", timeout: 8)
        setExpectedOpcode(nil)
        progress?(ODUploadProgress(bytesSent: bytes.count, bytesTotal: bytes.count, phase: .awaitingRefresh))
    }

    private func awaitAck(_ opcode: UInt16, operation: String, timeout: TimeInterval) async throws {
        let lo = UInt8(opcode & 0xFF)
        let note = try await router.awaitNotification(operation: operation, timeout: timeout) { n in
            n.status == 0xFF || (n.status == 0x00 && n.opcode == lo) || (n.status == 0xFE && n.opcode == lo)
        }
        if note.status == 0xFF { throw ODProtocolError.deviceRejected(opcode: opcode, code: note.payload.first) }
        if note.status == 0xFE { throw ODProtocolError.authRequired }
    }
}
