import XCTest
@testable import ODProtocolKit

final class ODDeflateTests: XCTestCase {

    /// The panel's streaming inflater has a 512-byte window, so the zlib header MUST advertise
    /// CINFO=1 (window 512) — header byte 0x18 (CMF: CM=8 low nibble, CINFO=1 high nibble).
    func testZlibHeaderIsWindow512() throws {
        let out = try ODDeflate.deflate(Data(repeating: 0xAB, count: 4096), level: 9, windowBits: 9)
        XCTAssertGreaterThanOrEqual(out.count, 2)
        XCTAssertEqual(out[0], 0x18, "CMF byte must be 0x18 (CM=8, CINFO=1 → 512-byte window)")
    }

    func testRoundTripWindow9() throws {
        for sample in [Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }),
                       Data(repeating: 0x00, count: 4000),
                       Data(repeating: 0xFF, count: 4000),
                       Data()] {
            let deflated = try ODDeflate.deflate(sample, level: 9, windowBits: 9)
            let inflated = try ODDeflate.inflate(deflated, windowBits: 9)
            XCTAssertEqual(inflated, sample)
        }
    }

    func testLevel6Deflates() throws {
        let sample = Data((0..<2000).map { UInt8($0 & 1) })
        let out = try ODDeflate.deflate(sample, level: 6, windowBits: 9)
        XCTAssertEqual(out[0], 0x18)
        XCTAssertEqual(try ODDeflate.inflate(out, windowBits: 9), sample)
    }
}
