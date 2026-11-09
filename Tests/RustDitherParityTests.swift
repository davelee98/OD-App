import XCTest
@testable import OD_App

/// Proves the app's native dithering path (`RustDither` → `EpaperDithering` XCFramework → Rust
/// `epaper-dithering-core`) reproduces the Rust reference **byte-for-byte**, which is the entire
/// point of replacing the old sRGB-Euclidean Swift matcher with the shared OKLab core.
///
/// Fixtures (`Tests/Fixtures/`):
/// - `cat_800x480.rgb` — the exact RGB bytes the core's regression suite feeds in, exported via the
///   same `image` crate decode (so PNG-decode differences between Rust and iOS CGImage can't
///   confound the comparison — this isolates dithering parity).
/// - `cat__floyd_steinberg_mono_raw.bin` — the core's stored reference for the
///   `floyd_steinberg_mono_raw` suite: Floyd-Steinberg, monochrome palette, no tone/gamut,
///   serpentine (the `DitherConfig` default). This is exactly `RustDither`'s scope, so it must match
///   to the byte.
final class RustDitherParityTests: XCTestCase {

    private let width = 800
    private let height = 480

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw XCTSkip("missing fixture \(name).\(ext) in test bundle")
        }
        return try Data(contentsOf: url)
    }

    func testMonoFloydSteinbergMatchesRustReference() throws {
        let rgb = try fixture("cat_800x480", "rgb")
        let reference = try fixture("cat__floyd_steinberg_mono_raw", "bin")

        XCTAssertEqual(rgb.count, width * height * 3, "input RGB size")
        XCTAssertEqual(reference.count, width * height, "reference index count")

        // Monochrome palette in app/reference index order: 0 = black, 1 = white (PALETTE_MONO).
        let mono: [UInt8] = [0, 0, 0, 255, 255, 255]

        let indices = try RustDither.dither(
            rgb: [UInt8](rgb), width: width, height: height,
            palette: mono, mode: .floydSteinberg, serpentine: true
        )

        XCTAssertEqual(indices.count, reference.count)
        XCTAssertEqual(Data(indices), reference,
                       "native dither output must match the Rust reference byte-for-byte")
    }

    /// Sanity: a solid-red image against black/white/red maps every pixel to the red index,
    /// exercising the FFI end-to-end through the app wrapper with a tiny deterministic input.
    func testSolidColorMapsExactly() throws {
        let w = 4, h = 4
        let rgb = [UInt8](repeating: 0, count: w * h * 3).enumerated().map { i, _ in
            i % 3 == 0 ? UInt8(255) : UInt8(0)   // R=255, G=0, B=0
        }
        let palette: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 0, 0] // black, white, red
        let indices = try RustDither.dither(
            rgb: rgb, width: w, height: h, palette: palette, mode: .burkes
        )
        XCTAssertEqual(indices, [UInt8](repeating: 2, count: w * h))
    }

    /// The vendored framework must be the options-struct ABI this wrapper calls.
    func testFrameworkABIVersion() {
        XCTAssertEqual(RustDither.abiVersion, 2)
    }

    /// DBS through the app wrapper: valid indices, different from plain diffusion, and
    /// deterministic (same input → same output, despite the core's parallel tiles).
    func testRefinementChangesOutputDeterministically() throws {
        let w = 48, h = 32
        var rgb = [UInt8](); rgb.reserveCapacity(w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let v = UInt8((x + y) * 255 / (w + h - 2))
            rgb += [v, v / 2, 255 - v]
        } }
        let palette: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 0, 0] // black, white, red
        let refinement = RustDither.Refinement.coreDefault
        let plain = try RustDither.dither(rgb: rgb, width: w, height: h, palette: palette, mode: .burkes)
        let refined = try RustDither.dither(rgb: rgb, width: w, height: h, palette: palette,
                                            mode: .burkes, refinement: refinement)
        let again = try RustDither.dither(rgb: rgb, width: w, height: h, palette: palette,
                                          mode: .burkes, refinement: refinement)
        XCTAssertEqual(refined.count, w * h)
        XCTAssertTrue(refined.allSatisfy { $0 < 3 })
        XCTAssertNotEqual(refined, plain)
        XCTAssertEqual(refined, again)
    }

    func testRefinementDefaultsAndPanelPPI() {
        let d = RustDither.Refinement.coreDefault
        XCTAssertGreaterThan(d.maxPasses, 0)
        XCTAssertGreaterThan(d.viewingDistanceCm, 0)
        XCTAssertGreaterThan(d.ppi, 0)
        // 800 px across 163 mm (7.3" panel) ≈ 124.7 ppi.
        XCTAssertEqual(RustDither.Refinement.panelPPI(pixelWidth: 800, activeWidthMM: 163) ?? 0, 124.66, accuracy: 0.01)
        XCTAssertNil(RustDither.Refinement.panelPPI(pixelWidth: 800, activeWidthMM: 0))
        XCTAssertEqual(RustDither.Refinement.forPanel(pixelWidth: 800, activeWidthMM: 0).ppi, d.ppi)
    }
}
