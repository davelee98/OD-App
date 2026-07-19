import XCTest
@testable import ODProtocolKit

@MainActor
final class DirectWriteUploadTests: XCTestCase {

    func testUncompressedWireSequence() async throws {
        let link = MockLink()
        let client = ODProtocolClient(link: link)
        let packed = Data((0..<500).map { UInt8($0 & 0xFF) })   // 3 chunks @230: 230,230,40

        var lastProgress = 0.0
        try await client.uploadImage(packed, modes: [], refresh: .full) { p in
            lastProgress = Double(p.bytesSent) / Double(max(1, p.bytesTotal))
        }

        XCTAssertEqual(link.sent.count, 5)                          // start + 3 data + end
        XCTAssertEqual(link.sent[0], Data([0x00, 0x70]))           // bare start (uncompressed)
        XCTAssertEqual(link.sent[1], Data([0x00, 0x71]) + packed.prefix(230))
        XCTAssertEqual(link.sent[2], Data([0x00, 0x71]) + packed[230..<460])
        XCTAssertEqual(link.sent[3], Data([0x00, 0x71]) + packed[460..<500])
        XCTAssertEqual(link.sent[4], Data([0x00, 0x72, 0x00]))     // end, refresh=full(0)
        XCTAssertEqual(lastProgress, 1.0, accuracy: 0.0001)
    }

    func testEndCarriesEtagWhenProvided() async throws {
        let link = MockLink()
        let client = ODProtocolClient(link: link)
        try await client.uploadImage(Data([1, 2, 3]), modes: [], refresh: .full, etag: 0xDEADBEEF)
        // end = 0072 | refresh(0) | etag BE
        XCTAssertEqual(link.sent.last, Data([0x00, 0x72, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testCompressedUploadReconstructs() async throws {
        let link = MockLink()
        let client = ODProtocolClient(link: link)
        let packed = Data((0..<1200).map { UInt8(($0 * 7) & 0xFF) })

        try await client.uploadImage(packed, modes: [.streamingDecompression], refresh: .full)

        // Start = 0070 | uncompressed_size(u32 LE) | leading compressed bytes.
        let start = [UInt8](link.sent[0])
        XCTAssertEqual(Array(start[0...1]), [0x00, 0x70])
        XCTAssertEqual(ODByteOrder.readU32LE(start, 2), UInt32(packed.count))

        // Reassemble all compressed bytes: start leading + every 0x71 chunk payload.
        var compressed = Array(start[6...])
        for frame in link.sent.dropFirst() where frame.count >= 2 && frame[1] == 0x71 {
            compressed += [UInt8](frame.dropFirst(2))
        }
        let inflated = try ODDeflate.inflate(Data(compressed), windowBits: 9)
        XCTAssertEqual(inflated, packed)
        XCTAssertEqual(link.sent.last, Data([0x00, 0x72, 0x00]))
    }

    func testTinyImageFitsEntirelyInStart() async throws {
        let link = MockLink()
        let client = ODProtocolClient(link: link)
        try await client.uploadImage(Data(repeating: 0x00, count: 16), modes: [.streamingDecompression])
        // A 16-byte all-zero frame compresses tiny → rides in the start; no 0x71 frames.
        XCTAssertFalse(link.sent.dropFirst().dropLast().contains { $0.count >= 2 && $0[1] == 0x71 })
        XCTAssertEqual(link.sent.first?.prefix(2), Data([0x00, 0x70]))
        XCTAssertEqual(link.sent.last, Data([0x00, 0x72, 0x00]))
    }

    func testDeviceNackAbortsUpload() async {
        let link = MockLink()
        link.responder = { frame in
            (frame.count >= 2 && frame[1] == 0x70) ? [Data([0xFF, 0x70, 0x01])] : [Data([0x00, frame[1]])]
        }
        let client = ODProtocolClient(link: link)
        do {
            try await client.uploadImage(Data([1, 2, 3]), modes: [])
            XCTFail("expected rejection")
        } catch let ODProtocolError.deviceRejected(opcode, code) {
            XCTAssertEqual(opcode, CMD_DIRECT_WRITE_START)
            XCTAssertEqual(code, 0x01)
        } catch { XCTFail("unexpected error: \(error)") }
    }
}
