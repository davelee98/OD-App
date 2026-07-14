import CoreGraphics

/// Converts between **normalized canvas coordinates** (0…1, relative to the on-screen canvas box)
/// and view points, and from normalized coordinates straight to panel pixels for the composite
/// render.
///
/// Annotation geometry (stroke points, text/QR positions and sizes) and the photo `pan` are stored
/// normalized so a box resize — device rotation, iPad Split View / Stage Manager resize, or a late
/// device config changing the panel aspect ratio — preserves the composition instead of shifting
/// the crop and drifting annotations relative to the photo. Nothing has to be rescaled when the box
/// changes; the values are box-independent by construction.
///
/// The canvas box always matches the panel's aspect ratio (`box.width / box.height == w / h`), so
/// the two axes share one scale factor and a *length* (font size, QR side, stroke width) normalizes
/// by width alone while remaining isotropic in panel pixels.
struct CanvasSpace {
    /// The current on-screen canvas box (points). May be `.zero` before first layout, in which case
    /// the `toNorm*` conversions return 0 rather than dividing by zero.
    let box: CGSize

    init(box: CGSize) { self.box = box }

    // MARK: Points ↔ normalized

    /// Normalized point → view point.
    func toPoint(_ n: CGPoint) -> CGPoint {
        CGPoint(x: n.x * box.width, y: n.y * box.height)
    }
    /// View point → normalized point.
    func toNorm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: box.width > 0 ? p.x / box.width : 0,
                y: box.height > 0 ? p.y / box.height : 0)
    }

    /// Normalized length → view points (length normalizes by width).
    func toPoint(length n: CGFloat) -> CGFloat { n * box.width }
    /// View-point length → normalized length.
    func toNorm(length p: CGFloat) -> CGFloat { box.width > 0 ? p / box.width : 0 }

    /// Normalized offset → view-point offset.
    func toPoint(size n: CGSize) -> CGSize {
        CGSize(width: n.width * box.width, height: n.height * box.height)
    }
    /// View-point offset → normalized offset.
    func toNorm(size p: CGSize) -> CGSize {
        CGSize(width: box.width > 0 ? p.width / box.width : 0,
               height: box.height > 0 ? p.height / box.height : 0)
    }
}

/// Maps normalized canvas coordinates directly to panel pixels for the off-main composite render.
/// Because the normalized value is already box-independent, the render never needs the on-screen box
/// — `normalized × panelPixels` reproduces the exact same placement the old point→pixel math did.
enum PanelSpace {
    /// Normalized point → panel pixel.
    static func pixel(_ n: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(x: n.x * CGFloat(width), y: n.y * CGFloat(height))
    }
    /// Normalized length → panel pixels (length normalizes by width).
    static func pixel(length n: CGFloat, width: Int) -> CGFloat {
        n * CGFloat(width)
    }
    /// Normalized offset → panel-pixel offset.
    static func pixel(offset n: CGSize, width: Int, height: Int) -> CGSize {
        CGSize(width: n.width * CGFloat(width), height: n.height * CGFloat(height))
    }
}

/// How the photo is mapped onto the canvas before the user's zoom (`scale`) and `pan` are applied.
/// The chosen mode sets the *base* draw size; each mode defines a clean framing baseline, so
/// switching modes resets `scale`/`pan` (see `ComposerView.setFitMode`). `Cover` is the default and
/// matches the app's original aspect-fill behavior.
enum PhotoFitMode: String, CaseIterable, Identifiable, Equatable {
    /// Aspect-fill: the photo covers the whole canvas, cropping the overflow (the original behavior).
    case cover
    /// Aspect-fit: the whole photo is visible, letter/pillar-boxed on the white canvas.
    case contain
    /// Non-uniform: the photo is stretched to fill the canvas exactly in both dimensions.
    case stretch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cover:   return "Cover"
        case .contain: return "Contain"
        case .stretch: return "Stretch"
        }
    }
}

/// Computes the photo's draw rect inside a container for a given fit mode, zoom, and pan. This is the
/// **single source of truth** shared by the on-screen canvas (`DisplayCanvasView`, container = the
/// canvas box in points) and the off-screen composite render (`ComposerView.renderComposite`,
/// container = the panel in pixels). Because the geometry is expressed purely in terms of the
/// container size — and `pan` is normalized to it — the same formula yields a proportionally
/// identical rect at any resolution, so what the user frames on screen is exactly what is rasterized
/// and sent to the panel. Keep the two call sites pointed at this function so they can't drift.
enum PhotoLayout {
    /// - Parameters:
    ///   - container: the box the photo lives in (points on screen, pixels for the render).
    ///   - imageSize: the source image's size (only its aspect ratio matters for cover/contain,
    ///     and it is ignored entirely for stretch, so a downscaled preview and the full-res original
    ///     produce the same *proportional* placement).
    ///   - scale: the user's zoom multiplier (1 = the fit-mode baseline).
    ///   - pan: normalized pan offset (fraction of the container's width/height).
    static func drawRect(container: CGSize, imageSize: CGSize, fitMode: PhotoFitMode,
                         scale: CGFloat, pan: CGSize) -> CGRect {
        let wf = container.width, hf = container.height
        let imgW = imageSize.width, imgH = imageSize.height
        guard imgW > 0, imgH > 0 else { return .zero }

        let drawW: CGFloat, drawH: CGFloat
        switch fitMode {
        case .cover:
            let s0 = max(wf / imgW, hf / imgH)   // fill: largest edge covers the box
            drawW = imgW * s0 * scale
            drawH = imgH * s0 * scale
        case .contain:
            let s0 = min(wf / imgW, hf / imgH)   // fit: smallest edge fits inside the box
            drawW = imgW * s0 * scale
            drawH = imgH * s0 * scale
        case .stretch:
            drawW = wf * scale                    // fill both axes exactly, ignoring aspect ratio
            drawH = hf * scale
        }
        // Centered in the box, then shifted by the normalized pan (× container size).
        let x = (wf - drawW) / 2 + pan.width * wf
        let y = (hf - drawH) / 2 + pan.height * hf
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }
}
