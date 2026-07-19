import Foundation

/// PIPE sliding-window image upload (0x80 START / 0x81 DATA+SACK / 0x82 END). A faithful port of the
/// py-opendisplay sender (`device.py:_negotiate_pipe`/`_send_pipe_chunks`/`_await_pipe_end_ack`).
///
/// Flow: negotiate window/ack-cadence/frame/selective via 0x80 (min-rule against the device's grant),
/// stream 0x81 `[seq][data]` frames (seq = index mod 256, reset by START) up to the window, and process
/// the device's SACKs (`highest_seen` implicitly acked + a 32-bit mask of the chunks below it). Losses
/// below the highest received are retransmitted — selectively when the device granted selective-repeat,
/// else by rewinding the whole window. A stall triggers a PTO probe of the oldest unacked frame.
///
/// END rule: `explicitEnd = compressed || partial`. Uncompressed full-frame transfers auto-complete —
/// the device sends an unsolicited 0x82 END_ACK once `total_size` is reached and the client must NOT
/// send END. Compressed/partial transfers require an explicit 0x82 (carrying the refresh selector and,
/// for partial, the new etag BE).
@MainActor
struct PipeUploader {
    let router: ODNotificationRouter
    let transmit: (Data) async throws -> Void
    let encrypted: Bool

    /// Read timeouts (seconds). Defaults mirror py-opendisplay; tests inject small values to exercise
    /// the PTO/tail-flush paths without real waits.
    struct Timeouts { var start = 30.0; var compressedData = 5.0; var uncompressedData = 90.0; var tailFlush = 0.5; var endAck = 8.0 }
    var timeouts = Timeouts()

    /// Max consecutive PTO probes before giving up (py `MAX_PTO`).
    private static let maxPTO = 3

    /// Result of a negotiated START; nil from `negotiate` means "not a pipe device — fall back".
    struct Params {
        var window: Int          // W (frames in flight)
        var ackEvery: Int        // N (frames per SACK)
        var frameEff: Int        // effective on-wire frame size
        var selective: Bool      // selective-repeat vs full-rewind
        var partialAccepted: Bool
    }

    /// Optional partial-region extension for a partial pipe transfer (LE geometry).
    struct PartialRegion { var oldEtag: UInt32; var x: UInt16; var y: UInt16; var w: UInt16; var h: UInt16 }

    enum StartOutcome {
        case negotiated(Params)
        case retryUncompressed          // 0x02: device wants an uncompressed stream
        case fallback(ODProtocolError?) // any other rejection / timeout / garble → legacy path
    }

    // MARK: - START negotiation (0x80)

    /// Send a 0x80 START and parse the grant. `reqWindow`/`reqAckEvery` default to the client's request
    /// caps; `partial` appends the 12-byte LE region extension.
    func negotiate(totalSize: Int, compressed: Bool, partial: PartialRegion?,
                   reqWindow: Int = 32, reqAckEvery: Int = 8, reqFrame: Int = Int(PIPE_MAX_FRAME)) async throws -> StartOutcome {
        var flags: UInt8 = 0
        if compressed { flags |= PIPE_FLAG_COMPRESSED }
        if partial != nil { flags |= PIPE_FLAG_PARTIAL }
        var payload = PipeStartRequest(version: PIPE_VERSION, flags: flags,
                                       reqWindow: UInt8(reqWindow), reqAckEvery: UInt8(reqAckEvery),
                                       clientMaxFrame: UInt16(reqFrame), totalSize: UInt32(totalSize)).serialize()
        if let p = partial {
            payload += PipePartialExt(oldEtag: p.oldEtag, x: p.x, y: p.y, w: p.w, h: p.h).serialize()
        }

        let lo = UInt8(CMD_PIPE_WRITE_START & 0xFF)
        router.expectedOpcode = lo
        defer { router.expectedOpcode = nil }
        try await transmit(ODFrame.command(CMD_PIPE_WRITE_START, payload: payload))

        let note: ODFrame.Notification
        do {
            note = try await router.awaitNotification(operation: "pipeStart", timeout: timeouts.start) { $0.opcode == lo }
        } catch ODProtocolError.timeout {
            return .fallback(nil)   // no PIPE support (stale capability bit) → legacy
        }
        if note.status == 0xFF {
            let err = note.payload.first
            if err == OD_ERR_PIPE_START_UNKNOWN_FLAG { return .retryUncompressed }   // 0x02
            return .fallback(.deviceRejected(opcode: CMD_PIPE_WRITE_START, code: err))
        }
        guard note.status == 0x00, let resp = PipeStartResponse(bytes: note.payload) else {
            return .fallback(.malformedResponse("pipe START response"))
        }
        let window = max(1, min(reqWindow, Int(resp.maxWindow), 32))
        let ackEvery = max(1, min(reqAckEvery, Int(resp.maxAckEvery), window))
        let frameEff = min(reqFrame, Int(resp.maxFrame))
        return .negotiated(Params(window: window, ackEvery: ackEvery, frameEff: frameEff,
                                  selective: resp.respFlags & 0x01 != 0,
                                  partialAccepted: resp.respFlags & 0x02 != 0))
    }

    // MARK: - Data streaming (0x81) + END (0x82)

    /// Stream `wire` (already compressed if `compressed`) and finalize. Returns after the END-ACK; the
    /// refresh (0x73/0x74) flows to `onUnmatched` afterwards, like the direct-write path.
    func run(wire: Data, params: Params, compressed: Bool, partial: Bool,
             refresh: ODRefreshMode, newEtag: UInt32?,
             progress: ((ODUploadProgress) -> Void)?) async throws {
        let channel = PipeChannel()
        let previousUnmatched = router.onUnmatched
        router.frameSink = { note in
            // The uploader owns 0x81 (SACK/NACK) and 0x82 (END-ACK); refresh & strays go to onUnmatched.
            if note.opcode == UInt8(CMD_PIPE_WRITE_DATA & 0xFF) || note.opcode == UInt8(CMD_PIPE_WRITE_END & 0xFF) {
                channel.deliver(note)
            } else {
                previousUnmatched?(note)
            }
        }
        defer { router.frameSink = nil }

        let bytes = [UInt8](wire)
        let dataSize = ODChunkPolicy(encrypted: encrypted).pipeDataSize(frameEff: params.frameEff)
        let chunks = stride(from: 0, to: bytes.count, by: dataSize).map { Array(bytes[$0 ..< min($0 + dataSize, bytes.count)]) }
        let n = chunks.count
        let explicitEnd = compressed || partial
        let seqOpcode = UInt8(CMD_PIPE_WRITE_DATA & 0xFF)

        var acked = Set<Int>()
        var windowBase = 0
        var nextToSend = 0
        var ptoCount = 0
        var retxCount = 0
        let maxRetx = 3 * max(1, params.window)

        func sendFrame(_ absIndex: Int) async throws {
            let frame = ODFrame.command(CMD_PIPE_WRITE_DATA, payload: [UInt8(absIndex % 256)] + chunks[absIndex])
            try await transmit(frame)
        }
        func reportProgress() {
            let sent = min(windowBase, n) * dataSize
            progress?(ODUploadProgress(bytesSent: min(sent, bytes.count), bytesTotal: bytes.count, phase: .sending))
        }

        var autoCompleted = false
        streamLoop: while true {
            // 1. Fill the window.
            while nextToSend < n && (nextToSend - windowBase) < params.window {
                try await sendFrame(nextToSend)
                nextToSend += 1
            }
            // 2. Explicit-end transfers stop once everything is acked; the caller sends END.
            if windowBase >= n && explicitEnd { break }

            // 3. Read the next SACK/NACK/END-ACK (tail-flush uses a short timeout).
            let inTailFlush = explicitEnd && nextToSend >= n && (n - windowBase) < params.ackEvery
            let timeout: TimeInterval = inTailFlush ? timeouts.tailFlush : (compressed ? timeouts.compressedData : timeouts.uncompressedData)
            let note: ODFrame.Notification
            do {
                note = try await channel.next(timeout: timeout)
            } catch {
                if inTailFlush { break }                     // last group's SACK never came → go to END
                if windowBase >= n { break }                 // uncompressed auto-complete race → done
                // PTO: probe the oldest unacked frame.
                ptoCount += 1; retxCount += 1
                if ptoCount > Self.maxPTO || retxCount > maxRetx { throw ODProtocolError.timeout(operation: "pipeData") }
                try await sendFrame(windowBase)
                continue
            }

            // 4. NACK is fatal.
            if note.status == 0xFF {
                if note.opcode == UInt8(CMD_PIPE_WRITE_END & 0xFF) { throw ODProtocolError.deviceRejected(opcode: CMD_PIPE_WRITE_END, code: note.payload.first) }
                throw ODProtocolError.deviceRejected(opcode: CMD_PIPE_WRITE_DATA, code: note.payload.first)
            }
            // 5. Unsolicited END-ACK = uncompressed auto-complete.
            if note.opcode == UInt8(CMD_PIPE_WRITE_END & 0xFF) { autoCompleted = true; break }
            guard note.opcode == seqOpcode, let sack = PipeSack(bytes: note.payload) else { continue }

            // 6. Resolve the rolling SACK against the absolute window and merge.
            ptoCount = 0
            let baseMod = windowBase % 256
            var delta = (Int(sack.highestSeen) - baseMod + 256) % 256
            if delta > 128 { delta -= 256 }
            let hAbs = windowBase + delta
            if hAbs >= windowBase { acked.insert(hAbs) }
            for i in 0..<Int(PIPE_ACK_MASK_BITS) where (sack.ackMask >> UInt32(i)) & 1 == 1 {
                let seq = hAbs - 1 - i
                if seq >= windowBase { acked.insert(seq) }
            }
            while acked.contains(windowBase) { windowBase += 1 }
            reportProgress()

            // 7. Retransmit holes below the highest received.
            guard let highestRecv = acked.max() else { continue }
            let upper = min(highestRecv, nextToSend)
            let missing = upper > windowBase ? (windowBase ..< upper).filter { !acked.contains($0) } : []
            if params.selective {
                for m in missing {
                    retxCount += 1
                    if retxCount > maxRetx { throw ODProtocolError.timeout(operation: "pipeData") }
                    try await sendFrame(m)
                }
            } else if !missing.isEmpty {
                retxCount += 1
                if retxCount > maxRetx { throw ODProtocolError.timeout(operation: "pipeData") }
                nextToSend = windowBase   // full rewind
            }
        }

        progress?(ODUploadProgress(bytesSent: bytes.count, bytesTotal: bytes.count, phase: .sending))

        // 8. END. Uncompressed full-frame already auto-completed; explicit transfers send 0x82 now.
        if !autoCompleted && explicitEnd {
            var endPayload: [UInt8] = [refresh.rawValue]
            if let newEtag { endPayload += ODByteOrder.u32BE(newEtag) }
            router.expectedOpcode = UInt8(CMD_PIPE_WRITE_END & 0xFF)
            try await transmit(ODFrame.command(CMD_PIPE_WRITE_END, payload: endPayload))
            try await awaitEndAck(channel)
            router.expectedOpcode = nil
        }
        progress?(ODUploadProgress(bytesSent: bytes.count, bytesTotal: bytes.count, phase: .awaitingRefresh))
    }

    /// Await the 0x82 END-ACK, skipping any tail-flush SACKs that trail the END.
    private func awaitEndAck(_ channel: PipeChannel) async throws {
        for _ in 0..<33 {
            let note = try await channel.next(timeout: timeouts.endAck)
            if note.opcode == UInt8(CMD_PIPE_WRITE_END & 0xFF) {
                if note.status == 0xFF { throw ODProtocolError.deviceRejected(opcode: CMD_PIPE_WRITE_END, code: note.payload.first) }
                return
            }
            if note.status == 0xFF { throw ODProtocolError.deviceRejected(opcode: CMD_PIPE_WRITE_DATA, code: note.payload.first) }
            // else a trailing SACK — keep waiting for the END-ACK.
        }
        throw ODProtocolError.timeout(operation: "pipeEnd")
    }
}

/// A single-consumer inbox for PIPE frames: buffers notifications delivered by the router's `frameSink`
/// and hands them to the sender's `next(timeout:)`, which either returns a buffered frame immediately or
/// suspends (with a per-wait watchdog) until one arrives.
@MainActor
final class PipeChannel {
    private var buffer: [ODFrame.Notification] = []
    private var waiter: (CheckedContinuation<ODFrame.Notification, Error>, DispatchWorkItem)?

    func deliver(_ note: ODFrame.Notification) {
        if let (cont, timeout) = waiter {
            waiter = nil; timeout.cancel()
            cont.resume(returning: note)
        } else {
            buffer.append(note)
        }
    }

    func next(timeout: TimeInterval) async throws -> ODFrame.Notification {
        if !buffer.isEmpty { return buffer.removeFirst() }
        return try await withCheckedThrowingContinuation { cont in
            let work = DispatchWorkItem { [weak self] in
                guard let self, let (c, _) = self.waiter else { return }
                self.waiter = nil
                c.resume(throwing: ODProtocolError.timeout(operation: "pipeAwait"))
            }
            waiter = (cont, work)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }
}
