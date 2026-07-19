import XCTest
@testable import ODProtocolKit

/// Legacy 0x76 partial transport + the client-level pipe→0x70 fallback.
@MainActor
final class PartialAndFallbackTests: XCTestCase {

    private func harness(_ link: MockLink) -> (PartialWriteUploader, ODNotificationRouter) {
        let router = ODNotificationRouter()
        link.onNotification = { router.receive($0) }
        let transmit: (Data) async throws -> Void = { data in
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                link.send(data) { err in err.map { c.resume(throwing: $0) } ?? c.resume() }
            }
        }
        let up = PartialWriteUploader(policy: ODChunkPolicy(encrypted: false), router: router,
                                      transmit: transmit, setExpectedOpcode: { router.expectedOpcode = $0 })
        return (up, router)
    }

    func testPartialStartHeaderIsBigEndianThenChunksAndEnd() async throws {
        let link = MockLink()   // default echoes [00][opcode] ACKs
        let (up, _) = harness(link)
        let stream = Data((0..<250).map { UInt8($0 & 0xFF) })
        try await up.run(flags: 0x01, oldEtag: 0x11223344, newEtag: 0x55667788,
                         rect: .init(x: 8, y: 16, width: 32, height: 24), stream: stream)

        // First frame: [00][76] + 17-byte BE header + leading stream.
        let start = [UInt8](link.sent[0])
        XCTAssertEqual(Array(start.prefix(2)), [0x00, 0x76])
        XCTAssertEqual(start[2], 0x01)                                   // flags
        XCTAssertEqual(Array(start[3..<7]), [0x11, 0x22, 0x33, 0x44])    // old_etag BE
        XCTAssertEqual(Array(start[7..<11]), [0x55, 0x66, 0x77, 0x88])   // new_etag BE
        XCTAssertEqual(Array(start[11..<13]), [0x00, 0x08])             // x BE
        XCTAssertEqual(Array(start[13..<15]), [0x00, 0x10])             // y BE
        XCTAssertEqual(Array(start[15..<17]), [0x00, 0x20])             // width BE
        XCTAssertEqual(Array(start[17..<19]), [0x00, 0x18])             // height BE

        // Last frame: [00][72][02] partial END.
        XCTAssertEqual([UInt8](link.sent.last!), [0x00, 0x72, ODRefreshMode.partial.rawValue])
        // The opcode sequence is 0x76 START, some 0x71 DATA, 0x72 END.
        let opcodes = link.sent.map { [UInt8]($0)[1] }
        XCTAssertEqual(opcodes.first, 0x76)
        XCTAssertTrue(opcodes.dropFirst().dropLast().allSatisfy { $0 == 0x71 })
    }

    func testPartialStartNackSurfacesPartialErrorCode() async {
        let link = MockLink()
        link.responder = { f in
            (f.count >= 2 && f[1] == 0x76) ? [Data([0xFF, 0x76, OD_ERR_PARTIAL_ETAG_MISMATCH, 0x00])]
                                           : [Data([0x00, f[1]])]
        }
        let (up, _) = harness(link)
        do {
            try await up.run(flags: 0, oldEtag: 1, newEtag: 2, rect: .init(x: 0, y: 0, width: 8, height: 8), stream: Data([1, 2, 3]))
            XCTFail("expected rejection")
        } catch ODProtocolError.deviceRejected(let op, let code) {
            XCTAssertEqual(op, CMD_PARTIAL_WRITE_START)
            XCTAssertEqual(code, OD_ERR_PARTIAL_ETAG_MISMATCH)
        } catch { XCTFail("unexpected: \(error)") }
    }

    /// A pipe-eligible upload whose 0x80 START is rejected must fall back to legacy 0x70 direct-write.
    func testPipeStartRejectFallsBackToDirectWrite() async throws {
        let link = MockLink()
        link.responder = { f in
            guard f.count >= 2 else { return [] }
            if f[1] == 0x80 { return [Data([0xFF, 0x80, OD_ERR_PIPE_START_BAD_HEADER, 0x00])] }   // reject pipe
            return [Data([0x00, f[1]])]   // ack 0x70/0x71/0x72
        }
        let client = ODProtocolClient(link: link)
        try await client.uploadImage(Data((0..<300).map { UInt8($0 & 0xFF) }),
                                     modes: [.pipeWrite], refresh: .full, etag: nil, progress: nil)
        let opcodes = link.sent.map { [UInt8]($0)[1] }
        XCTAssertEqual(opcodes.first, 0x80)                 // tried pipe first
        XCTAssertTrue(opcodes.contains(0x70))               // fell back to direct-write START
        XCTAssertEqual(opcodes.last, 0x72)                  // direct-write END
    }
}
