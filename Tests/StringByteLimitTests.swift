import XCTest
@testable import OD_App

final class StringByteLimitTests: XCTestCase {
    func testAsciiUnderLimitIsUnchanged() {
        XCTAssertEqual("hello".prefixFittingUTF8Bytes(31), "hello")
    }

    func testAsciiExactFitIsUnchanged() {
        let value = String(repeating: "a", count: 31)
        XCTAssertEqual(value.prefixFittingUTF8Bytes(31), value)
    }

    func testAsciiOverLimitTruncates() {
        let value = String(repeating: "a", count: 40)
        XCTAssertEqual(value.prefixFittingUTF8Bytes(31), String(repeating: "a", count: 31))
    }

    func testTwoByteCharacterStraddlingBoundaryIsDroppedWhole() {
        // 30 ASCII bytes + "é" (2 bytes) = 32 bytes; a raw byte slice at 31 would cut the
        // "é" in half. The grapheme-safe prefix drops it entirely.
        let value = String(repeating: "a", count: 30) + "é"
        XCTAssertEqual(value.prefixFittingUTF8Bytes(31), String(repeating: "a", count: 30))
    }

    func testFourByteEmojiIsNeverSplit() {
        // 29 ASCII bytes + 😀 (4 bytes) = 33 bytes; bytes 30-31 would hold half the emoji.
        let value = String(repeating: "a", count: 29) + "😀"
        XCTAssertEqual(value.prefixFittingUTF8Bytes(31), String(repeating: "a", count: 29))
    }

    func testMultiScalarEmojiIsNeverSplit() {
        // Family ZWJ sequence: four 4-byte emoji joined by three 3-byte ZWJs = 25 bytes,
        // a single Character. It must be kept or dropped as one unit.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.utf8.count, 25)
        let value = "abc" + family
        XCTAssertEqual(value.prefixFittingUTF8Bytes(27), "abc")
        XCTAssertEqual(value.prefixFittingUTF8Bytes(28), value)
    }

    func testZeroLimitReturnsEmpty() {
        XCTAssertEqual("hello".prefixFittingUTF8Bytes(0), "")
    }
}
