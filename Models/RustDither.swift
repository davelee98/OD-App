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
/// Scope: matching + error diffusion, plus the core's optional DBS refinement (`Refinement`).
/// Tone/gamut/exposure pre-processing stays in Swift
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

    /// Direct Binary Search refinement, run by the core after error diffusion. DBS repeatedly
    /// toggles and swaps pixels to minimise the difference between the image and the dithered
    /// result as the eye blurs them at this viewing geometry. Opt-in: noticeably better color
    /// and tone on multi-color panels, but far slower than diffusion alone.
    struct Refinement: Equatable {
        /// Upper bound on full-image passes; the core stops earlier once a pass changes nothing.
        var maxPasses: UInt32
        var viewingDistanceCm: Double
        /// Panel pixel density. Use the panel's real value when known (`panelPPI`).
        var ppi: Double

        /// The core's defaults (read from Rust, never hard-coded here).
        static var coreDefault: Refinement {
            let o = ed_dither_options_default()
            return Refinement(maxPasses: ed_dither_options_default_dbs_passes(),
                              viewingDistanceCm: o.dbs_viewing_distance_cm, ppi: o.dbs_ppi)
        }

        /// Core defaults with the panel's own pixel density when it can be derived.
        static func forPanel(pixelWidth: Int, activeWidthMM: Int) -> Refinement {
            var r = coreDefault
            if let ppi = panelPPI(pixelWidth: pixelWidth, activeWidthMM: activeWidthMM) { r.ppi = ppi }
            return r
        }

        /// Pixels per inch from the config's `pixel_width` and `active_width_mm`; nil when the
        /// config doesn't carry a physical size.
        static func panelPPI(pixelWidth: Int, activeWidthMM: Int) -> Double? {
            guard pixelWidth > 0, activeWidthMM > 0 else { return nil }
            return Double(pixelWidth) / (Double(activeWidthMM) / 25.4)
        }
    }

    /// ABI version of the linked framework (`ed_abi_version`); this wrapper needs 2.
    static var abiVersion: UInt32 { ed_abi_version() }

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
    ///   - refinement: optional DBS pass after diffusion; `nil` (the default) leaves it off.
    /// - Returns: `width * height` palette indices.
    static func dither(rgb: [UInt8], width: Int, height: Int,
                       palette: [UInt8], accentIndex: Int = 0,
                       mode: DitheringMode, serpentine: Bool = true,
                       refinement: Refinement? = nil) throws -> [UInt8] {
        precondition(rgb.count == width * height * 3, "rgb buffer size mismatch")
        precondition(palette.count >= 6 && palette.count % 3 == 0, "palette must be ≥2 RGB triples")

        var options = ed_dither_options_default()
        options.mode_id = modeID(for: mode)
        options.serpentine = serpentine
        if let refinement, refinement.maxPasses > 0 {
            options.dbs_max_passes = refinement.maxPasses
            options.dbs_viewing_distance_cm = refinement.viewingDistanceCm
            options.dbs_ppi = refinement.ppi
        }

        var out = [UInt8](repeating: 0, count: width * height)
        let status: Int32 = rgb.withUnsafeBufferPointer { px in
            palette.withUnsafeBufferPointer { pal in
                out.withUnsafeMutableBufferPointer { outBuf in
                    ed_dither(
                        px.baseAddress, px.count, width,
                        pal.baseAddress, pal.count, accentIndex,
                        nil, 0, 0,                       // no canonical palette (plain matching)
                        &options,
                        outBuf.baseAddress, outBuf.count
                    )
                }
            }
        }
        guard status == ED_OK else { throw DitherError(code: status) }
        return out
    }
}
