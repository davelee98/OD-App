import XCTest
@testable import ODProtocolKit

@MainActor
final class ConfigTransferTests: XCTestCase {

    func testReadReassemblesMultiChunkStream() async throws {
        let blob = Data((0..<250).map { UInt8($0 & 0xFF) })
        let link = MockLink()
        link.responder = { frame in
            guard frame.count >= 2, frame[1] == 0x40 else { return [] }
            let total = UInt16(blob.count)
            // chunk 0: 0040 | 0000 | total(LE) | first 200 ; chunk 1: 0040 | 0100 | last 50
            let chunk0 = Data([0x00, 0x40, 0x00, 0x00, UInt8(total & 0xFF), UInt8(total >> 8)]) + blob.prefix(200)
            let chunk1 = Data([0x00, 0x40, 0x01, 0x00]) + blob[200..<250]
            return [chunk0, chunk1]
        }
        let got = try await ODProtocolClient(link: link).readConfigBlob()
        XCTAssertEqual(got, blob)   // byte-identical blob handed to the toolbox engine
    }

    func testReadAuthRequired() async {
        let link = MockLink()
        link.responder = { f in (f.count >= 2 && f[1] == 0x40) ? [Data([0x00, 0x40, 0xFE])] : [] }
        do {
            _ = try await ODProtocolClient(link: link).readConfigBlob()
            XCTFail("expected authRequired")
        } catch ODProtocolError.authRequired {} catch { XCTFail("unexpected: \(error)") }
    }

    func testWriteChunkedWithSizeHeader() async throws {
        let blob = Data((0..<250).map { UInt8(($0 * 3) & 0xFF) })
        let link = MockLink()   // default echoes [00, opcode] ACK
        try await ODProtocolClient(link: link).writeConfigBlob(blob)

        XCTAssertEqual(link.sent.count, 2)
        // first: 0041 | total(u16 LE = 250 → FA 00) | first 200
        XCTAssertEqual(Array(link.sent[0].prefix(4)), [0x00, 0x41, 0xFA, 0x00])
        XCTAssertEqual([UInt8](link.sent[0].suffix(200)), [UInt8](blob.prefix(200)))
        // second: 0042 | last 50
        XCTAssertEqual(Array(link.sent[1].prefix(2)), [0x00, 0x42])
        XCTAssertEqual([UInt8](link.sent[1].dropFirst(2)), [UInt8](blob[200..<250]))
    }

    func testSmallWriteIsSingleCommandNoSizePrefix() async throws {
        let blob = Data([1, 2, 3, 4, 5])
        let link = MockLink()
        try await ODProtocolClient(link: link).writeConfigBlob(blob)
        XCTAssertEqual(link.sent, [Data([0x00, 0x41]) + blob])
    }

    func testWriteNackAborts() async {
        let link = MockLink()
        link.responder = { f in (f.count >= 2 && f[1] == 0x41) ? [Data([0xFF, 0x41, 0x09])] : [Data([0x00, f[1]])] }
        do {
            try await ODProtocolClient(link: link).writeConfigBlob(Data([1, 2, 3]))
            XCTFail("expected rejection")
        } catch ODProtocolError.deviceRejected(let op, let code) {
            XCTAssertEqual(op, CMD_CONFIG_WRITE); XCTAssertEqual(code, 0x09)
        } catch { XCTFail("unexpected: \(error)") }
    }
}
