import XCTest
@testable import OD_App

/// Validates the Swift tone-compression port against the epaper-dithering Rust reference
/// (`packages/rust/core/src/tone_map.rs`, `compress_dynamic_range` + its unit tests).
final class ToneCompressionTests: XCTestCase {

    // Pre-computed linear luminance of the measured palette endpoints (Rec.709 coefficients).
    // SPECTRA_7_3_6COLOR (colorScheme 4): black [26,13,35], white [185,202,205].
    private let spectraBlackY = 0.00628823
    private let spectraWhiteY = 0.56962313
    // MONO_4_26 (colorScheme 0): black [5,5,5], white [220,220,220].
    private let monoWhiteY = 0.71569357

    private func luminance(of rgb: (Double, Double, Double)) -> Double {
        ImageProcessor.luminance(rgb.0, rgb.1, rgb.2)
    }

    /// Convenience: run the buffer wrapper on a single sRGB pixel and read back the linear luminance.
    private func compressedLuminance(srgb: (Float, Float, Float), scheme: UInt8, strength: Double) -> Double {
        var pixels: [Float] = [srgb.0, srgb.1, srgb.2]
        ImageProcessor.compressDynamicRange(&pixels, colorScheme: scheme, strength: strength)
        return luminance(of: (ImageProcessor.srgbToLinear(Double(pixels[0]) / 255),
                              ImageProcessor.srgbToLinear(Double(pixels[1]) / 255),
                              ImageProcessor.srgbToLinear(Double(pixels[2]) / 255)))
    }

    // MARK: - Reference anchors

    func testStrengthZeroIsIdentity() {
        var pixels: [Float] = [255, 128, 0, 64, 200, 33]
        let original = pixels
        ImageProcessor.compressDynamicRange(&pixels, colorScheme: 4, strength: 0)
        XCTAssertEqual(pixels, original)
    }

    func testWhiteMapsToDisplayWhite() {
        // White at full strength compresses to exactly the display's white luminance.
        let y = compressedLuminance(srgb: (255, 255, 255), scheme: 4, strength: 1)
        XCTAssertEqual(y, spectraWhiteY, accuracy: 1e-4)
    }

    func testBlackMapsToDisplayBlack() {
        let y = compressedLuminance(srgb: (0, 0, 0), scheme: 4, strength: 1)
        XCTAssertEqual(y, spectraBlackY, accuracy: 1e-4)
    }

    func testMonoSchemeWhite() {
        let y = compressedLuminance(srgb: (255, 255, 255), scheme: 0, strength: 1)
        XCTAssertEqual(y, monoWhiteY, accuracy: 1e-4)
    }

    // MARK: - Per-pixel core (Double precision, tighter tolerance)

    func testPixelCoreWhiteFullStrength() {
        // The Rec.709 coefficients sum to 1.0000001, so white round-trips a few 1e-8 off the constant.
        let out = ImageProcessor.toneMapPixel((1, 1, 1),
                                              blackY: spectraBlackY, whiteY: spectraWhiteY, strength: 1)
        XCTAssertEqual(luminance(of: out), spectraWhiteY, accuracy: 1e-6)
    }

    func testPixelCoreMidtoneAnchor() {
        // Linear (0.8, 0.4, 0.2), strength 0.5, SPECTRA range. Independently derived from the Rust formula:
        //   y = 0.47063420, target_y = 0.37102355, scale = target_y / y → per-channel.
        let out = ImageProcessor.toneMapPixel((0.8, 0.4, 0.2),
                                              blackY: spectraBlackY, whiteY: spectraWhiteY, strength: 0.5)
        XCTAssertEqual(out.0, 0.63067843, accuracy: 1e-6)
        XCTAssertEqual(out.1, 0.31533922, accuracy: 1e-6)
        XCTAssertEqual(out.2, 0.15766961, accuracy: 1e-6)
    }

    func testNearBlackPreservesHue() {
        // A very dim blue-dominant pixel (luminance below the 1e-6 branch threshold) keeps blue dominant.
        let out = ImageProcessor.toneMapPixel((1e-8, 1e-8, 5e-7),
                                              blackY: spectraBlackY, whiteY: spectraWhiteY, strength: 1)
        XCTAssertGreaterThan(out.2, out.0)
        XCTAssertGreaterThan(out.2, out.1)
    }
}
