import XCTest
@testable import ODProtocolKit

final class ODCRC16Tests: XCTestCase {
    /// The canonical CRC16-CCITT (poly 0x1021, init 0xFFFF, "FALSE" variant) check value for the
    /// ASCII string "123456789" is 0x29B1.
    func testKnownVector() {
        XCTAssertEqual(ODCRC16.compute([UInt8]("123456789".utf8)), 0x29B1)
    }

    func testUsesGeneratedConstants() {
        XCTAssertEqual(OD_CONFIG_CRC_POLY, 0x1021)
        XCTAssertEqual(OD_CONFIG_CRC_INIT, 0xFFFF)
    }
}
