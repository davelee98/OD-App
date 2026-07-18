import Foundation
import EpaperDithering

/// Swift front door to the Rust `epaper-dithering-core` dithering engine, linked in as the
/// `EpaperDithering` static-library XCFramework (built from `epaper-dithering/packages/rust/ios`).
///
/// This replaces the app's former pure-Swift nearest-color matcher, which used **sRGB-Euclidean**
/// distance and therefore diverged from the website / Python / firmware reference (all of which
/// match in **OKLab** via the shared Rust core). Feeding the app's palette in the app's own index
/// order means the returned indices line up with `ImageProcessor`'s wire-format packing with no
/// remapping.
///
/// Scope: matching + error diffusion only. Tone/gamut/exposure pre-processing stays in Swift
/// (`ImageProcessor.compressDynamicRange`), so callers pass pixels that are already pre-processed
/// and this runs the core at its defaults (all pre-processing off).
enum RustDither {

    /// Maps the app's `DitheringMode` to the core's `DitherMode` discriminant
    /// (see `enums.rs`: 0=None, 1=Burkes, 2=Ordered, 3=FloydSteinberg, 4=Atkinson,
    /// 5=Stucki, 6=Sierra, 7=SierraLite, 8=JarvisJudiceNinke).
    static func modeID(for mode: DitheringMode) -> UInt8 {
        switch mode {
        case .none:           return 0
        case .burkes:         return 1
        case .floydSteinberg: return 3
        case .atkinson:       return 4
        case .stucki:         return 5
        case .sierra:         return 6
        case .sierraLite:     return 7
        case .jarvis:         return 8
        }
    }

    /// Errors surfaced from the FFI boundary. `code` is the negative `ED_ERR_*` status.
    struct DitherError: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "RustDither.ed_dither failed with status \(code)" }
    }

    /// Dither a flat sRGB image (`width*height*3` bytes) to palette indices, one `UInt8` per pixel.
    ///
    /// - Parameters:
    ///   - rgb: flat sRGB bytes, `count == width * height * 3`.
    ///   - width/height: image dimensions in pixels.
    ///   - palette: flat RGB palette bytes in the caller's index order (`count` a multiple of 3, ≥ 2 colors).
    ///     The returned indices are into this palette.
    ///   - accentIndex: the palette's accent color index (only affects gamut, which is off here — pass 0).
    ///   - mode: dithering algorithm.
    ///   - serpentine: serpentine scan for error-diffusion modes. Defaults to `true` to match the core
    ///     (and thus the website / reference output).
    /// - Returns: `width * height` palette indices.
    static func dither(rgb: [UInt8], width: Int, height: Int,
                       palette: [UInt8], accentIndex: Int = 0,
                       mode: DitheringMode, serpentine: Bool = true) throws -> [UInt8] {
        precondition(rgb.count == width * height * 3, "rgb buffer size mismatch")
        precondition(palette.count >= 6 && palette.count % 3 == 0, "palette must be ≥2 RGB triples")

        var out = [UInt8](repeating: 0, count: width * height)
        let status: Int32 = rgb.withUnsafeBufferPointer { px in
            palette.withUnsafeBufferPointer { pal in
                out.withUnsafeMutableBufferPointer { outBuf in
                    ed_dither(
                        px.baseAddress, px.count, width,
                        pal.baseAddress, pal.count, accentIndex,
                        nil, 0, 0,                       // no canonical palette (plain matching)
                        modeID(for: mode), serpentine,
                        outBuf.baseAddress, outBuf.count
                    )
                }
            }
        }
        guard status == ED_OK else { throw DitherError(code: status) }
        return out
    }
}
