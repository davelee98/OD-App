import SwiftUI
import CoreImage.CIFilterBuiltins

/// The "physical canvas" for an e-paper screen: a fixed box locked to the panel's exact aspect
/// ratio. A photo is dropped inside and can be **panned** (`DragGesture`) and **zoomed**
/// (`MagnificationGesture`); the box `.clipped()`s it, acting as a hard crop bounding box — so the
/// user frames the shot the way it'll appear on the panel instead of stretching/padding it.
/// Draw / text / QR annotation overlays sit on top of the cropped photo and composite into it.
struct DisplayCanvasView: View {
    /// Adjusted photo to display (already run through `ImageProcessor.adjust`).
    let image: UIImage?
    /// Native pixel dimensions of the connected panel (drives the box aspect ratio).
    let displaySize: CGSize
    /// Scheme palette as SwiftUI colors, for rendering annotation strokes/text/QR on screen.
    let palette: [Color]
    let mode: CanvasMode

    // Photo crop transform (persisted by the Composer so it can render the final bitmap).
    // `pan` is stored **normalized** to the canvas box (fraction of width/height) so it survives a
    // box resize (rotation / iPad window resize) instead of shifting the crop; `scale` is a pure
    // zoom multiplier and is already box-independent.
    @Binding var pan: CGSize
    @Binding var scale: CGFloat

    // Annotation layers. Geometry inside these is stored normalized to the canvas box (see `Stroke`,
    // `TextItem`, `QRItem`); this view converts to/from view points at the gesture/render boundary.
    @Binding var strokes: [Stroke]
    @Binding var textItems: [TextItem]
    @Binding var qrItems: [QRItem]

    /// Reported back so the Composer can map canvas points → panel pixels when rendering.
    @Binding var canvasSize: CGSize

    /// Currently selected text/QR element (owned by the Composer so it can clear on mode/undo/reset).
    @Binding var selection: SelectedElement?

    // Annotation authoring parameters (current tool settings).
    var drawColorIndex: Int = 0
    var drawLineWidth: CGFloat = 3
    var pendingText: Binding<String>?
    var pendingTextSize: CGFloat = 32
    var textColorIndex: Int = 0
    var pendingQRContent: String = ""
    var pendingQRSize: CGFloat = 120
    var qrColorIndex: Int = 0
    /// Gates tap-to-place in `.qr` mode: the Composer disarms placement after each stamp so a
    /// stray tap can't drop duplicate codes; editing the content re-arms it.
    var qrPlacementEnabled: Bool = true
    /// Called to place a text item at the given position. The Composer provides the tap location.
    var onPlaceText: (CGPoint) -> Void = { _ in }
    /// Called when a text or QR element is selected on the canvas (for switching tool chips).
    var onElementSelected: (SelectedElement) -> Void = { _ in }
    /// A QR was just stamped — lets the Composer disarm further tap-to-place.
    var onQRPlaced: () -> Void = {}
    /// Called with the *pre-mutation* snapshot whenever the canvas changes annotation state
    /// (place / move / resize / delete / duplicate / reorder) — the Composer's undo stack.
    var onCommitUndo: (CanvasSnapshot) -> Void = { _ in }

    // Live drawing + gesture accumulators. Baselines are captured at gesture *start* (not persisted
    // across gestures or view recreation), so a device rotation that recreates this view can't leave
    // a stale baseline that snaps the photo on the next drag/pinch.
    @State private var currentStroke: Stroke?
    @State private var pinchBaseScale: CGFloat?   // photo zoom baseline, captured on the first pinch tick
    @State private var pinchActive = false        // a magnification is in progress → gate the drag/draw layer
    @State private var pinchDuringDraw = false    // a pinch preempted this draw → decline strokes for the rest of the touch

    // Selection-drag accumulators. Hit-test happens once on the first onChanged of a drag.
    @State private var dragStarted = false
    @State private var dragTarget: SelectedElement?
    @State private var dragOrigin: CGPoint?       // hit element's start position, in view points
    @State private var panStart: CGSize?          // photo pan (view points) captured at drag start
    @State private var dragExceededSlop = false
    @State private var pinchDuringDrag = false    // a pinch preempted this drag → suppress its tap/commit
    @State private var preDragSnapshot: CanvasSnapshot?

    /// A tap moves the finger less than this; beyond it the gesture is treated as a drag.
    private let tapSlop: CGFloat = 10

    private var aspectRatio: CGFloat {
        guard displaySize.height > 0 else { return 1 }
        return displaySize.width / displaySize.height
    }
    private func color(_ index: Int) -> Color { palette[safe: index] ?? .black }

    var body: some View {
        GeometryReader { geo in
            let box = boxSize(in: geo.size)

            ZStack(alignment: .topLeading) {
                Color.white

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: box.width, height: box.height)
                        .scaleEffect(scale)
                        .offset(CanvasSpace(box: box).toPoint(size: pan))
                } else {
                    placeholder
                }

                strokeCanvas(box: box)
                textOverlays(box: box)
                qrOverlays(box: box)
                interactionLayer(box: box)
                selectionChrome(box: box)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(zoomGesture())
            .border(Color(.systemGray4), width: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { canvasSize = box }
            .onChange(of: box) { _, newBox in canvasSize = newBox }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
    }

    private func boxSize(in available: CGSize) -> CGSize {
        let w = available.width
        let h = w / aspectRatio
        if h <= available.height {
            return CGSize(width: w, height: h)
        }
        return CGSize(width: available.height * aspectRatio, height: available.height)
    }

    // MARK: - Layers

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 36))
                .foregroundStyle(Color(.systemGray3))
            Text("Choose a photo to send")
                .font(.caption)
                .foregroundStyle(Color(.systemGray2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func strokeCanvas(box: CGSize) -> some View {
        let space = CanvasSpace(box: box)
        return Canvas { ctx, _ in
            for stroke in strokes { draw(stroke, in: ctx, space: space) }
            if let currentStroke { draw(currentStroke, in: ctx, space: space) }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ stroke: Stroke, in ctx: GraphicsContext, space: CanvasSpace) {
        guard stroke.points.count > 1 else { return }
        var path = Path()
        path.move(to: space.toPoint(stroke.points[0]))
        stroke.points.dropFirst().forEach { path.addLine(to: space.toPoint($0)) }
        ctx.stroke(path, with: .color(stroke.color),
                   style: StrokeStyle(lineWidth: space.toPoint(length: stroke.lineWidth),
                                      lineCap: .round, lineJoin: .round))
    }

    private func textOverlays(box: CGSize) -> some View {
        let space = CanvasSpace(box: box)
        return ForEach(textItems) { item in
            Text(item.text)
                .font(.system(size: space.toPoint(length: item.fontSize)))
                .foregroundColor(item.color)
                .position(space.toPoint(item.position))
        }
        .allowsHitTesting(false)   // all hit-testing is manual, inside interactionLayer
    }

    private func qrOverlays(box: CGSize) -> some View {
        let space = CanvasSpace(box: box)
        return ForEach(qrItems) { item in
            let side = space.toPoint(length: item.size)
            if let qrImg = odGenerateQR(content: item.content, size: side, color: item.color) {
                Image(uiImage: qrImg)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: side, height: side)
                    .position(space.toPoint(item.position))
            }
        }
        .allowsHitTesting(false)
    }

    /// Transparent top layer that captures the mode-specific single-finger interaction. Selection
    /// (tap/drag text & QR) is active in `.move`/`.text`/`.qr`; `.draw` owns the surface exclusively.
    @ViewBuilder
    private func interactionLayer(box: CGSize) -> some View {
        switch mode {
        case .draw:
            Color.clear.contentShape(Rectangle()).gesture(drawGesture(box: box))
        case .move, .text, .qr:
            Color.clear.contentShape(Rectangle()).gesture(selectionGesture(box: box))
        }
    }

    /// Selection chrome for the currently selected element — a dashed accent border plus corner
    /// controls: delete (top-right) and a context menu (top-left). Resizing is done with the tool
    /// panel's size slider (pinch is reserved for photo zoom — see `zoomGesture`). Sits *above*
    /// `interactionLayer` so the real controls win touches over the clear layer below. The rect is
    /// derived by ID lookup each render, so a stale selection (undo/reset) vanishes.
    @ViewBuilder
    private func selectionChrome(box: CGSize) -> some View {
        if let selection, let rect = frame(of: selection, in: box) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            Button {
                delete(selection)
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .background(Circle().fill(.white).padding(3))
            }
            .position(cornerPosition(x: rect.maxX, y: rect.minY, in: box))

            Menu {
                Button { duplicate(selection, in: box) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button { bringToFront(selection) } label: {
                    Label("Bring to Front", systemImage: "square.stack.3d.up")
                }
                Button(role: .destructive) { delete(selection) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .background(Circle().fill(.white).padding(3))
            }
            .position(cornerPosition(x: rect.minX, y: rect.minY, in: box))
        }
    }

    // MARK: - Hit-testing (manual)

    /// On-screen frame of a text item, centered on its position with a slop inset (UIFont vs SwiftUI
    /// Text metrics differ slightly). Element geometry is normalized, so it's denormalized against
    /// the current box first.
    private func frame(ofText item: TextItem, in box: CGSize) -> CGRect {
        let space = CanvasSpace(box: box)
        let pos = space.toPoint(item.position)
        let fontSize = space.toPoint(length: item.fontSize)
        let size = (item.text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: fontSize)])
        return CGRect(x: pos.x - size.width / 2, y: pos.y - size.height / 2,
                      width: size.width, height: size.height).insetBy(dx: -12, dy: -12)
    }

    private func frame(ofQR item: QRItem, in box: CGSize) -> CGRect {
        let space = CanvasSpace(box: box)
        let pos = space.toPoint(item.position)
        let side = space.toPoint(length: item.size)
        return CGRect(x: pos.x - side / 2, y: pos.y - side / 2,
                      width: side, height: side).insetBy(dx: -8, dy: -8)
    }

    private func frame(of selection: SelectedElement, in box: CGSize) -> CGRect? {
        switch selection {
        case .text(let id): return textItems.first { $0.id == id }.map { frame(ofText: $0, in: box) }
        case .qr(let id):   return qrItems.first { $0.id == id }.map { frame(ofQR: $0, in: box) }
        }
    }

    /// Topmost element under `point` (view points). QR items render above text, and each array is
    /// reversed so the last-drawn (topmost) item wins.
    private func hitTest(_ point: CGPoint, in box: CGSize) -> SelectedElement? {
        for item in qrItems.reversed() where frame(ofQR: item, in: box).contains(point) { return .qr(item.id) }
        for item in textItems.reversed() where frame(ofText: item, in: box).contains(point) { return .text(item.id) }
        return nil
    }

    private func cornerPosition(x: CGFloat, y: CGFloat, in box: CGSize) -> CGPoint {
        // Clamp inside the box — the ZStack is .clipped(), so an off-box control is untappable.
        let inset: CGFloat = 14
        return CGPoint(x: min(max(x, inset), box.width - inset),
                       y: min(max(y, inset), box.height - inset))
    }

    private func snapshot() -> CanvasSnapshot {
        CanvasSnapshot(strokes: strokes, textItems: textItems, qrItems: qrItems)
    }

    private func delete(_ selection: SelectedElement) {
        onCommitUndo(snapshot())
        switch selection {
        case .text(let id): textItems.removeAll { $0.id == id }
        case .qr(let id):   qrItems.removeAll { $0.id == id }
        }
        self.selection = nil
    }

    private func duplicate(_ selection: SelectedElement, in box: CGSize) {
        switch selection {
        case .text(let id):
            guard let src = textItems.first(where: { $0.id == id }) else { return }
            onCommitUndo(snapshot())
            let copy = TextItem(text: src.text, fontSize: src.fontSize, color: src.color,
                                position: offset(src.position, byPoints: 16, in: box))
            textItems.append(copy)
            self.selection = .text(copy.id)
        case .qr(let id):
            guard let src = qrItems.first(where: { $0.id == id }) else { return }
            onCommitUndo(snapshot())
            let copy = QRItem(content: src.content, size: src.size, color: src.color,
                              position: offset(src.position, byPoints: 16, in: box))
            qrItems.append(copy)
            self.selection = .qr(copy.id)
        }
    }

    /// Nudge a normalized position by a fixed number of view points, clamped to the box, returning
    /// the result normalized (used when duplicating so the copy is visibly offset at any box size).
    private func offset(_ norm: CGPoint, byPoints d: CGFloat, in box: CGSize) -> CGPoint {
        let space = CanvasSpace(box: box)
        let p = space.toPoint(norm)
        return space.toNorm(clamp(CGPoint(x: p.x + d, y: p.y + d), in: box))
    }

    /// Move the element to the end of its array — last-drawn wins both rendering and hit-testing.
    /// (QR still always renders above text; ordering is within each type.)
    private func bringToFront(_ selection: SelectedElement) {
        switch selection {
        case .text(let id):
            guard let i = textItems.firstIndex(where: { $0.id == id }), i != textItems.count - 1 else { return }
            onCommitUndo(snapshot())
            textItems.append(textItems.remove(at: i))
        case .qr(let id):
            guard let i = qrItems.firstIndex(where: { $0.id == id }), i != qrItems.count - 1 else { return }
            onCommitUndo(snapshot())
            qrItems.append(qrItems.remove(at: i))
        }
    }

    /// Move an element to a new **normalized** position.
    private func move(_ target: SelectedElement, toNormalized position: CGPoint) {
        switch target {
        case .text(let id): if let i = textItems.firstIndex(where: { $0.id == id }) { textItems[i].position = position }
        case .qr(let id):   if let i = qrItems.firstIndex(where: { $0.id == id }) { qrItems[i].position = position }
        }
    }

    /// The element's current **normalized** position.
    private func originOf(_ target: SelectedElement) -> CGPoint? {
        switch target {
        case .text(let id): return textItems.first { $0.id == id }?.position
        case .qr(let id):   return qrItems.first { $0.id == id }?.position
        }
    }

    private func clamp(_ point: CGPoint, in box: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), box.width), y: min(max(point.y, 0), box.height))
    }

    // MARK: - Gestures

    /// Pinch gesture: **photo zoom only**. Element resize is done with the tool-panel size sliders,
    /// so pinch is reserved for framing the photo (per the project's interaction model) and never
    /// fights the drag/draw layer for element manipulation. `value` is relative to the gesture start
    /// (begins at 1), and `pinchBaseScale` is captured on the first tick rather than persisted, so a
    /// rotation that recreates this view can't leave a stale baseline. `pinchActive` gates the
    /// simultaneous drag/draw layer so a two-finger pinch can't also pan the photo or lay a stroke.
    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pinchActive = true
                if pinchBaseScale == nil { pinchBaseScale = scale }
                scale = max(1, (pinchBaseScale ?? scale) * value)
            }
            .onEnded { _ in
                pinchBaseScale = nil
                pinchActive = false
            }
    }

    private func drawGesture(box: CGSize) -> some Gesture {
        let space = CanvasSpace(box: box)
        return DragGesture(minimumDistance: 0)
            .onChanged { v in
                // A pinch is zooming the photo — or has, earlier in this touch. Abandon any
                // in-progress stroke and stay disabled for the sequence's remainder: the surviving
                // finger keeps this DragGesture alive after the magnification ends, and letting it
                // resume would lay (and commit) a stray line. `pinchDuringDraw` makes the freeze sticky.
                if pinchActive || pinchDuringDraw { pinchDuringDraw = true; currentStroke = nil; return }
                let p = space.toNorm(v.location)
                if currentStroke == nil {
                    currentStroke = Stroke(color: color(drawColorIndex),
                                           lineWidth: space.toNorm(length: drawLineWidth), points: [p])
                } else {
                    currentStroke?.points.append(p)
                }
            }
            .onEnded { _ in
                if !pinchActive, !pinchDuringDraw, let s = currentStroke, s.points.count > 1 {
                    onCommitUndo(snapshot())
                    strokes.append(s)
                }
                currentStroke = nil
                pinchDuringDraw = false   // reset the sticky freeze for the next touch sequence
            }
    }

    /// Unified tap+drag gesture for `.move`/`.text`/`.qr`. A near-stationary gesture is a tap
    /// (select / edit / place / deselect); movement drags the hit element, or pans the photo in
    /// `.move`. Element moves only begin once the finger clears `tapSlop`, so a plain tap never
    /// nudges the element it selects. All geometry works in view points here and is normalized when
    /// written back. If a pinch preempts the drag, this layer freezes (and its tap/commit is
    /// suppressed) so zooming the photo never also pans or moves an element.
    private func selectionGesture(box: CGSize) -> some Gesture {
        let space = CanvasSpace(box: box)
        return DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !dragStarted {
                    // Hit-test the start location exactly once, at the first onChanged. Baselines are
                    // captured here (per-gesture), not persisted across gestures.
                    dragStarted = true
                    dragTarget = hitTest(v.startLocation, in: box)
                    dragOrigin = dragTarget.flatMap(originOf).map(space.toPoint)
                    panStart = space.toPoint(size: pan)
                    pinchDuringDrag = false
                    if dragTarget != nil { preDragSnapshot = snapshot() }
                }
                if pinchActive || pinchDuringDrag {
                    // Pinch took over — or did earlier in this touch. Hold everything at its
                    // gesture-start value so the zoom doesn't also drag the element or drift the pan,
                    // and keep holding for the sequence's remainder: the surviving finger keeps this
                    // DragGesture alive after the magnification ends, and its translation now carries
                    // the pinch's motion, so resuming would jump. `pinchDuringDrag` makes it sticky
                    // (onEnded still swallows the tap/commit).
                    pinchDuringDrag = true
                    if let target = dragTarget, let origin = dragOrigin {
                        move(target, toNormalized: space.toNorm(origin))
                    } else if mode == .move, let ps = panStart {
                        pan = space.toNorm(size: ps)
                    }
                    return
                }
                if let target = dragTarget, let origin = dragOrigin {
                    if !dragExceededSlop,
                       abs(v.translation.width) < tapSlop, abs(v.translation.height) < tapSlop {
                        return   // still within tap territory — don't move yet
                    }
                    dragExceededSlop = true
                    let moved = clamp(CGPoint(x: origin.x + v.translation.width,
                                              y: origin.y + v.translation.height), in: box)
                    move(target, toNormalized: space.toNorm(moved))
                } else if mode == .move, let ps = panStart {
                    let moved = CGSize(width: ps.width + v.translation.width,
                                       height: ps.height + v.translation.height)
                    pan = space.toNorm(size: moved)
                }
            }
            .onEnded { v in
                // A pinch preempted this drag: swallow the tap/commit (movement was already reverted).
                if !pinchDuringDrag {
                    let isTap = abs(v.translation.width) < tapSlop && abs(v.translation.height) < tapSlop
                    if isTap {
                        handleTap(at: v.location, in: box)
                    } else if dragTarget != nil, dragExceededSlop, let snap = preDragSnapshot {
                        onCommitUndo(snap)
                    }
                    // Photo pan needs no commit (not on the undo stack) and no baseline persist.
                }
                dragStarted = false
                dragTarget = nil
                dragOrigin = nil
                panStart = nil
                dragExceededSlop = false
                pinchDuringDrag = false
                preDragSnapshot = nil
            }
    }

    /// Tap logic per mode: a hit selects; tapping empty space deselects first (guards accidental placement).
    /// In `.text` mode with nothing selected, empty space places a text item at that location
    /// (the Composer provides the pending text, size, and color).
    private func handleTap(at loc: CGPoint, in box: CGSize) {
        let space = CanvasSpace(box: box)
        switch mode {
        case .draw:
            break
        case .move:
            let hit = hitTest(loc, in: box)
            selection = hit
            if let hit { onElementSelected(hit) }
        case .text:
            if let hit = hitTest(loc, in: box) {
                selection = hit
                onElementSelected(hit)
            } else if selection != nil {
                selection = nil
            } else {
                onPlaceText(space.toNorm(loc))   // Composer places at this normalized point
            }
        case .qr:
            if let hit = hitTest(loc, in: box) {
                selection = hit
                onElementSelected(hit)
            } else if selection != nil {
                selection = nil
            } else if qrPlacementEnabled {
                let content = pendingQRContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return }
                onCommitUndo(snapshot())
                let sidePoints = min(max(pendingQRSize, 24), max(min(box.width, box.height), 24))
                let item = QRItem(content: content, size: space.toNorm(length: sidePoints),
                                  color: color(qrColorIndex), position: space.toNorm(loc))
                qrItems.append(item)
                selection = .qr(item.id)
                onElementSelected(.qr(item.id))
                onQRPlaced()
            }
        }
    }
}

// MARK: - Shared QR helper (used by the canvas and the final composite render)

/// Shared CIContext for rasterizing QR codes to CGImage-backed UIImages.
private let odQRContext = CIContext(options: nil)

/// Cache of rendered QR images. The canvas calls `odGenerateQR` on every SwiftUI render pass, and
/// `QRItem` is a value struct in `@State` (storing a UIImage on it would break value semantics), so
/// an NSCache — with automatic memory-pressure eviction — is the right shape. Canvas-size and
/// composite-size (`size * k`) entries are distinct by key design.
private let odQRCache = NSCache<NSString, UIImage>()

/// Generate a QR code as a **CGImage-backed** `UIImage`. The previous `UIImage(ciImage:)` had a nil
/// `cgImage`, which SwiftUI's `Image(uiImage:)` cannot rasterize — so the QR was invisible on the
/// live canvas (only the UIKit `draw(in:)` composite path could render it). Rasterizing through a
/// CIContext to a real CGImage fixes that.
func odGenerateQR(content: String, size: CGFloat, color: Color) -> UIImage? {
    guard size > 0 else { return nil }

    // Cache key: content + rounded size + tint RGB. Tint change or size change is a distinct entry.
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    let roundedSize = Int(size.rounded())
    let key = "\(content)|\(roundedSize)|\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255))" as NSString
    if let cached = odQRCache.object(forKey: key) { return cached }

    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(content.utf8)
    filter.correctionLevel = "M"
    guard let base = filter.outputImage, base.extent.width > 0 else { return nil }

    // Tint the dark modules with the swatch color; keep the background white so codes stay scannable
    // over photos. (The old `color:` param was ignored — the swatch picker did nothing.)
    let tint = CIFilter.falseColor()
    tint.inputImage = base
    tint.color0 = CIColor(color: UIColor(color))
    tint.color1 = CIColor(color: .white)
    guard let tinted = tint.outputImage else { return nil }

    // Nearest-neighbour sampling before the affine upscale keeps modules crisp.
    let scale = size / tinted.extent.width
    let upscaled = tinted.samplingNearest()
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

    guard let cg = odQRContext.createCGImage(upscaled, from: upscaled.extent) else { return nil }
    let image = UIImage(cgImage: cg)
    odQRCache.setObject(image, forKey: key)
    return image
}

// MARK: - Supporting Types

enum CanvasMode: String, CaseIterable, Identifiable {
    case move, draw, text, qr
    var id: String { rawValue }
    var title: String {
        switch self {
        case .move: return "Photo"
        case .draw: return "Draw"
        case .text: return "Text"
        case .qr:   return "QR"
        }
    }
    var systemImage: String {
        switch self {
        case .move: return "hand.draw"
        case .draw: return "pencil.tip"
        case .text: return "textformat"
        case .qr:   return "qrcode"
        }
    }
}

/// The currently selected canvas element. Strokes are intentionally not selectable.
enum SelectedElement: Equatable {
    case text(UUID)
    case qr(UUID)
}

// Annotation geometry is stored **normalized** to the canvas box (0…1): positions are fractions of
// the box (x by width, y by height) and lengths (`lineWidth`, `fontSize`, `size`) are fractions of
// the box width. This keeps the composition box-independent, so device rotation, an iPad window
// resize, or a late device-config aspect change preserves both the on-screen layout and the image
// actually sent to the panel. `CanvasSpace` converts to view points for display/hit-testing;
// `PanelSpace` maps straight to panel pixels in the composite render.

struct Stroke: Identifiable, Equatable {
    let id = UUID()
    var color: Color
    var lineWidth: CGFloat      // normalized to box width
    var points: [CGPoint]       // normalized to the box
}

struct TextItem: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var fontSize: CGFloat       // normalized to box width
    var color: Color
    var position: CGPoint       // normalized to the box
}

struct QRItem: Identifiable, Equatable {
    let id = UUID()
    var content: String
    var size: CGFloat           // normalized to box width
    var color: Color
    var position: CGPoint       // normalized to the box
}

/// Value snapshot of all annotation layers — one entry in the Composer's undo/redo history.
/// Copies preserve element `id`s (value structs), so restoring a snapshot keeps identity stable.
struct CanvasSnapshot: Equatable {
    var strokes: [Stroke]
    var textItems: [TextItem]
    var qrItems: [QRItem]
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
