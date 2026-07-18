import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Image Adjustments

/// Intuitive photo adjustments applied *before* dithering. Every field is neutral at its default,
/// so `.neutral` passes an image through unchanged. High-contrast, dithered e-ink output benefits
/// measurably from tonal recovery (shadows/highlights), gentle brightness/contrast, and — on color
/// panels — saturation. Equatable so a single SwiftUI `.onChange` can drive the live canvas refresh.
struct ImageAdjustments: Equatable {
    var brightness: Float = 0     // CIColorControls.brightness             slider -0.4...0.4
    var contrast:   Float = 1     // CIColorControls.contrast               slider 0.5...1.5
    var shadows:    Float = 0     // CIHighlightShadowAdjust.shadowAmount   slider -1...1
    var highlights: Float = 1     // CIHighlightShadowAdjust.highlightAmount slider 0.3...1 (1 = neutral)
    var saturation: Float = 1     // CIColorControls.saturation             slider 0...2 (color schemes only)
    var toneCompression: Float = 0 // dynamic-range compression toward the panel's measured range 0...1 (0 = off)
    static let neutral = ImageAdjustments()
    var isNeutral: Bool { self == .neutral }

    /// Whether any *Core Image* adjustment differs from neutral. Tone compression is applied by a
    /// separate CPU pass (not Core Image), so a tone-only change should skip the CI filters entirely.
    var hasCoreImageAdjustments: Bool {
        brightness != 0 || contrast != 1 || shadows != 0 || highlights != 1 || saturation != 1
    }
}

// MARK: - Dithering Mode

enum DitheringMode: String, CaseIterable, Identifiable {
    case none              = "none"
    case floydSteinberg    = "floyd-steinberg"
    case atkinson          = "atkinson"
    case stucki            = "stucki"
    case sierra            = "sierra"
    case sierraLite        = "sierra-lite"
    case burkes            = "burkes"
    case jarvis            = "jarvis-judice-ninke"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none:           return "None"
        case .floydSteinberg: return "Floyd-Steinberg"
        case .atkinson:       return "Atkinson"
        case .stucki:         return "Stucki"
        case .sierra:         return "Sierra"
        case .sierraLite:     return "Sierra Lite"
        case .burkes:         return "Burkes"
        case .jarvis:         return "Jarvis-Judice-Ninke"
        }
    }
}

// MARK: - Colour Palettes (0-255 per channel)

enum ImageProcessor {

    typealias RGB = (r: Float, g: Float, b: Float)

    static let palettes: [UInt8: [RGB]] = [
        0: [(0,0,0), (255,255,255)],                                         // B/W
        1: [(0,0,0), (255,255,255), (255,0,0)],                              // B/W+Red
        2: [(0,0,0), (255,255,255), (255,255,0)],                            // B/W+Yellow
        3: [(0,0,0), (255,255,255), (255,255,0), (255,0,0)],                 // B/W+Y+R (wire: 0=black,1=white,2=yellow,3=red)
        4: [(0,0,0), (255,255,255), (0,255,0), (0,0,255), (255,0,0), (255,255,0)],  // 6-color
        5: [(0,0,0), (85,85,85), (170,170,170), (255,255,255)],              // 4-gray
        6: Array((0..<16).map { i -> RGB in let v = Float(i * 17); return (v,v,v) }),  // 16-gray
    ]

    /// Photographically *measured* display ink colors, index-aligned to `palettes` (the wire contract).
    /// Sourced from epaper-dithering `measured_palettes.rs`, reordered to the app's wire index order.
    /// Used only when the user enables the "Measured palette" switch — real e-paper black is not 0 and
    /// white is a dull gray-cyan, which is what makes tone compression meaningful. Schemes 5/6 have no
    /// measured data, so they lerp in sRGB between the MONO black/white endpoints (only the mid colors
    /// are approximated; tone compression reads only indices 0 and 1).
    static let measuredPalettes: [UInt8: [RGB]] = [
        0: [(5,5,5), (220,220,220)],                                          // MONO_4_26
        1: [(5,5,5), (200,200,200), (120,15,5)],                              // B/W+Red   (HANSHOW/SOLUM_BWR)
        2: [(5,5,5), (200,200,200), (200,180,0)],                             // B/W+Yellow (HANSHOW_BWY)
        3: [(5,5,5), (200,200,200), (200,180,0), (120,15,5)],                 // B/W+Y+R   (BWRY_4_2, app order b,w,y,r)
        4: [(26,13,35), (185,202,205), (40,82,57), (0,69,139), (121,9,0), (202,184,0)],
                                                                              // 6-color   (SPECTRA_7_3_6COLOR, app order k,w,g,b,r,y)
        5: Array((0..<4).map { i -> RGB in let v = Float(5) + Float(i) * (220 - 5) / 3; return (v,v,v) }),   // 4-gray
        6: Array((0..<16).map { i -> RGB in let v = Float(5) + Float(i) * (220 - 5) / 15; return (v,v,v) }), // 16-gray
    ]

    static func expectedPackedByteCount(width: Int, height: Int, colorScheme: UInt8) -> Int {
        let pixels = width * height
        switch colorScheme {
        case 0: return (pixels + 7) / 8
        case 1, 2, 5: return ((width + 7) / 8) * height * 2
        case 3: return (pixels + 3) / 4
        case 4, 6: return (pixels + 1) / 2
        default: return (pixels + 7) / 8
        }
    }

    // MARK: - Preview (apply dithering to UIImage for display)

    static func preview(image: UIImage, width: Int, height: Int,
                        colorScheme: UInt8, dithering: DitheringMode,
                        useMeasuredPalette: Bool = false, toneCompression: Double = 0) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let palette = (useMeasuredPalette ? measuredPalettes[colorScheme] : nil)
                    ?? palettes[colorScheme] ?? palettes[0]!
        var pixels = rgbaPixels(from: cgImage, width: width, height: height)
        var floatPixels = toFloat(pixels, count: width * height)
        if useMeasuredPalette {
            compressDynamicRange(&floatPixels, colorScheme: colorScheme, strength: toneCompression)
        }
        guard let indexed = ditherIndices(floatPixels, width: width, height: height, palette: palette, mode: dithering) else { return nil }
        // Map indices back to palette RGB and write into pixels
        for i in 0..<(width * height) {
            let (r, g, b) = palette[indexed[i]]
            pixels[i * 4 + 0] = UInt8(r)
            pixels[i * 4 + 1] = UInt8(g)
            pixels[i * 4 + 2] = UInt8(b)
            pixels[i * 4 + 3] = 255
        }
        return uiImage(from: pixels, width: width, height: height)
    }

    /// Runs the dithering pipeline **once** and returns both the packed wire bytes (for upload) and a
    /// dithered UIImage (for on-screen preview) — so the Composer can show what the panel will display
    /// without paying for the dither twice. Equivalent to calling `process` and `preview` back to back.
    static func processWithPreview(image: UIImage, width: Int, height: Int,
                                   colorScheme: UInt8, dithering: DitheringMode,
                                   useMeasuredPalette: Bool = false, toneCompression: Double = 0)
        -> (packed: Data, preview: UIImage)? {
        guard let cgImage = image.cgImage else { return nil }
        let palette = (useMeasuredPalette ? measuredPalettes[colorScheme] : nil)
                    ?? palettes[colorScheme] ?? palettes[0]!

        var pixels = rgbaPixels(from: cgImage, width: width, height: height)
        guard !pixels.isEmpty else { return nil }

        var floatPixels = toFloat(pixels, count: width * height)
        if useMeasuredPalette {
            compressDynamicRange(&floatPixels, colorScheme: colorScheme, strength: toneCompression)
        }
        guard let indexed = ditherIndices(floatPixels, width: width, height: height, palette: palette, mode: dithering) else { return nil }

        let packed = pack(indexed, scheme: colorScheme, width: width, height: height)

        // Map indices back to palette RGB for the preview image.
        for i in 0..<(width * height) {
            let (r, g, b) = palette[indexed[i]]
            pixels[i * 4 + 0] = UInt8(r)
            pixels[i * 4 + 1] = UInt8(g)
            pixels[i * 4 + 2] = UInt8(b)
            pixels[i * 4 + 3] = 255
        }
        guard let preview = uiImage(from: pixels, width: width, height: height) else { return nil }
        return (packed, preview)
    }

    // MARK: - Adjustments (Core Image)

    private static let ciContext = CIContext(options: nil)

    /// Apply intuitive photo adjustments *before* dithering. `.neutral` (all fields at their default)
    /// passes the image through unchanged. Filter order is tonal recovery → color:
    /// **CIHighlightShadowAdjust → CIColorControls**. High-contrast, dithered e-ink
    /// panels benefit from these before quantization.
    static func adjust(_ image: UIImage, adjustments: ImageAdjustments) -> UIImage {
        guard adjustments.hasCoreImageAdjustments, let cgImage = image.cgImage else { return image }
        let extent = CIImage(cgImage: cgImage).extent
        var ci = CIImage(cgImage: cgImage)

        // 1. Tonal recovery — pull up shadows / roll off highlights.
        if adjustments.shadows != 0 || adjustments.highlights != 1 {
            let hs = CIFilter.highlightShadowAdjust()
            hs.inputImage = ci
            hs.shadowAmount = adjustments.shadows
            hs.highlightAmount = adjustments.highlights
            ci = hs.outputImage ?? ci
        }

        // 2. Color — brightness / contrast / saturation.
        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = ci
            colorControls.brightness = adjustments.brightness
            colorControls.contrast = adjustments.contrast
            colorControls.saturation = adjustments.saturation
            ci = colorControls.outputImage ?? ci
        }

        // Crop back to the original extent — CIHighlightShadowAdjust can expand it, and
        // packing depends on exact pixel dimensions.
        guard let out = ciContext.createCGImage(ci, from: extent) else { return image }
        return UIImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Tone Compression (dynamic-range compression)

    /// sRGB IEC 61966-2-1 electro-optical transfer (gamma → linear). Port of `color_space.rs`.
    static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Inverse of `srgbToLinear` (linear → gamma).
    static func linearToSrgb(_ l: Double) -> Double {
        l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1.0 / 2.4) - 0.055
    }

    /// Rec.709 / sRGB linear luminance coefficients (tone_map.rs).
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    }

    /// Linear luminance of a palette entry (sRGB 0-255).
    private static func linearLuminance(_ c: RGB) -> Double {
        luminance(srgbToLinear(Double(c.r) / 255),
                  srgbToLinear(Double(c.g) / 255),
                  srgbToLinear(Double(c.b) / 255))
    }

    /// Fixed-strength dynamic-range compression of a single linear-RGB pixel toward the display's
    /// `[blackY, whiteY]` luminance range. Formula-for-formula port of `compress_dynamic_range`
    /// (epaper-dithering tone_map.rs:121-161); Double throughout for exactness.
    static func toneMapPixel(_ rgb: (Double, Double, Double),
                             blackY: Double, whiteY: Double, strength: Double) -> (Double, Double, Double) {
        var (r, g, b) = rgb
        let displayRange = whiteY - blackY
        let y = luminance(r, g, b)
        let compressedY = blackY + y * displayRange
        let targetY = y + strength * (compressedY - y)
        if y > 1e-6 {
            let scale = min(max(targetY / y, 0), 1e6)
            r = min(max(r * scale, 0), 1); g = min(max(g * scale, 0), 1); b = min(max(b * scale, 0), 1)
        } else {
            // Near-black: preserve channel ratios, scaling the brightest channel toward blackY·strength.
            let blendedBlack = blackY * strength
            let maxCh = max(r, max(g, b))
            if maxCh > 1e-12 {
                let scale = blendedBlack / maxCh
                r = min(max(r * scale, 0), 1); g = min(max(g * scale, 0), 1); b = min(max(b * scale, 0), 1)
            } else {
                r = blendedBlack; g = blendedBlack; b = blendedBlack
            }
        }
        return (r, g, b)
    }

    /// Apply tone compression across the app's interleaved float RGB planes (sRGB 0-255). Converts each
    /// pixel to linear, remaps via `toneMapPixel`, and converts back — keeping float precision (no u8
    /// round-trip). No-op unless `strength > 0` and a measured palette exists with positive range.
    static func compressDynamicRange(_ pixels: inout [Float], colorScheme: UInt8, strength: Double) {
        guard strength > 0, let pal = measuredPalettes[colorScheme], pal.count >= 2 else { return }
        let blackY = linearLuminance(pal[0])
        let whiteY = linearLuminance(pal[1])
        guard whiteY - blackY > 0 else { return }
        let n = pixels.count / 3
        for i in 0..<n {
            let lin = (srgbToLinear(Double(pixels[i*3+0]) / 255),
                       srgbToLinear(Double(pixels[i*3+1]) / 255),
                       srgbToLinear(Double(pixels[i*3+2]) / 255))
            let (r, g, b) = toneMapPixel(lin, blackY: blackY, whiteY: whiteY, strength: strength)
            pixels[i*3+0] = Float(linearToSrgb(r) * 255)
            pixels[i*3+1] = Float(linearToSrgb(g) * 255)
            pixels[i*3+2] = Float(linearToSrgb(b) * 255)
        }
    }

    /// Live-canvas convenience: apply tone compression to a whole UIImage (for the on-screen preview).
    /// The final send re-derives compression inside `process`, so this is a display-only approximation.
    static func compressTone(_ image: UIImage, colorScheme: UInt8, strength: Double) -> UIImage {
        guard strength > 0, let cgImage = image.cgImage else { return image }
        let w = cgImage.width, h = cgImage.height
        var pixels = rgbaPixels(from: cgImage, width: w, height: h)
        guard !pixels.isEmpty else { return image }
        var floatPixels = toFloat(pixels, count: w * h)
        compressDynamicRange(&floatPixels, colorScheme: colorScheme, strength: strength)
        for i in 0..<(w * h) {
            pixels[i*4+0] = UInt8(min(max(floatPixels[i*3+0], 0), 255))
            pixels[i*4+1] = UInt8(min(max(floatPixels[i*3+1], 0), 255))
            pixels[i*4+2] = UInt8(min(max(floatPixels[i*3+2], 0), 255))
        }
        return uiImage(from: pixels, width: w, height: h) ?? image
    }

    // MARK: - Pixel Helpers

    private static func rgbaPixels(from cgImage: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels,
                                  width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func uiImage(from pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        var mutable = pixels
        guard let ctx = CGContext(data: &mutable, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func toFloat(_ pixels: [UInt8], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * 3)
        for i in 0..<count {
            out[i*3+0] = Float(pixels[i*4+0])
            out[i*3+1] = Float(pixels[i*4+1])
            out[i*3+2] = Float(pixels[i*4+2])
        }
        return out
    }

    // MARK: - Dithering

    /// Dither interleaved float sRGB planes (0-255) to palette indices via the Rust core
    /// (`RustDither` → `EpaperDithering` XCFramework). OKLab matching, so output is identical to
    /// the website / Python / firmware reference. Pixels are expected to be already pre-processed
    /// (tone compression, if any, has run in `compressDynamicRange` upstream).
    ///
    /// Returns `nil` if the FFI reports failure — which cannot happen for the validated inputs this
    /// method always passes (correct dimensions, a ≥2-color palette). There is deliberately no Swift
    /// fallback: the old sRGB-Euclidean matcher produced website-divergent output, so silently
    /// substituting it would reintroduce the exact drift this replaced. A failure is logged and
    /// propagated as `nil` (callers return `nil` / no image) rather than shipping wrong pixels.
    private static func ditherIndices(_ pixels: [Float], width: Int, height: Int,
                                      palette: [RGB], mode: DitheringMode) -> [Int]? {
        let n = width * height
        // Interleaved float sRGB (0-255) → clamped/rounded UInt8 RGB.
        var rgb = [UInt8](repeating: 0, count: n * 3)
        for i in 0..<(n * 3) {
            rgb[i] = UInt8(min(max(pixels[i].rounded(), 0), 255))
        }
        // Palette RGB floats → flat UInt8 bytes, in the app's wire index order.
        var palBytes = [UInt8](repeating: 0, count: palette.count * 3)
        for (i, c) in palette.enumerated() {
            palBytes[i * 3 + 0] = UInt8(min(max(c.r.rounded(), 0), 255))
            palBytes[i * 3 + 1] = UInt8(min(max(c.g.rounded(), 0), 255))
            palBytes[i * 3 + 2] = UInt8(min(max(c.b.rounded(), 0), 255))
        }
        do {
            let idx = try RustDither.dither(rgb: rgb, width: width, height: height,
                                            palette: palBytes, mode: mode)
            return idx.map { Int($0) }
        } catch {
            ODLog.imaging.error("RustDither failed: \(String(describing: error), privacy: .public)")
            assertionFailure("RustDither failed for validated inputs: \(error)")
            return nil
        }
    }

    // MARK: - Wire Format Packing

    private static func pack(_ indexed: [Int], scheme: UInt8, width: Int, height: Int) -> Data {
        switch scheme {
        case 0:        return pack1bpp(indexed)
        case 1:        return pack2planes(indexed, redIdx: 2, yellowIdx: nil, width: width, height: height)
        case 2:        return pack2planes(indexed, redIdx: nil, yellowIdx: 2, width: width, height: height)
        case 3:        return pack2bpp(indexed)
        case 4:        return pack6color(indexed)
        case 5:        return packGray4(indexed, width: width, height: height)
        case 6:        return pack4bpp(indexed)
        default:       return pack1bpp(indexed)
        }
    }

    // 1 bpp: 0=black, 1=white, MSB first
    private static func pack1bpp(_ indexed: [Int]) -> Data {
        var out = Data(count: (indexed.count + 7) / 8)
        for (i, v) in indexed.enumerated() {
            if v != 0 { out[i / 8] |= UInt8(0x80 >> (i % 8)) }
        }
        return out
    }

    // 2 bitplanes (B/W + colour), row-padded so each row starts on a byte boundary
    private static func pack2planes(_ indexed: [Int], redIdx: Int?, yellowIdx: Int?, width: Int, height: Int) -> Data {
        let bytesPerRow = (width + 7) / 8
        let planeSize = bytesPerRow * height
        var out = Data(count: planeSize * 2)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard i < indexed.count else { continue }
                let v = indexed[i]
                let byteIdx = y * bytesPerRow + (x >> 3)
                let mask = UInt8(0x80 >> (x & 7))
                // plane1 (BW): white (v==1) or red; yellow does NOT set this plane
                if v == 1 || (redIdx != nil && v == redIdx) { out[byteIdx] |= mask }
                // plane2 (colour): red or yellow
                if v == redIdx || v == yellowIdx { out[planeSize + byteIdx] |= mask }
            }
        }
        return out
    }

    // 2 bpp packed: 4 pixels/byte, MSB first (scheme 3: B/W+R+Y)
    private static func pack2bpp(_ indexed: [Int]) -> Data {
        var out = Data(count: (indexed.count + 3) / 4)
        for (i, v) in indexed.enumerated() {
            let shift = (3 - (i % 4)) * 2
            out[i / 4] |= UInt8((v & 0x03) << shift)
        }
        return out
    }

    // 6-color nibble packing (scheme 4): palette index → wire color code
    // Palette: [black(0), white(1), green(2), blue(3), red(4), yellow(5)]
    // Wire:     black=0,  white=1,  yellow=2, red=3,   blue=5, green=6
    private static let scheme4Remap: [UInt8] = [0, 1, 6, 5, 3, 2]
    private static func pack6color(_ indexed: [Int]) -> Data {
        var out = Data(count: (indexed.count + 1) / 2)
        for (i, v) in indexed.enumerated() {
            let val = scheme4Remap[min(v, scheme4Remap.count - 1)]
            if i % 2 == 0 { out[i / 2] |= val << 4 }
            else           { out[i / 2] |= val }
        }
        return out
    }

    // 4-gray (scheme 5): two concatenated 1bpp planes, gray level mapped via LUT.
    // GRAY4_LUT: level(0=black..3=white) → stored code; bit0→plane0, bit1→plane1.
    private static func packGray4(_ indexed: [Int], width: Int, height: Int) -> Data {
        let lut: [UInt8] = [3, 1, 2, 0]
        let bytesPerRow = (width + 7) / 8
        var plane0 = Data(count: bytesPerRow * height)
        var plane1 = Data(count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard i < indexed.count else { continue }
                let stored = lut[min(indexed[i], 3)]
                let byteIdx = y * bytesPerRow + (x >> 3)
                let bitIdx = 7 - (x & 7)
                if stored & 1 != 0 { plane0[byteIdx] |= UInt8(1 << bitIdx) }
                if stored & 2 != 0 { plane1[byteIdx] |= UInt8(1 << bitIdx) }
            }
        }
        return plane0 + plane1
    }

    // 4 bpp packed: 2 pixels/byte, high nibble first (scheme 6: 16-gray)
    private static func pack4bpp(_ indexed: [Int]) -> Data {
        var out = Data(count: (indexed.count + 1) / 2)
        for (i, v) in indexed.enumerated() {
            if i % 2 == 0 { out[i / 2] |= UInt8((v & 0x0F) << 4) }
            else           { out[i / 2] |= UInt8(v & 0x0F) }
        }
        return out
    }
}

extension UIImage {
    // Redraws the image into a .up-oriented CGImage, fixing EXIF rotation from the camera roll.
    func orientationNormalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in draw(at: .zero) }
    }

    /// Downscale so the longest edge is at most `maxDimension` *pixels*, preserving aspect ratio
    /// (returns self if already within bounds). Used to build a lightweight canvas-preview copy so
    /// live image adjustments run Core Image over a small image instead of a
    /// full-resolution photo — a 12–48MP photo produces a 48–190MB bitmap per render, and dragging
    /// a slider spawns many of those, which exhausts memory and gets the app killed.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let newSize = CGSize(width: size.width * maxDimension / longest,
                             height: size.height * maxDimension / longest)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // treat newSize as absolute pixels; don't let @2x/@3x scale it back up
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
