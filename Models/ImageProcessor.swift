import Foundation
import UIKit
import zlib

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
        4: [(0,0,0), (255,255,255), (0,128,0), (0,0,255), (255,0,0), (255,255,0)],  // 6-color
        5: [(0,0,0), (85,85,85), (170,170,170), (255,255,255)],              // 4-gray
        6: Array((0..<16).map { i -> RGB in let v = Float(i * 17); return (v,v,v) }),  // 16-gray
    ]

    // MARK: - Main Entry Point

    /// Process a UIImage into packed wire-format bytes ready for BLE upload.
    static func process(image: UIImage, width: Int, height: Int,
                        colorScheme: UInt8, dithering: DitheringMode) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let palette = palettes[colorScheme] ?? palettes[0]!

        // Render into RGBA buffer at target size
        let pixels = rgbaPixels(from: cgImage, width: width, height: height)
        guard !pixels.isEmpty else { return nil }

        // Extract float RGB planes for dithering
        var floatPixels = toFloat(pixels, count: width * height)

        // Apply dithering
        applyDithering(&floatPixels, width: width, height: height,
                        palette: palette, mode: dithering)

        // Quantize to palette indices
        let indexed = quantize(floatPixels, palette: palette)

        // Pack into wire format
        return pack(indexed, scheme: colorScheme, width: width, height: height)
    }

    // MARK: - Preview (apply dithering to UIImage for display)

    static func preview(image: UIImage, width: Int, height: Int,
                        colorScheme: UInt8, dithering: DitheringMode) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let palette = palettes[colorScheme] ?? palettes[0]!
        var pixels = rgbaPixels(from: cgImage, width: width, height: height)
        var floatPixels = toFloat(pixels, count: width * height)
        applyDithering(&floatPixels, width: width, height: height, palette: palette, mode: dithering)
        let indexed = quantize(floatPixels, palette: palette)
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

    // MARK: - Deflate Compression (raw deflate, window_bits = -15)

    static func deflate(_ data: Data) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, 9, Z_DEFLATED, 9, 8,
                             Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                             Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var output = Data()
        let bufSize = 65536
        var buffer  = [UInt8](repeating: 0, count: bufSize)

        return data.withUnsafeBytes { src in
            stream.next_in  = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            repeat {
                buffer.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bufSize)
                    zlib.deflate(&stream, Z_FINISH)
                }
                let n = bufSize - Int(stream.avail_out)
                output.append(contentsOf: buffer.prefix(n))
            } while stream.avail_out == 0
            return output
        }
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

    private static func applyDithering(_ pixels: inout [Float], width: Int, height: Int,
                                        palette: [RGB], mode: DitheringMode) {
        switch mode {
        case .none:           break
        case .floydSteinberg: errorDiffuse(&pixels, w: width, h: height, palette: palette,
                                            kernel: [(1,0,7/16.0),(-1,1,3/16.0),(0,1,5/16.0),(1,1,1/16.0)])
        case .atkinson:       errorDiffuse(&pixels, w: width, h: height, palette: palette,
                                            kernel: [(1,0,1/8.0),(2,0,1/8.0),(-1,1,1/8.0),(0,1,1/8.0),(1,1,1/8.0),(0,2,1/8.0)])
        case .stucki:         errorDiffuse(&pixels, w: width, h: height, palette: palette,
                                            kernel: [(1,0,8/42.0),(2,0,4/42.0),(-2,1,2/42.0),(-1,1,4/42.0),(0,1,8/42.0),(1,1,4/42.0),(2,1,2/42.0),(-2,2,1/42.0),(-1,2,2/42.0),(0,2,4/42.0),(1,2,2/42.0),(2,2,1/42.0)])
        case .sierra:         errorDiffuse(&pixels, w: width, h: height, palette: palette,
                                            kernel: [(1,0,5/32.0),(2,0,3/32.0),(-2,1,2/32.0),(-1,1,4/32.0),(0,1,5/32.0),(1,1,4/32.0),(2,1,3/32.0),(-1,2,2/32.0),(0,2,3/32.0),(1,2,2/32.0)])
        case .sierraLite:     errorDiffuse(&pixels, w: width, h: height, palette: palette,
                                            kernel: [(1,0,2/4.0),(-1,1,1/4.0),(0,1,1/4.0)])
        case .burkes:         errorDiffuse(&pixels, w: width, h: height, palette: palette,
                                            kernel: [(1,0,8/32.0),(2,0,4/32.0),(-2,1,2/32.0),(-1,1,4/32.0),(0,1,8/32.0),(1,1,4/32.0),(2,1,2/32.0)])
        case .jarvis:         errorDiffuse(&pixels, w: width, h: height, palette: palette,
                                            kernel: [(1,0,7/48.0),(2,0,5/48.0),(-2,1,3/48.0),(-1,1,5/48.0),(0,1,7/48.0),(1,1,5/48.0),(2,1,3/48.0),(-2,2,1/48.0),(-1,2,3/48.0),(0,2,5/48.0),(1,2,3/48.0),(2,2,1/48.0)])
        }
    }

    private static func errorDiffuse(_ p: inout [Float], w: Int, h: Int,
                                      palette: [RGB], kernel: [(Int, Int, Float)]) {
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let old = (p[i], p[i+1], p[i+2])
                let idx = nearest(r: old.0, g: old.1, b: old.2, palette: palette)
                let (nr, ng, nb) = palette[idx]
                p[i] = nr; p[i+1] = ng; p[i+2] = nb
                let er = old.0 - nr, eg = old.1 - ng, eb = old.2 - nb
                for (dx, dy, frac) in kernel {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0 && nx < w && ny >= 0 && ny < h else { continue }
                    let ni = (ny * w + nx) * 3
                    p[ni]   = (p[ni]   + er * frac).clamped(to: 0...255)
                    p[ni+1] = (p[ni+1] + eg * frac).clamped(to: 0...255)
                    p[ni+2] = (p[ni+2] + eb * frac).clamped(to: 0...255)
                }
            }
        }
    }

    private static func nearest(r: Float, g: Float, b: Float, palette: [RGB]) -> Int {
        var best = 0; var bestDist = Float.infinity
        for (i, (pr, pg, pb)) in palette.enumerated() {
            let d = (r-pr)*(r-pr) + (g-pg)*(g-pg) + (b-pb)*(b-pb)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    private static func quantize(_ pixels: [Float], palette: [RGB]) -> [Int] {
        let count = pixels.count / 3
        return (0..<count).map { i in nearest(r: pixels[i*3], g: pixels[i*3+1], b: pixels[i*3+2], palette: palette) }
    }

    // MARK: - Wire Format Packing

    private static func pack(_ indexed: [Int], scheme: UInt8, width: Int, height: Int) -> Data {
        switch scheme {
        case 0:        return pack1bpp(indexed, invert: false)
        case 1:        return pack2planes(indexed, redIdx: 2, yellowIdx: nil)
        case 2:        return pack2planes(indexed, redIdx: nil, yellowIdx: 2)
        case 3:        return pack2bpp(indexed)
        case 4:        return pack6color(indexed)
        case 5:        return packGray4(indexed, width: width, height: height)
        case 6:        return pack4bpp(indexed)
        default:       return pack1bpp(indexed, invert: false)
        }
    }

    // 1 bpp: 0=black, 1=white, MSB first
    private static func pack1bpp(_ indexed: [Int], invert: Bool) -> Data {
        var out = Data(count: (indexed.count + 7) / 8)
        for (i, v) in indexed.enumerated() {
            let bit = invert ? (v == 0 ? 1 : 0) : v
            if bit != 0 { out[i / 8] |= UInt8(0x80 >> (i % 8)) }
        }
        return out
    }

    // 2 bitplanes (B/W + colour)
    private static func pack2planes(_ indexed: [Int], redIdx: Int?, yellowIdx: Int?) -> Data {
        let planeSize = (indexed.count + 7) / 8
        var out = Data(count: planeSize * 2)
        for (i, v) in indexed.enumerated() {
            let mask = UInt8(0x80 >> (i % 8))
            // plane1 (BW): white (v==1) or red; yellow does NOT set this plane
            if v == 1 || (redIdx != nil && v == redIdx) { out[i / 8] |= mask }
            // plane2 (colour): red or yellow
            if v == redIdx || v == yellowIdx { out[planeSize + i / 8] |= mask }
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

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}

extension UIImage {
    // Redraws the image into a .up-oriented CGImage, fixing EXIF rotation from the camera roll.
    func orientationNormalized() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in draw(at: .zero) }
    }
}
