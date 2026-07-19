import XCTest
@testable import OD_App

/// Locks the app's use of the generated `ColorScheme` (from `Generated/opendisplay_structs.swift`)
/// after retiring the app's hand-rolled enum. Guards the composer's color-mode picker against the
/// generated enum gaining cases (it already carries `sevenColor`/`bwgbrySplit`/RGB modes the app
/// doesn't compose for) and against the display names / wire codes drifting.
final class ColorSchemeTests: XCTestCase {

    func testAppSupportedAreExactlyTheEpaperCodes0Through6() {
        // The composer offers only the e-paper modes ImageProcessor can dither+pack (raw codes 0…6).
        XCTAssertEqual(ColorScheme.appSupported.map { $0.rawValue }, [0, 1, 2, 3, 4, 5, 6])
        // Non-epaper / unsupported cases must NOT be offered.
        for excluded in [ColorScheme.sevenColor, .bwgbrySplit, .rgb565, .rgb888, .rgb16bpc] {
            XCTAssertFalse(ColorScheme.appSupported.contains(excluded), "\(excluded) should not be pickable")
        }
    }

    func testDisplayNamesMatchTheFormerHandRolledEnum() {
        XCTAssertEqual(ColorScheme.mono.displayName,   "Black & White")
        XCTAssertEqual(ColorScheme.bwr.displayName,    "B/W + Red")
        XCTAssertEqual(ColorScheme.bwy.displayName,    "B/W + Yellow")
        XCTAssertEqual(ColorScheme.bwry.displayName,   "B/W + Red + Yellow")
        XCTAssertEqual(ColorScheme.bwgbry.displayName, "6-Color")
        XCTAssertEqual(ColorScheme.gray4.displayName,  "4-Grayscale")
        XCTAssertEqual(ColorScheme.gray16.displayName, "16-Grayscale")
    }

    func testRawValueReconstructionMatchesPersistedCodes() {
        // ContentView rebuilds the scheme from a persisted UInt8 code (SavedDisplayEntity.colorScheme).
        XCTAssertEqual(ColorScheme(rawValue: 0), .mono)
        XCTAssertEqual(ColorScheme(rawValue: 4), .bwgbry)
        XCTAssertEqual(ColorScheme(rawValue: 6), .gray16)
        XCTAssertNil(ColorScheme(rawValue: 200), "an unknown code must return nil, not crash")
    }
}
