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
