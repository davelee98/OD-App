import SwiftUI
import CoreImage.CIFilterBuiltins

/// The "physical canvas" for an e-paper screen: a fixed box locked to the panel's exact aspect
/// ratio. A photo is dropped inside and can be **panned** (`DragGesture`) and **zoomed**
/// (`MagnificationGesture`); the box `.clipped()`s it, acting as a hard crop bounding box — so the
/// user frames the shot the way it'll appear on the panel instead of stretching/padding it.
/// Draw / text / QR annotation overlays sit on top of the cropped photo and composite into it.
struct DisplayCanvasView: View {
    /// Exposure-adjusted photo to display (already run through `ImageProcessor.adjust`).
    let image: UIImage?
    /// Native pixel dimensions of the connected panel (drives the box aspect ratio).
    let displaySize: CGSize
    /// Scheme palette as SwiftUI colors, for rendering annotation strokes/text/QR on screen.
    let palette: [Color]
    let mode: CanvasMode

    // Photo crop transform (persisted by the Composer so it can render the final bitmap).
    @Binding var pan: CGSize
    @Binding var scale: CGFloat

    // Annotation layers.
    @Binding var strokes: [Stroke]
    @Binding var textItems: [TextItem]
    @Binding var qrItems: [QRItem]

    /// Reported back so the Composer can map canvas points → panel pixels when rendering.
    @Binding var canvasSize: CGSize

    // Annotation authoring parameters (current tool settings).
    var drawColorIndex: Int = 0
    var drawLineWidth: CGFloat = 3
    var pendingText: String = ""
    var pendingTextSize: CGFloat = 32
    var textColorIndex: Int = 0
    var pendingQRContent: String = ""
    var pendingQRSize: CGFloat = 120
    var qrColorIndex: Int = 0
    var onRequestTextEntry: () -> Void = {}

    // Live drawing + gesture accumulators.
    @State private var currentStroke: Stroke?
    @State private var basePan: CGSize = .zero
    @State private var baseScale: CGFloat = 1
    @State private var selectedTextID: UUID?

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
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(zoomGesture)
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
        ForEach($textItems) { $item in
            Text(item.text)
                .font(.system(size: item.fontSize))
                .foregroundColor(item.color)
                .position(item.position)
                .overlay(selectedTextID == item.id
                         ? RoundedRectangle(cornerRadius: 2).stroke(Color.blue, lineWidth: 1)
                         : nil)
                .onTapGesture { selectedTextID = item.id }
                .gesture(dragGesture(for: $item.position))
        }
    }

    private var qrOverlays: some View {
        ForEach($qrItems) { $item in
            if let qrImg = odGenerateQR(content: item.content, size: item.size, color: item.color) {
                Image(uiImage: qrImg)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: item.size, height: item.size)
                    .position(item.position)
                    .gesture(dragGesture(for: $item.position))
            }
        }
    }

    /// Transparent top layer that captures the mode-specific single-finger interaction.
    @ViewBuilder
    private func interactionLayer(box: CGSize) -> some View {
        switch mode {
        case .move:
            Color.clear.contentShape(Rectangle()).gesture(panGesture)
        case .draw:
            Color.clear.contentShape(Rectangle()).gesture(drawGesture)
        case .text:
            Color.clear.contentShape(Rectangle())
                .onTapGesture { loc in
                    if pendingText.isEmpty { onRequestTextEntry() }
                    else {
                        textItems.append(TextItem(text: pendingText, fontSize: pendingTextSize,
                                                  color: color(textColorIndex), position: loc))
                    }
                }
        case .qr:
            Color.clear.contentShape(Rectangle())
                .onTapGesture { loc in
                    qrItems.append(QRItem(content: pendingQRContent, size: pendingQRSize,
                                          color: color(qrColorIndex), position: loc))
                }
        }
    }

    // MARK: - Gestures

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in scale = max(1, baseScale * value) }
            .onEnded { _ in baseScale = scale }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                pan = CGSize(width: basePan.width + v.translation.width,
                             height: basePan.height + v.translation.height)
            }
            .onEnded { _ in basePan = pan }
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
                if let s = currentStroke, s.points.count > 1 { strokes.append(s) }
                currentStroke = nil
            }
    }

    private func dragGesture(for position: Binding<CGPoint>) -> some Gesture {
        DragGesture().onChanged { v in position.wrappedValue = v.location }
    }
}

// MARK: - Shared QR helper (used by the canvas and the final composite render)

func odGenerateQR(content: String, size: CGFloat, color: Color) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(content.utf8)
    filter.correctionLevel = "M"
    guard size > 0, let ciImage = filter.outputImage, ciImage.extent.width > 0 else { return nil }
    let scale = size / ciImage.extent.width
    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return UIImage(ciImage: scaled)
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

struct Stroke: Identifiable {
    let id = UUID()
    var color: Color
    var lineWidth: CGFloat
    var points: [CGPoint]
}

struct TextItem: Identifiable {
    let id = UUID()
    var text: String
    var fontSize: CGFloat
    var color: Color
    var position: CGPoint
}

struct QRItem: Identifiable {
    let id = UUID()
    var content: String
    var size: CGFloat
    var color: Color
    var position: CGPoint
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
