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
    @Binding var pan: CGSize
    @Binding var scale: CGFloat
    /// Bumped by the Composer whenever `pan`/`scale` are force-reset from outside a gesture (new
    /// photo, Reset button, full page reset). Syncs `basePan`/`baseScale` to match so the *next*
    /// drag/pinch computes its delta from the reset origin instead of a stale pre-reset baseline.
    var transformResetToken: Int = 0

    // Annotation layers.
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

    // Live drawing + gesture accumulators.
    @State private var currentStroke: Stroke?
    @State private var basePan: CGSize = .zero
    @State private var baseScale: CGFloat = 1

    // Selection-drag accumulators. Hit-test happens once on the first onChanged of a drag.
    @State private var dragStarted = false
    @State private var dragTarget: SelectedElement?
    @State private var dragOrigin: CGPoint?
    @State private var dragExceededSlop = false
    @State private var preDragSnapshot: CanvasSnapshot?

    // Pinch-resize accumulators (captured once at the first onChanged of a pinch that has a selection).
    @State private var resizeSnapshot: CanvasSnapshot?
    @State private var resizeBaseValue: CGFloat?

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
                        .offset(pan)
                } else {
                    placeholder
                }

                strokeCanvas
                textOverlays
                qrOverlays
                interactionLayer(box: box)
                selectionChrome(box: box)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(zoomGesture(box: box))
            .border(Color(.systemGray4), width: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { canvasSize = box }
            .onChange(of: box) { _, newBox in canvasSize = newBox }
            .onChange(of: transformResetToken) { _, _ in basePan = .zero; baseScale = 1 }
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

    private var strokeCanvas: some View {
        Canvas { ctx, _ in
            for stroke in strokes { draw(stroke, in: ctx) }
            if let currentStroke { draw(currentStroke, in: ctx) }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ stroke: Stroke, in ctx: GraphicsContext) {
        guard stroke.points.count > 1 else { return }
        var path = Path()
        path.move(to: stroke.points[0])
        stroke.points.dropFirst().forEach { path.addLine(to: $0) }
        ctx.stroke(path, with: .color(stroke.color),
                   style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round))
    }

    private var textOverlays: some View {
        ForEach(textItems) { item in
            Text(item.text)
                .font(.system(size: item.fontSize))
                .foregroundColor(item.color)
                .position(item.position)
        }
        .allowsHitTesting(false)   // all hit-testing is manual, inside interactionLayer
    }

    private var qrOverlays: some View {
        ForEach(qrItems) { item in
            if let qrImg = odGenerateQR(content: item.content, size: item.size, color: item.color) {
                Image(uiImage: qrImg)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: item.size, height: item.size)
                    .position(item.position)
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
            Color.clear.contentShape(Rectangle()).gesture(drawGesture)
        case .move, .text, .qr:
            Color.clear.contentShape(Rectangle()).gesture(selectionGesture(box: box))
        }
    }

    /// Selection chrome for the currently selected element — a dashed accent border plus corner
    /// controls: delete (top-right) and a context menu (top-left). Resizing is a pinch gesture on
    /// the selected element rather than a chrome control (see `zoomGesture`). Sits *above*
    /// `interactionLayer` so the real controls win touches over the clear layer below. The rect is
    /// derived by ID lookup each render, so a stale selection (undo/reset) vanishes.
    @ViewBuilder
    private func selectionChrome(box: CGSize) -> some View {
        if let selection, let rect = frame(of: selection) {
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
    /// Text metrics differ slightly).
    private func frame(ofText item: TextItem) -> CGRect {
        let size = (item.text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: item.fontSize)])
        return CGRect(x: item.position.x - size.width / 2, y: item.position.y - size.height / 2,
                      width: size.width, height: size.height).insetBy(dx: -12, dy: -12)
    }

    private func frame(ofQR item: QRItem) -> CGRect {
        CGRect(x: item.position.x - item.size / 2, y: item.position.y - item.size / 2,
               width: item.size, height: item.size).insetBy(dx: -8, dy: -8)
    }

    private func frame(of selection: SelectedElement) -> CGRect? {
        switch selection {
        case .text(let id): return textItems.first { $0.id == id }.map(frame(ofText:))
        case .qr(let id):   return qrItems.first { $0.id == id }.map(frame(ofQR:))
        }
    }

    /// Topmost element under `point`. QR items render above text, and each array is reversed so the
    /// last-drawn (topmost) item wins.
    private func hitTest(_ point: CGPoint) -> SelectedElement? {
        for item in qrItems.reversed() where frame(ofQR: item).contains(point) { return .qr(item.id) }
        for item in textItems.reversed() where frame(ofText: item).contains(point) { return .text(item.id) }
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
                                position: clamp(CGPoint(x: src.position.x + 16, y: src.position.y + 16), in: box))
            textItems.append(copy)
            self.selection = .text(copy.id)
        case .qr(let id):
            guard let src = qrItems.first(where: { $0.id == id }) else { return }
            onCommitUndo(snapshot())
            let copy = QRItem(content: src.content, size: src.size, color: src.color,
                              position: clamp(CGPoint(x: src.position.x + 16, y: src.position.y + 16), in: box))
            qrItems.append(copy)
            self.selection = .qr(copy.id)
        }
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

    private func sizeValue(of target: SelectedElement) -> CGFloat? {
        switch target {
        case .text(let id): return textItems.first { $0.id == id }?.fontSize
        case .qr(let id):   return qrItems.first { $0.id == id }?.size
        }
    }

    private func setSize(of target: SelectedElement, to value: CGFloat, in box: CGSize) {
        switch target {
        case .text(let id):
            guard let i = textItems.firstIndex(where: { $0.id == id }) else { return }
            textItems[i].fontSize = min(max(value, 8), 200)
        case .qr(let id):
            guard let i = qrItems.firstIndex(where: { $0.id == id }) else { return }
            qrItems[i].size = min(max(value, 24), max(min(box.width, box.height), 24))
        }
    }

    private func move(_ target: SelectedElement, to position: CGPoint) {
        switch target {
        case .text(let id): if let i = textItems.firstIndex(where: { $0.id == id }) { textItems[i].position = position }
        case .qr(let id):   if let i = qrItems.firstIndex(where: { $0.id == id }) { qrItems[i].position = position }
        }
    }

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

    /// Pinch gesture: with an element selected, scales *that element* (font size / QR size) around
    /// its fixed center — `value` is already a relative scale factor, so resize is just
    /// `base size × value`. With nothing selected, it zooms the photo as before.
    private func zoomGesture(box: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if let target = selection {
                    if resizeBaseValue == nil {
                        resizeSnapshot = snapshot()
                        resizeBaseValue = sizeValue(of: target)
                    }
                    if let base = resizeBaseValue {
                        setSize(of: target, to: base * value, in: box)
                    }
                } else {
                    scale = max(1, baseScale * value)
                }
            }
            .onEnded { _ in
                if selection != nil {
                    if let snap = resizeSnapshot, snap != snapshot() { onCommitUndo(snap) }
                    resizeSnapshot = nil
                    resizeBaseValue = nil
                } else {
                    baseScale = scale
                }
            }
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if currentStroke == nil {
                    currentStroke = Stroke(color: color(drawColorIndex),
                                           lineWidth: drawLineWidth, points: [v.location])
                } else {
                    currentStroke?.points.append(v.location)
                }
            }
            .onEnded { _ in
                if let s = currentStroke, s.points.count > 1 {
                    onCommitUndo(snapshot())
                    strokes.append(s)
                }
                currentStroke = nil
            }
    }

    /// Unified tap+drag gesture for `.move`/`.text`/`.qr`. A near-stationary gesture is a tap
    /// (select / edit / place / deselect); movement drags the hit element, or pans the photo in
    /// `.move`. Element moves only begin once the finger clears `tapSlop`, so a plain tap never
    /// nudges the element it selects.
    private func selectionGesture(box: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if !dragStarted {
                    // Hit-test the start location exactly once, at the first onChanged.
                    dragStarted = true
                    dragTarget = hitTest(v.startLocation)
                    dragOrigin = dragTarget.flatMap(originOf)
                    if dragTarget != nil { preDragSnapshot = snapshot() }
                }
                if let target = dragTarget, let origin = dragOrigin {
                    if !dragExceededSlop,
                       abs(v.translation.width) < tapSlop, abs(v.translation.height) < tapSlop {
                        return   // still within tap territory — don't move yet
                    }
                    dragExceededSlop = true
                    move(target, to: clamp(CGPoint(x: origin.x + v.translation.width,
                                                   y: origin.y + v.translation.height), in: box))
                } else if mode == .move {
                    pan = CGSize(width: basePan.width + v.translation.width,
                                 height: basePan.height + v.translation.height)
                }
            }
            .onEnded { v in
                let isTap = abs(v.translation.width) < tapSlop && abs(v.translation.height) < tapSlop
                if isTap {
                    handleTap(at: v.location, in: box)
                } else if dragTarget != nil {
                    if dragExceededSlop, let snap = preDragSnapshot { onCommitUndo(snap) }
                } else if mode == .move {
                    basePan = pan   // photo pan committed
                }
                dragStarted = false
                dragTarget = nil
                dragOrigin = nil
                dragExceededSlop = false
                preDragSnapshot = nil
            }
    }

    /// Tap logic per mode: a hit selects; tapping empty space deselects first (guards accidental placement).
    /// In `.text` mode with nothing selected, empty space places a text item at that location
    /// (the Composer provides the pending text, size, and color).
    private func handleTap(at loc: CGPoint, in box: CGSize) {
        switch mode {
        case .draw:
            break
        case .move:
            let hit = hitTest(loc)
            selection = hit
            if let hit { onElementSelected(hit) }
        case .text:
            if let hit = hitTest(loc) {
                selection = hit
                onElementSelected(hit)
            } else if selection != nil {
                selection = nil
            } else {
                onPlaceText(loc)
            }
        case .qr:
            if let hit = hitTest(loc) {
                selection = hit
                onElementSelected(hit)
            } else if selection != nil {
                selection = nil
            } else if qrPlacementEnabled {
                let content = pendingQRContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { return }
                onCommitUndo(snapshot())
                let size = min(max(pendingQRSize, 24), max(min(box.width, box.height), 24))
                let item = QRItem(content: content, size: size,
                                  color: color(qrColorIndex), position: loc)
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

struct Stroke: Identifiable, Equatable {
    let id = UUID()
    var color: Color
    var lineWidth: CGFloat
    var points: [CGPoint]
}

struct TextItem: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var fontSize: CGFloat
    var color: Color
    var position: CGPoint
}

struct QRItem: Identifiable, Equatable {
    let id = UUID()
    var content: String
    var size: CGFloat
    var color: Color
    var position: CGPoint
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
