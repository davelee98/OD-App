import XCTest
@testable import ODProtocolKit

/// Scripted PIPE device (an `ODLink`): answers 0x80 with a START grant, records 0x81 data seqs, and
/// emits SACKs keyed by arrival count (a dropped seq does not count as an arrival), so the sender's
/// retransmit logic is exercised deterministically — the same scenarios py-opendisplay's
/// `test_pipe_write_sender` uses. Responses are deferred to the next main-queue turn (the sender's
/// `PipeChannel` buffers them).
@MainActor
final class PipeDeviceLink: ODLink {
    var maximumWriteLength = 512
    var onNotification: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    // Negotiation grant.
    var startAckFlags: UInt8 = 0x01          // bit0 selective, bit1 partial
    var maxWindow = 32, maxAckEvery = 32, maxFrame = 244
    var startNackErr: UInt8?                 // if set, NACK the 0x80 START

    // Data behavior.
    var drops: Set<Int> = []                 // seqs dropped once (no arrival, no ack)
    var sackAt: [Int: [Int]] = [:]           // arrival# → received-set to SACK
    var autoCompleteAt: Int?                 // arrival# → emit unsolicited 0x82 END-ACK (uncompressed)
    var dataNackAt: Int?                     // arrival# → emit fatal 0x81 NACK
    var emitRefresh = true
    var endNack = false

    private(set) var sentSeqs: [Int] = []
    private(set) var startPayloads: [[UInt8]] = []
    private var arrivals = 0

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        completion(nil)
        let b = [UInt8](data)
        guard b.count >= 2 else { return }
        var out: [Data] = []
        switch b[1] {
        case UInt8(CMD_PIPE_WRITE_START & 0xFF):
            startPayloads.append(Array(b.dropFirst(2)))
            if let e = startNackErr { out = [Data([0xFF, 0x80, e, 0x00])] }
            else { out = [Data([0x00, 0x80, PIPE_VERSION, UInt8(maxWindow), UInt8(maxAckEvery),
                                UInt8(maxFrame & 0xFF), UInt8(maxFrame >> 8), startAckFlags])] }
        case UInt8(CMD_PIPE_WRITE_DATA & 0xFF):
            let seq = Int(b[2]); sentSeqs.append(seq)
            if drops.contains(seq) { drops.remove(seq); break }   // dropped
            arrivals += 1
            if dataNackAt == arrivals { out = [Data([0xFF, 0x81, 0x03, UInt8(seq % 256)] + ODByteOrder.u32LE(0))] }
            else {
                if let recv = sackAt[arrivals] { out = [sackFrame(recv)] }
                if autoCompleteAt == arrivals { out.append(Data([0x00, 0x82])) }
            }
        case UInt8(CMD_PIPE_WRITE_END & 0xFF):
            out = endNack ? [Data([0xFF, 0x82])] : [Data([0x00, 0x82])]
            if emitRefresh && !endNack { out.append(Data([0x00, 0x73])) }
        default: break
        }
        for d in out { DispatchQueue.main.async { [weak self] in self?.onNotification?(d) } }
    }

    func drop(_ error: Error?) { onDisconnect?(error) }

    private func sackFrame(_ recv: [Int]) -> Data {
        let hs = recv.max() ?? 0
        var mask: UInt32 = 0
        for i in 0..<32 where recv.contains(hs - 1 - i) { mask |= (UInt32(1) << UInt32(i)) }
        return Data([0x00, 0x81, UInt8(hs % 256)] + ODByteOrder.u32LE(mask))
    }
}

@MainActor
final class PipeUploaderTests: XCTestCase {

    /// Build an uploader wired to `link` with tiny timeouts and 1-byte data frames (frameEff 4).
    private func harness(_ link: PipeDeviceLink) -> (PipeUploader, ODNotificationRouter) {
        let router = ODNotificationRouter()
        link.onNotification = { router.receive($0) }
        let transmit: (Data) async throws -> Void = { data in
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                link.send(data) { err in err.map { c.resume(throwing: $0) } ?? c.resume() }
            }
        }
        var up = PipeUploader(router: router, transmit: transmit, encrypted: false)
        up.timeouts = .init(start: 1, compressedData: 0.3, uncompressedData: 0.3, tailFlush: 0.2, endAck: 1)
        return (up, router)
    }

    private let params = PipeUploader.Params(window: 4, ackEvery: 4, frameEff: 4, selective: true, partialAccepted: false)

    private func run(_ up: PipeUploader, _ wire: [UInt8], compressed: Bool, params: PipeUploader.Params? = nil) async throws {
        try await up.run(wire: Data(wire), params: params ?? self.params, compressed: compressed, partial: false,
                         refresh: .full, newEtag: nil, progress: nil)
    }

    func testInOrder() async throws {
        let link = PipeDeviceLink()
        link.sackAt = [1: [0], 2: [0, 1], 3: [0, 1, 2], 4: [0, 1, 2, 3]]
        let (up, _) = harness(link)
        try await run(up, [0, 1, 2, 3], compressed: true)   // explicit END
        XCTAssertEqual(link.sentSeqs, [0, 1, 2, 3])
    }

    func testGapSelectiveRepeat() async throws {
        let link = PipeDeviceLink()
        link.drops = [1]                       // seq 1 lost once
        link.sackAt = [3: [0, 2, 3], 4: [0, 1, 2, 3]]
        let (up, _) = harness(link)
        try await run(up, [0, 1, 2, 3], compressed: true)
        XCTAssertEqual(link.sentSeqs, [0, 1, 2, 3, 1])   // only seq 1 retransmitted
    }

    func testChaosFullRewind() async throws {
        let link = PipeDeviceLink()
        link.startAckFlags = 0x00              // selective NOT supported → rewind
        link.drops = [1]
        link.sackAt = [3: [0, 2, 3], 6: [0, 1, 2, 3]]
        let (up, _) = harness(link)
        var p = params; p.selective = false
        try await run(up, [0, 1, 2, 3], compressed: true, params: p)
        XCTAssertEqual(link.sentSeqs, [0, 1, 2, 3, 1, 2, 3])   // rewind to window base
    }

    func testUncompressedAutoComplete() async throws {
        let link = PipeDeviceLink()
        link.autoCompleteAt = 4                 // device finalizes; client must NOT send END
        let (up, _) = harness(link)
        try await run(up, [0, 1, 2, 3], compressed: false)
        XCTAssertEqual(link.sentSeqs, [0, 1, 2, 3])   // no explicit END frame is sent (auto-complete)
    }

    func testNackIsFatal() async {
        let link = PipeDeviceLink()
        link.dataNackAt = 2
        let (up, _) = harness(link)
        do { try await run(up, [0, 1, 2, 3], compressed: true); XCTFail("expected NACK") }
        catch ODProtocolError.deviceRejected(let op, _) { XCTAssertEqual(op, CMD_PIPE_WRITE_DATA) }
        catch { XCTFail("unexpected: \(error)") }
    }

    func testPTOResendsOldestUnacked() async throws {
        let link = PipeDeviceLink()
        // No SACK for the first burst → sender times out and PTO-probes window_base (seq 0).
        // ackEvery=1 keeps the 2-unacked case out of the tail-flush branch, so the timeout is a PTO.
        link.sackAt = [3: [0, 1]]               // ack after the PTO resend (arrival 3)
        let (up, _) = harness(link)
        var p = params; p.ackEvery = 1
        try await run(up, [0, 1], compressed: true, params: p)
        XCTAssertEqual(link.sentSeqs, [0, 1, 0])
    }

    func testNegotiateMinRule() async throws {
        let link = PipeDeviceLink()
        link.maxWindow = 8; link.maxAckEvery = 2; link.maxFrame = 200; link.startAckFlags = 0x03
        let (up, _) = harness(link)
        let outcome = try await up.negotiate(totalSize: 1000, compressed: true, partial: nil, reqWindow: 32, reqAckEvery: 8, reqFrame: 244)
        guard case .negotiated(let p) = outcome else { return XCTFail("expected negotiated") }
        XCTAssertEqual(p.window, 8)             // min(32, 8, 32)
        XCTAssertEqual(p.ackEvery, 2)           // min(8, 2, window)
        XCTAssertEqual(p.frameEff, 200)         // min(244, 200)
        XCTAssertTrue(p.selective && p.partialAccepted)
    }

    func testNegotiateUnknownFlagRetryUncompressed() async throws {
        let link = PipeDeviceLink()
        link.startNackErr = OD_ERR_PIPE_START_UNKNOWN_FLAG   // 0x02
        let (up, _) = harness(link)
        let outcome = try await up.negotiate(totalSize: 500, compressed: true, partial: nil)
        guard case .retryUncompressed = outcome else { return XCTFail("expected retryUncompressed") }
    }

    func testNegotiateHardRejectFallsBack() async throws {
        let link = PipeDeviceLink()
        link.startNackErr = OD_ERR_PIPE_START_SIZE_MISMATCH  // 0x03
        let (up, _) = harness(link)
        let outcome = try await up.negotiate(totalSize: 500, compressed: true, partial: nil)
        guard case .fallback = outcome else { return XCTFail("expected fallback") }
    }
}
