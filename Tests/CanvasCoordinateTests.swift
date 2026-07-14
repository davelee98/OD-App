import XCTest
import CoreGraphics
@testable import OD_App

/// Pins the canvas coordinate model that keeps a composition stable across box resizes (device
/// rotation, iPad window resize, late aspect-change). Two properties matter:
///   1. **Round-trip** — normalizing a view value and denormalizing it against the same box is the
///      identity, so nothing drifts when the box is unchanged.
///   2. **Render equivalence** — mapping a normalized value straight to panel pixels reproduces the
///      *exact* placement the previous point→pixel math (`value × k`, `k = panelWidth / box.width`)
///      produced, so the bitmap sent to a panel is unchanged for an untouched composition.
final class CanvasCoordinateTests: XCTestCase {

    // Boxes that keep the panel aspect ratio (800×480) exactly — as the live canvas always does,
    // deriving height from width — at a few on-screen sizes incl. a larger (rotated/iPad) window.
    private let panel = (w: 800, h: 480)
    private func box(width: CGFloat) -> CGSize {
        CGSize(width: width, height: width * CGFloat(panel.h) / CGFloat(panel.w))
    }
    private var boxes: [CGSize] { [box(width: 350), box(width: 700), box(width: 1000)] }

    // MARK: - Round-trip identity

    func testPointRoundTrip() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 175, y: 105),
                      CGPoint(x: 349.5, y: 12.25), CGPoint(x: 40, y: 200)]
        for box in boxes {
            let space = CanvasSpace(box: box)
            for p in points {
                let round = space.toPoint(space.toNorm(p))
                XCTAssertEqual(round.x, p.x, accuracy: 1e-9)
                XCTAssertEqual(round.y, p.y, accuracy: 1e-9)
            }
        }
    }

    func testLengthRoundTrip() {
        for box in boxes {
            let space = CanvasSpace(box: box)
            for len: CGFloat in [0, 3, 32, 120, 300] {
                XCTAssertEqual(space.toPoint(length: space.toNorm(length: len)), len, accuracy: 1e-9)
            }
        }
    }

    func testSizeRoundTrip() {
        let sizes = [CGSize.zero, CGSize(width: 40, height: -25), CGSize(width: 120, height: 66)]
        for box in boxes {
            let space = CanvasSpace(box: box)
            for s in sizes {
                let round = space.toPoint(size: space.toNorm(size: s))
                XCTAssertEqual(round.width, s.width, accuracy: 1e-9)
                XCTAssertEqual(round.height, s.height, accuracy: 1e-9)
            }
        }
    }

    /// Normalizing is box-independent: the same view point in a small box and in a 2× box maps to
    /// the *same* normalized value, which is the whole point of the representation.
    func testNormalizationIsBoxIndependentAtSameFraction() {
        let small = CanvasSpace(box: CGSize(width: 350, height: 210))
        let large = CanvasSpace(box: CGSize(width: 700, height: 420))
        // A point at 40% width / 60% height of each box.
        let a = small.toNorm(CGPoint(x: 0.4 * 350, y: 0.6 * 210))
        let b = large.toNorm(CGPoint(x: 0.4 * 700, y: 0.6 * 420))
        XCTAssertEqual(a.x, b.x, accuracy: 1e-12)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-12)
        XCTAssertEqual(a.x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(a.y, 0.6, accuracy: 1e-12)
    }

    // MARK: - Zero-box safety (pre-layout)

    func testZeroBoxNormalizesToZeroWithoutDividingByZero() {
        let space = CanvasSpace(box: .zero)
        let n = space.toNorm(CGPoint(x: 100, y: 50))
        XCTAssertEqual(n.x, 0)
        XCTAssertEqual(n.y, 0)
        XCTAssertEqual(space.toNorm(length: 42), 0)
        XCTAssertTrue(n.x.isFinite && n.y.isFinite)
    }

    // MARK: - Render equivalence vs. the legacy point→pixel math

    func testPixelMappingMatchesLegacyPointMath() {
        for box in boxes {
            let space = CanvasSpace(box: box)
            let k = CGFloat(panel.w) / box.width   // legacy: canvas points → panel pixels

            for p in [CGPoint(x: 175, y: 105), CGPoint(x: 12, y: 260), CGPoint(x: 349, y: 1)] {
                let legacy = CGPoint(x: p.x * k, y: p.y * k)   // old render used k on both axes
                let norm = space.toNorm(p)
                let pixel = PanelSpace.pixel(norm, width: panel.w, height: panel.h)
                XCTAssertEqual(pixel.x, legacy.x, accuracy: 1e-6)
                XCTAssertEqual(pixel.y, legacy.y, accuracy: 1e-6)
            }

            for len: CGFloat in [3, 32, 120] {
                let legacy = len * k
                let pixel = PanelSpace.pixel(length: space.toNorm(length: len), width: panel.w)
                XCTAssertEqual(pixel, legacy, accuracy: 1e-6)
            }
        }
    }

    /// The pan offset the composite adds in pixels must equal the legacy `pan_points × k`.
    func testPanPixelOffsetMatchesLegacy() {
        for box in boxes {
            let space = CanvasSpace(box: box)
            let k = CGFloat(panel.w) / box.width
            let panPoints = CGSize(width: 48, height: -30)
            let panNorm = space.toNorm(size: panPoints)
            let offset = PanelSpace.pixel(offset: panNorm, width: panel.w, height: panel.h)
            XCTAssertEqual(offset.width, panPoints.width * k, accuracy: 1e-6)
            XCTAssertEqual(offset.height, panPoints.height * k, accuracy: 1e-6)
        }
    }
}
