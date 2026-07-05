import XCTest
@testable import OD_App

final class BLEChunkSizeTests: XCTestCase {
    /// `ODDevice.writeConfig` counts chunk ACKs natively (the firmware never sends the JS-level
    /// completion message), predicting the expected count from `OD.configWriteChunkSize`. If a
    /// vendored ble-common.js update ever changes `writeConfigChunked`'s chunking, that
    /// prediction silently breaks — writes would complete early or only via watchdog timeout.
    /// This pins the Swift constant to the bundled JS source.
    func testConfigWriteChunkSizeMatchesBundledJS() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ble-common", withExtension: "js"))
        let source = try String(contentsOf: url, encoding: .utf8)
        let functionStart = try XCTUnwrap(source.range(of: "writeConfigChunked"),
                                          "ble-common.js no longer defines writeConfigChunked")
        let match = try XCTUnwrap(source[functionStart.upperBound...].firstMatch(of: /const chunkSize = (\d+);/),
                                  "could not find the config write chunk size in ble-common.js")
        XCTAssertEqual(Int(match.1), OD.configWriteChunkSize)
    }
}
