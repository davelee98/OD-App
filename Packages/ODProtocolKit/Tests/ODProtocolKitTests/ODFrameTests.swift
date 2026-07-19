import XCTest
@testable import ODProtocolKit

final class ODFrameTests: XCTestCase {

    func testBuildCommand() {
        XCTAssertEqual(ODFrame.command(CMD_DIRECT_WRITE_START), Data([0x00, 0x70]))
        XCTAssertEqual(ODFrame.command(CMD_DIRECT_WRITE_DATA, payload: [0xAA, 0xBB]),
                       Data([0x00, 0x71, 0xAA, 0xBB]))
    }

    func testClassifyPreferredOrder() {
        let n = ODFrame.classify([0x00, 0x70, 0x01], expectedOpcode: 0x70)
        XCTAssertEqual(n?.status, 0x00); XCTAssertEqual(n?.opcode, 0x70); XCTAssertEqual(n?.payload, [0x01])
    }

    func testClassifySwappedOrder() {
        // Some firmware emits [opcode][status].
        let n = ODFrame.classify([0x70, 0x00], expectedOpcode: 0x70)
        XCTAssertEqual(n?.status, 0x00); XCTAssertEqual(n?.opcode, 0x70)
    }

    func testClassifyNack() {
        let n = ODFrame.classify([0xFF, 0x70, 0x05], expectedOpcode: 0x70)
        XCTAssertEqual(n?.status, 0xFF); XCTAssertEqual(n?.opcode, 0x70); XCTAssertEqual(n?.payload, [0x05])
    }

    func testClassifyAuthRequired() {
        let n = ODFrame.classify([0xFE, 0x40], expectedOpcode: 0x40)
        XCTAssertEqual(n?.status, 0xFE); XCTAssertEqual(n?.opcode, 0x40)
    }

    func testClassifyNackWithMismatchedExpectedStillSurfaces() {
        // An FF for a different opcode than expected must still be seen (so the upload can abort).
        let n = ODFrame.classify([0xFF, 0x70], expectedOpcode: 0x71)
        XCTAssertEqual(n?.status, 0xFF); XCTAssertEqual(n?.opcode, 0x70)
    }
}
