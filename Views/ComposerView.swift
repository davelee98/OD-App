import SwiftUI
import PhotosUI
import CoreBluetooth

/// Serial queue for live canvas adjustments. Dragging an adjustment slider fires many refreshes;
/// running them here one at a time (instead of on the global concurrent queue) stops a burst from
/// stacking up simultaneous Core Image renders and spiking memory. File-scope so it survives the
/// SwiftUI struct being recreated on every state change.
private let composerCanvasQueue = DispatchQueue(label: "org.opendisplay.composer.canvas", qos: .userInitiated)

/// Longest edge (in pixels) of the downscaled photo used *only* for the on-screen canvas preview.
/// The full-resolution photo is still what gets rendered and sent to the panel.
private let canvasPreviewMaxDimension: CGFloat = 1600

/// The composer's tool chips. Exactly one is active at a time (radio-style); `.photo` is the
/// resting state (pinch/drag the background). `.draw/.text/.qr` map to a `CanvasMode`; the rest
/// (`.adjustments/.dithering/.colorMode`) are photo-level tools that leave the canvas in `.move`.
enum ComposerTool: String, CaseIterable, Identifiable {
    case photo, draw, text, qr, adjustments, dithering, colorMode
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photo: return "Photo"
        case .draw: return "Draw"
        case .text: return "Text"
        case .qr: return "QR"
        case .adjustments: return "Adjust"
        case .dithering: return "Dithering"
        case .colorMode: return "Color Mode"
        }
    }
    var systemImage: String {
        switch self {
        case .photo: return "photo"
        case .draw: return "pencil.tip"
        case .text: return "textformat"
        case .qr: return "qrcode"
        case .adjustments: return "slider.horizontal.3"
        case .dithering: return "square.grid.3x3"
        case .colorMode: return "paintpalette"
        }
    }
}

/// Compose a photo for one saved e-paper display and send it. Wraps `DisplayCanvasView` (crop /
/// zoom + annotations) and adds e-ink photo adjustments (brightness / contrast / shadows /
/// highlight recovery / saturation), a dithered Preview, and smart defaults so a non-technical
/// user rarely touches the Advanced controls.
struct ComposerView: View {
    let entity: SavedDisplayEntity
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    // Photo + crop transform.
    @State private var photoItem: PhotosPickerItem?
    @State private var baseImage: UIImage?      // original full-res photo (orientation-normalized), used for the final send
    @State private var previewBase: UIImage?    // downscaled copy of baseImage, adjusted live for the canvas
    @State private var canvasImage: UIImage?    // exposure-adjusted copy shown on the canvas
    @State private var canvasRenderToken = 0    // drops stale async adjustment results from a fast slider drag
    @State private var pan: CGSize = .zero
    @State private var scale: CGFloat = 1
    /// Bumped whenever `pan`/`scale` are force-reset from outside a gesture (new photo, Reset
    /// button, full page reset) — tells `DisplayCanvasView` to also drop its internal gesture
    /// baselines (`basePan`/`baseScale`), which otherwise stay stale and make the *next* drag or
    /// pinch jump using an outdated reference point.
    @State private var transformResetToken = 0

    // Annotations.
    @State private var activeTool: ComposerTool = .photo
    @State private var strokes: [Stroke] = []
    @State private var textItems: [TextItem] = []
    @State private var qrItems: [QRItem] = []
    @State private var canvasSize: CGSize = .zero
    @State private var selection: SelectedElement?

    // Annotation tool settings.
    @State private var drawColorIndex = 0
    @State private var drawLineWidth: CGFloat = 3
    @State private var pendingText = ""
    @State private var pendingTextSize: CGFloat = 32
    @State private var textColorIndex = 0
    @State private var pendingQRContent = "https://opendisplay.org"
    @State private var pendingQRSize: CGFloat = 120
    @State private var qrColorIndex = 0
    @State private var qrPlacementArmed = true         // disarmed after each stamp; re-armed by edits
    @State private var qrContentUndoID: UUID?          // selected-QR content edits push undo once per selection

    // Undo/redo: chronological snapshots of the annotation layers (photo/adjustments not covered).
    @State private var undoStack: [CanvasSnapshot] = []
    @State private var redoStack: [CanvasSnapshot] = []
    @State private var showResetConfirm = false

    // Adjustments (neutral defaults = pass-through).
    @State private var adjustments = ImageAdjustments()

    // Dithering (smart default, overridable in Advanced).
    @State private var colorScheme: UInt8 = 0
    @State private var dithering: DitheringMode = .floydSteinberg
    @State private var ditheringOverridden = false
    // Render against the panel's measured ink colors (enables tone compression). Off = idealized palette.
    @State private var useMeasuredPalette = false

    // Preview.
    @State private var previewImage: UIImage?
    @State private var showPreview = false

    // Send overlay imagery: the full-color composite shows immediately, then the dithered panel
    // preview is revealed left→right in lockstep with upload progress.
    @State private var sendCompositeImage: UIImage?
    @State private var sendDitheredImage: UIImage?

    // Connection gate.
    @State private var isWaitingForConnection = false
    @State private var hasPhysicalConnection = false
    @State private var connectionAlertMessage: String?
    @State private var connectionTimeoutTask: Task<Void, Never>?

    private var targetIdentifier: UUID? { UUID(uuidString: entity.id) }
    private var device: ODDevice? {
        guard let targetIdentifier,
              ble.connectedDevice?.peripheral.identifier == targetIdentifier else { return nil }
        return ble.connectedDevice
    }
    private var displayWidth: Int {
        let w = device?.config?.displayWidth ?? entity.width
        return w > 0 ? w : entity.width
    }
    private var displayHeight: Int {
        let h = device?.config?.displayHeight ?? entity.height
        return h > 0 ? h : entity.height
    }
    private var displaySize: CGSize { CGSize(width: displayWidth, height: displayHeight) }

    /// The canvas interaction mode implied by the active tool. Only Draw/Text/QR change how the
    /// canvas responds to taps; the photo-level tools leave it in `.move` (pinch/drag background).
    private var mode: CanvasMode {
        switch activeTool {
        case .draw: return .draw
        case .text: return .text
        case .qr: return .qr
        case .photo, .adjustments, .dithering, .colorMode: return .move
        }
    }

    private var schemePaletteColors: [Color] {
        let rgb = ImageProcessor.palettes[colorScheme] ?? ImageProcessor.palettes[0]!
        return rgb.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) }
    }
    private var hasContent: Bool {
        baseImage != nil || !strokes.isEmpty || !textItems.isEmpty || !qrItems.isEmpty
    }

    var body: some View {
        Group {
            // Compact vertical height = phone landscape (more reliable than horizontal size class,
            // which stays .compact on most landscape phones). iPad stays regular → portrait.
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .navigationTitle(entity.friendlyName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { sendToolbarButton }
        .overlay { if isWaitingForConnection { connectionOverlay } }
        .modifier(UploadStatusPresenter(phase: device?.uploadPhase, overlay: uploadStatusOverlay,
                                        onAutoDismiss: autoDismissUploadOutcome))
        .onAppear {
            ensureConnection()
        }
        .onDisappear {
            connectionTimeoutTask?.cancel()
            device?.acknowledgeUploadOutcome()
        }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .onChange(of: adjustments) { _, _ in refreshCanvasImage() }
        .onChange(of: activeTool) { _, _ in selection = nil }
        .onChange(of: pendingQRContent) { _, _ in qrPlacementArmed = true }
        .onChange(of: selection) { _, _ in qrContentUndoID = nil }
        .onChange(of: ble.connectedDevice?.deviceID) { _, deviceID in
            ble.trace("Composer connectedDevice changed; target=\(entity.id), current=\(deviceID ?? "nil"), waiting=\(isWaitingForConnection)")
            if let identifier = targetIdentifier,
               ble.connectedDevice?.peripheral.identifier == identifier,
               ble.isPeripheralConnected(identifier) {
                // The radio link succeeded. GATT setup may still be finishing, so keep the
                // connecting overlay but never let the discovery watchdog tear down this link.
                hasPhysicalConnection = true
                connectionTimeoutTask?.cancel()
            } else if deviceID == nil, isWaitingForConnection, hasPhysicalConnection {
                connectionFailed("The Bluetooth connection to the display was lost.")
            }
        }
        .onChange(of: device?.connectionState) { _, state in handleConnectionState(state) }
        .onChange(of: ble.connectionError) { _, error in
            if isWaitingForConnection, let error { connectionFailed(error) }
        }
        .onChange(of: ble.bluetoothState) { _, state in handleBluetoothState(state) }
        .onChange(of: device?.config) { _, config in
            if let config {
                entity.apply(config: config)
                applyScheme(config.colorScheme)
            }
        }
        .sheet(isPresented: $showPreview) { previewSheet }
        .confirmationDialog("Reset the page?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset Page", role: .destructive) { resetPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the photo and every annotation. This can't be undone.")
        }
        .alert("Unable to Connect", isPresented: connectionAlertIsPresented) {
            Button("OK") { dismiss() }
        } message: {
            Text(connectionAlertMessage ?? "The display could not be reached.")
        }
    }

    // MARK: - Layouts

    /// Portrait (regular height): canvas on top, then the always-visible action row, the tool
    /// chip bar, and the selected tool's controls scrolling below.
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            canvas
            actionRow
            toolChipBar
            Divider()
            ScrollView { activeToolPanel.padding() }
        }
    }

    /// Landscape (compact height): canvas on the left, a fixed-width scrolling control column right.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            canvas
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    actionRow
                    toolChipBar
                    Divider()
                    activeToolPanel.padding()
                }
            }
            .frame(width: 340)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Canvas + upload overlay

    private var canvas: some View {
        DisplayCanvasView(
            image: canvasImage,
            displaySize: displaySize,
            palette: schemePaletteColors,
            mode: mode,
            pan: $pan, scale: $scale, transformResetToken: transformResetToken,
            strokes: $strokes, textItems: $textItems, qrItems: $qrItems,
            canvasSize: $canvasSize,
            selection: $selection,
            drawColorIndex: drawColorIndex, drawLineWidth: drawLineWidth,
            pendingText: $pendingText, pendingTextSize: pendingTextSize, textColorIndex: textColorIndex,
            pendingQRContent: pendingQRContent, pendingQRSize: pendingQRSize, qrColorIndex: qrColorIndex,
            qrPlacementEnabled: qrPlacementArmed,
            onPlaceText: { loc in placeTextAtPoint(loc) },
            onElementSelected: { element in
                switch element {
                case .text: activeTool = .text
                case .qr: activeTool = .qr
                }
            },
            onQRPlaced: { qrPlacementArmed = false },
            onCommitUndo: { pushUndo($0) }
        )
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var connectionOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.92)
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(entity.friendlyName)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(true)
    }

    /// Full-screen send status: progress → success → error, shown whenever a send is in flight or
    /// just finished. Mutually exclusive with `connectionOverlay` (sending requires a connection).
    @ViewBuilder
    private var uploadStatusOverlay: some View {
        if let device, device.uploadPhase != .idle {
            UploadStatusOverlay(
                phase: device.uploadPhase,
                progress: device.uploadProgress,
                status: device.uploadStatus,
                deviceName: entity.friendlyName,
                elapsed: device.uploadElapsed,
                byteCount: device.uploadByteCount,
                compositeImage: sendCompositeImage,
                ditheredImage: sendDitheredImage,
                onDismiss: { device.acknowledgeUploadOutcome() },
                onRetry: { device.acknowledgeUploadOutcome(); sendPhoto() }
            )
            .transition(.opacity)
        }
    }

    /// Auto-dismisses a terminal send status: success after ~2s, error after ~6s (or the user taps
    /// Dismiss/Retry sooner). Bound to `.task(id: device?.uploadPhase)` so it cancels/restarts on
    /// each phase change.
    private func autoDismissUploadOutcome() async {
        guard let device else { return }
        let delay: Duration
        switch device.uploadPhase {
        case .succeeded: delay = .seconds(2)
        case .failed:    delay = .seconds(6)
        case .idle, .preparing, .sending: return
        }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        device.acknowledgeUploadOutcome()
    }

    /// Always-visible actions directly under the canvas, independent of the selected tool.
    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { generatePreview() } label: {
                Label("Preview", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .disabled(!hasContent)
            .font(.caption)

            Spacer()

            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(undoStack.isEmpty)

            Button { redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .disabled(redoStack.isEmpty)

            Button(role: .destructive) { showResetConfirm = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(!hasContent)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Horizontally-scrolling tool chips. Exactly one is active; tapping switches tools and
    /// reveals that tool's panel below.
    private var toolChipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ComposerTool.allCases) { tool in
                    let isActive = activeTool == tool
                    Button { activeTool = tool } label: {
                        Label(tool.title, systemImage: tool.systemImage)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(isActive ? Color.accentColor : Color(.secondarySystemBackground))
                            )
                            .foregroundStyle(isActive ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Active tool panel (per selected chip)

    @ViewBuilder
    private var activeToolPanel: some View {
        switch activeTool {
        case .photo:   photoPanel
        case .draw:    drawPanel
        case .text:    textPanel
        case .qr:      qrPanel
        case .adjustments: adjustmentsSection
        case .dithering:   ditheringPanel
        case .colorMode:   colorModePanel
        }
    }

    private var photoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(baseImage == nil ? "Choose Photo" : "Change Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            HStack {
                Label("Pinch to zoom · drag to reposition", systemImage: "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { resetToOriginalState() }
                    .font(.caption).buttonStyle(.bordered)
                    .disabled(isAtOriginalState)
            }
        }
    }

    private var drawPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "line.diagonal").font(.caption).foregroundStyle(.secondary)
                Slider(value: $drawLineWidth, in: 1...20, step: 1)
                Text("\(Int(drawLineWidth))px").font(.caption).frame(width: 40)
            }
            colorSwatchPicker(selection: $drawColorIndex)
        }
    }

    // Inspector pattern: with a text element selected the controls edit *it* live;
    // otherwise they set the defaults for the next element. Tapping canvas places the pending text.
    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = selectedTextID {
                Text("Drag to move · pinch to resize")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Text", text: textContentBinding(for: id))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Image(systemName: "textformat.size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: textSizeBinding(for: id), in: 8...200, step: 2) { editing in
                        if editing { pushUndo() }
                    }
                    Text("\(Int(textItems.first(where: { $0.id == id })?.fontSize ?? 0))pt")
                        .font(.caption).frame(width: 44)
                }
                colorSwatchPicker(selection: textColorBinding(for: id, pushesUndo: true))
            } else {
                Text("Enter text below and tap canvas to place")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Text", text: $pendingText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Image(systemName: "textformat.size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $pendingTextSize, in: 8...200, step: 2)
                    Text("\(Int(pendingTextSize))pt").font(.caption).frame(width: 44)
                }
                colorSwatchPicker(selection: $textColorIndex)
            }
        }
    }

    private var qrPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id = selectedQRID {
                Text("Editing the selected QR code · pinch to resize")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("QR content (URL or text)", text: qrContentBinding(for: id))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Image(systemName: "qrcode").font(.caption).foregroundStyle(.secondary)
                    Slider(value: qrSizeBinding(for: id), in: 40...300, step: 2) { editing in
                        if editing { pushUndo() }
                    }
                    Text("\(Int(qrItems.first(where: { $0.id == id })?.size ?? 0))pt")
                        .font(.caption).frame(width: 44)
                }
                colorSwatchPicker(selection: qrColorBinding(for: id))
            } else {
                Text(qrHint)
                    .font(.caption).foregroundStyle(.secondary)
                TextField("QR content (URL or text)", text: $pendingQRContent)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                HStack {
                    Image(systemName: "qrcode").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $pendingQRSize, in: 40...300, step: 2)
                    Text("\(Int(pendingQRSize))pt").font(.caption).frame(width: 44)
                    Button("Add QR") { placeQRAtCenter() }
                        .buttonStyle(.bordered)
                        .disabled(pendingQRContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                colorSwatchPicker(selection: $qrColorIndex)
            }
        }
    }

    private var colorModePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set by the display hardware — expert override only", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)

            Picker("Color mode", selection: $colorScheme) {
                ForEach(ColorScheme.allCases) { scheme in
                    Text(scheme.displayName).tag(scheme.rawValue)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: colorScheme) { _, _ in
                if !ditheringOverridden { dithering = Self.smartDithering(for: colorScheme) }
                refreshCanvasImage()
                resetAnnotationColors()
            }

            Text("This panel's color type is read from the connected display. Overriding it only changes the on-screen palette — Preview and Send still use the hardware's real mode. Change it only if you know your panel's exact type.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qrHint: String {
        if pendingQRContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter QR content below to place a code"
        }
        return qrPlacementArmed ? "Tap the canvas to place the QR code"
                                : "Change the content or tap Add QR to place another"
    }

    // MARK: - Selected-element inspector bindings

    private var selectedTextID: UUID? {
        if case .text(let id) = selection { return id }
        return nil
    }

    private var selectedQRID: UUID? {
        if case .qr(let id) = selection { return id }
        return nil
    }

    private func textSizeBinding(for id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { textItems.first(where: { $0.id == id })?.fontSize ?? pendingTextSize },
            set: { newValue in
                if let i = textItems.firstIndex(where: { $0.id == id }) { textItems[i].fontSize = newValue }
            }
        )
    }

    private func textContentBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { textItems.first(where: { $0.id == id })?.text ?? pendingText },
            set: { newValue in
                if let i = textItems.firstIndex(where: { $0.id == id }) { textItems[i].text = newValue }
            }
        )
    }

    /// Swatch index ↔ the selected text item's color. A swatch tap is a single discrete change, so
    /// the binding itself records the undo entry (`pushesUndo`); the edit sheet passes `false`
    /// because opening it already pushed one entry covering the whole editing session.
    private func textColorBinding(for id: UUID, pushesUndo: Bool) -> Binding<Int> {
        Binding(
            get: {
                guard let color = textItems.first(where: { $0.id == id })?.color,
                      let index = schemePaletteColors.firstIndex(of: color) else { return textColorIndex }
                return index
            },
            set: { newIndex in
                guard let i = textItems.firstIndex(where: { $0.id == id }) else { return }
                let newColor = schemePaletteColors[safe: newIndex] ?? .black
                guard textItems[i].color != newColor else { return }
                if pushesUndo { pushUndo() }
                textItems[i].color = newColor
                textColorIndex = newIndex
            }
        )
    }

    private func qrSizeBinding(for id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { qrItems.first(where: { $0.id == id })?.size ?? pendingQRSize },
            set: { newValue in
                if let i = qrItems.firstIndex(where: { $0.id == id }) { qrItems[i].size = newValue }
            }
        )
    }

    /// Selected-QR payload edits arrive per keystroke; record one undo entry per selection so
    /// Undo restores the pre-edit payload instead of stepping back a character at a time.
    private func qrContentBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { qrItems.first(where: { $0.id == id })?.content ?? pendingQRContent },
            set: { newValue in
                guard let i = qrItems.firstIndex(where: { $0.id == id }) else { return }
                if qrContentUndoID != id {
                    pushUndo()
                    qrContentUndoID = id
                }
                qrItems[i].content = newValue
            }
        )
    }

    private func qrColorBinding(for id: UUID) -> Binding<Int> {
        Binding(
            get: {
                guard let color = qrItems.first(where: { $0.id == id })?.color,
                      let index = schemePaletteColors.firstIndex(of: color) else { return qrColorIndex }
                return index
            },
            set: { newIndex in
                guard let i = qrItems.firstIndex(where: { $0.id == id }) else { return }
                let newColor = schemePaletteColors[safe: newIndex] ?? .black
                guard qrItems[i].color != newColor else { return }
                pushUndo()
                qrItems[i].color = newColor
                qrColorIndex = newIndex
            }
        )
    }

    /// Grayscale schemes (0 = B/W, 5 = 4-gray, 6 = 16-gray) have no color to saturate.
    private var schemeHasColor: Bool {
        colorScheme != 0 && colorScheme != 5 && colorScheme != 6
    }

    /// Presents the stored `highlights` value (CI range `0.3...1`, `1` = neutral) as a left-anchored
    /// 0...1 "recovery" slider: `0` (left) feeds `1.0` (no change) to `CIHighlightShadowAdjust`, and
    /// `1` (right) feeds `0.3` (maximum highlight recovery). Keeps the underlying CI semantics intact
    /// while placing neutral at the far left instead of the far-right edge of the raw range.
    private var highlightRecoveryBinding: Binding<Float> {
        Binding(
            get: { (1 - adjustments.highlights) / 0.7 },
            set: { adjustments.highlights = 1 - $0 * 0.7 }
        )
    }

    private var adjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Adjustments", systemImage: "slider.horizontal.3").font(.subheadline).bold()
                Spacer()
                if !adjustments.isNeutral {
                    Button("Reset adjustments") { adjustments = .neutral }
                        .font(.caption)
                }
            }
            adjustmentSlider(icon: "circle.lefthalf.filled", title: "Brightness",
                             value: $adjustments.brightness, range: -0.4...0.4, neutral: 0)
            adjustmentSlider(icon: "circle.righthalf.filled", title: "Contrast",
                             value: $adjustments.contrast, range: 0.5...1.5, neutral: 1)
            adjustmentSlider(icon: "moon.stars", title: "Shadows",
                             value: $adjustments.shadows, range: -1...1, neutral: 0)
            adjustmentSlider(icon: "sun.max", title: "Highlight Recovery",
                             value: highlightRecoveryBinding, range: 0...1, neutral: 0)
            if schemeHasColor {
                adjustmentSlider(icon: "drop.halffull", title: "Saturation",
                                 value: $adjustments.saturation, range: 0...2, neutral: 1)
            }
        }
    }

    private var ditheringPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dithering", systemImage: "square.grid.3x3").font(.subheadline).bold()

            Toggle(isOn: $useMeasuredPalette) {
                Label("Measured palette", systemImage: "swatchpalette").font(.caption)
            }
            .onChange(of: useMeasuredPalette) { _, _ in refreshCanvasImage() }
            Text("Simulates the panel's real ink colors. Enables Tone compression.")
                .font(.caption2).foregroundStyle(.secondary)

            adjustmentSlider(icon: "arrow.down.right.and.arrow.up.left", title: "Tone",
                             value: $adjustments.toneCompression, range: 0...1, neutral: 0)
                .disabled(!useMeasuredPalette)
                .opacity(useMeasuredPalette ? 1 : 0.4)

            Divider().padding(.vertical, 2)

            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary).frame(width: 20)
                Text("Dithering").font(.caption).frame(width: 78, alignment: .leading)
                Picker("Dithering", selection: $dithering) {
                    ForEach(DitheringMode.allCases) { m in Text(m.displayName).tag(m) }
                }
                .pickerStyle(.menu)
                .onChange(of: dithering) { _, _ in ditheringOverridden = true }
            }
            Text("Defaults are chosen for this panel's palette. Atkinson suits black-and-white e-ink; Floyd-Steinberg suits multi-color.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adjustmentSlider(icon: String, title: String,
                                  value: Binding<Float>, range: ClosedRange<Float>, neutral: Float) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(.caption).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range)
            Button {
                value.wrappedValue = neutral
            } label: {
                Image(systemName: "arrow.counterclockwise").font(.caption2)
            }
            .buttonStyle(.borderless)
            .disabled(value.wrappedValue == neutral)
        }
    }

    @ViewBuilder
    private func colorSwatchPicker(selection: Binding<Int>) -> some View {
        let palette = schemePaletteColors
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36, maximum: 36))], spacing: 6) {
            ForEach(palette.indices, id: \.self) { i in
                Button { selection.wrappedValue = i } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette[i])
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selection.wrappedValue == i ? Color.accentColor : Color.primary.opacity(0.3),
                                        lineWidth: selection.wrappedValue == i ? 3 : 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Toolbar / sheets

    @ToolbarContentBuilder
    private var sendToolbarButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                sendPhoto()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .labelStyle(.titleAndIcon)
            .disabled(device?.connectionState != .connected || device?.isUploading == true || !hasContent)
        }
    }

    private var previewSheet: some View {
        NavigationStack {
            VStack {
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .border(Color(.systemGray4))
                        .padding()
                } else {
                    ProgressView("Rendering…")
                }
                Text("Approximate dithered result on the \(displayWidth)×\(displayHeight) panel.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom)
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPreview = false } } }
        }
    }

    // MARK: - Actions

    private var connectionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { connectionAlertMessage != nil },
            set: { if !$0 { connectionAlertMessage = nil } }
        )
    }

    private func ensureConnection() {
        ble.trace("Composer ensureConnection; target=\(entity.id), current=\(ble.connectedDevice?.deviceID ?? "nil"), appState=\(String(describing: device?.connectionState)), peripheralState=\(device?.peripheral.state.rawValue ?? -1)")
        if device?.connectionState == .connected {
            isWaitingForConnection = false
            syncFromDevice()
            return
        }

        guard let identifier = UUID(uuidString: entity.id) else {
            connectionFailed("This saved display has an invalid Bluetooth identifier.")
            return
        }

        isWaitingForConnection = true
        hasPhysicalConnection = false
        ble.reconnect(to: identifier)
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                ble.trace("Composer timeout fired; target=\(identifier.uuidString), current=\(ble.connectedDevice?.deviceID ?? "nil"), appState=\(String(describing: device?.connectionState)), peripheralState=\(device?.peripheral.state.rawValue ?? -1), physicallyConnected=\(ble.isPeripheralConnected(identifier))")
                // Core Bluetooth may be connected while service discovery is still completing.
                // That is not a failed reconnect and must not be cancelled by this watchdog.
                if ble.isPeripheralConnected(identifier) {
                    connectionTimeoutTask = nil
                } else if device?.connectionState != .connected {
                    connectionFailed("The display did not respond. Make sure it is powered on and nearby.")
                }
            }
        }
    }

    private func handleConnectionState(_ state: ConnectionState?) {
        ble.trace("Composer observed appState=\(String(describing: state)); target=\(entity.id), current=\(ble.connectedDevice?.deviceID ?? "nil")")
        switch state {
        case .connected:
            connectionTimeoutTask?.cancel()
            isWaitingForConnection = false
            hasPhysicalConnection = true
            syncFromDevice()
        case .failed:
            connectionFailed(device?.lastError ?? "The display connection failed.")
        default:
            break
        }
    }

    private func handleBluetoothState(_ state: CBManagerState) {
        guard isWaitingForConnection else { return }
        switch state {
        case .poweredOff:
            connectionFailed("Bluetooth is turned off. Turn it on and try again.")
        case .unauthorized:
            connectionFailed("Bluetooth access is not allowed for this app.")
        case .unsupported:
            connectionFailed("Bluetooth is not supported on this device.")
        default:
            break
        }
    }

    private func connectionFailed(_ message: String) {
        guard connectionAlertMessage == nil else { return }
        ble.trace("Composer connectionFailed: \(message)")
        connectionTimeoutTask?.cancel()
        isWaitingForConnection = false
        if let identifier = UUID(uuidString: entity.id) {
            ble.cancelReconnect(to: identifier)
        }
        connectionAlertMessage = message
    }

    private func syncFromDevice() {
        // Repair the registry whenever a config is already in hand — the .onChange(of: device?.config)
        // above only fires when it *changes* while this view is visible, so a config loaded before the
        // Composer appeared (e.g. the auto-read on connect) would otherwise never reach the entity.
        if let config = device?.config {
            entity.apply(config: config)
            applyScheme(config.colorScheme)
        } else {
            applyScheme(UInt8(clamping: entity.colorScheme))
            device?.readConfig()
        }
    }

    private func applyScheme(_ scheme: UInt8) {
        colorScheme = scheme
        if !ditheringOverridden { dithering = Self.smartDithering(for: scheme) }
        resetAnnotationColors()
    }

    /// Whether the photo's transform and processing settings already match what they'd be right
    /// after opening the Composer — i.e. nothing left for the Photo panel's "Reset" to undo.
    /// Deliberately excludes the photo itself and annotations, which are `resetPage()`'s job.
    private var isAtOriginalState: Bool {
        pan == .zero && scale == 1 && adjustments.isNeutral && !useMeasuredPalette && !ditheringOverridden
    }

    /// Restores the photo transform and processing settings (crop, adjustments, tone compression,
    /// measured-palette toggle, dithering) to what they were before the user touched anything this
    /// session — the smart dithering default for the current scheme, same as on first load. Leaves
    /// the chosen photo and annotations untouched (that's the separate, destructive "Reset Page").
    private func resetToOriginalState() {
        pan = .zero; scale = 1
        transformResetToken &+= 1
        adjustments = .neutral
        useMeasuredPalette = false
        ditheringOverridden = false
        dithering = Self.smartDithering(for: colorScheme)
        // `adjustments`/`useMeasuredPalette` each already drive `refreshCanvasImage()` via their
        // own `.onChange`; dithering/pan/scale don't affect `canvasImage` so need no extra refresh.
    }

    private func resetAnnotationColors() {
        drawColorIndex = 0; textColorIndex = 0; qrColorIndex = 0
    }

    static func smartDithering(for scheme: UInt8) -> DitheringMode {
        scheme == 0 ? .atkinson : .floydSteinberg
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        // `PhotosPickerItem` is Equatable on the underlying asset identifier, so re-picking the
        // *same* photo produces a value SwiftUI considers unchanged — `.onChange(of: photoItem)`
        // then never fires and this function never runs again. Clearing the binding immediately
        // guarantees every subsequent PhotosPicker selection, including the same asset, is a
        // genuine nil → item transition that always triggers onChange.
        photoItem = nil
        item.loadTransferable(type: Data.self) { result in
            // `loadTransferable` already calls back off the main thread — do the heavy
            // orientation-normalize + downscale here so a large photo doesn't block the UI.
            guard case .success(let data?) = result, let img = UIImage(data: data) else {
                if case .failure(let error) = result {
                    self.ble.trace("Composer photo load failed: \(error)")
                }
                return
            }
            let normalized = img.orientationNormalized()
            let preview = normalized.downscaled(maxDimension: canvasPreviewMaxDimension)
            DispatchQueue.main.async {
                self.baseImage = normalized
                self.previewBase = preview
                self.pan = .zero; self.scale = 1
                self.transformResetToken &+= 1
                self.refreshCanvasImage()
            }
        }
    }

    /// Recompute the adjusted photo shown on the canvas. Runs on a serial queue over the *downscaled*
    /// `previewBase` (not the full-res photo) and drops results superseded by a newer request, so a
    /// fast slider drag can't pile up full-resolution Core Image renders and exhaust memory.
    private func refreshCanvasImage() {
        guard let preview = previewBase else { canvasImage = nil; return }
        canvasRenderToken &+= 1
        let token = canvasRenderToken
        let a = adjustments
        let scheme = colorScheme
        let measured = useMeasuredPalette
        composerCanvasQueue.async {
            var adjusted = ImageProcessor.adjust(preview, adjustments: a)
            if measured, a.toneCompression > 0 {
                adjusted = ImageProcessor.compressTone(adjusted, colorScheme: scheme, strength: Double(a.toneCompression))
            }
            DispatchQueue.main.async {
                guard token == self.canvasRenderToken else { return }   // a newer adjustment won
                self.canvasImage = adjusted
            }
        }
    }

    /// Fully reset the canvas to a fresh state: photo, transform, annotations,
    /// tool settings, adjustments, dithering, and preview all return to defaults.
    private func resetPage() {
        // Photo + crop transform.
        baseImage = nil; previewBase = nil; canvasImage = nil; photoItem = nil
        pan = .zero; scale = 1; transformResetToken &+= 1

        // Annotations.
        activeTool = .photo
        strokes.removeAll(); textItems.removeAll(); qrItems.removeAll()
        selection = nil

        // Annotation tool settings.
        drawColorIndex = 0
        drawLineWidth = 3
        pendingText = ""
        pendingTextSize = 32
        textColorIndex = 0
        pendingQRContent = "https://opendisplay.org"
        pendingQRSize = 120
        qrColorIndex = 0
        qrPlacementArmed = true

        // Undo history covers only annotations; a full reset invalidates it.
        undoStack.removeAll()
        redoStack.removeAll()

        // Adjustments.
        adjustments = .neutral

        // Dithering. Re-derive the scheme from the connected panel so Preview and Send agree;
        // clear the override first so applyScheme reapplies the smart dithering default.
        ditheringOverridden = false
        useMeasuredPalette = false
        applyScheme(device?.config?.colorScheme ?? UInt8(clamping: entity.colorScheme))

        // Preview.
        previewImage = nil
        showPreview = false
    }

    // MARK: - Text placement / editing

    /// Place the pending text at the given position, select it, and clear the buffer.
    private func placeTextAtPoint(_ position: CGPoint) {
        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushUndo()
        let item = TextItem(text: trimmed, fontSize: pendingTextSize,
                            color: schemePaletteColors[safe: textColorIndex] ?? .black,
                            position: position)
        textItems.append(item)
        selection = .text(item.id)
    }

    // MARK: - QR placement

    private func placeQRAtCenter() {
        let content = pendingQRContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        pushUndo()
        let box = canvasSize
        let size = box.width > 0 ? min(max(pendingQRSize, 24), max(min(box.width, box.height), 24))
                                 : pendingQRSize
        let item = QRItem(content: content, size: size,
                          color: schemePaletteColors[safe: qrColorIndex] ?? .black,
                          position: CGPoint(x: max(box.width, 1) / 2, y: max(box.height, 1) / 2))
        qrItems.append(item)
        selection = .qr(item.id)
        qrPlacementArmed = false
    }

    // MARK: - Undo / redo

    private func currentSnapshot() -> CanvasSnapshot {
        CanvasSnapshot(strokes: strokes, textItems: textItems, qrItems: qrItems)
    }

    private func applySnapshot(_ snap: CanvasSnapshot) {
        strokes = snap.strokes
        textItems = snap.textItems
        qrItems = snap.qrItems
    }

    /// Record the state to restore on Undo. Pass the pre-mutation snapshot when the change already
    /// happened (the canvas does this); omit it to capture current state before mutating.
    private func pushUndo(_ snap: CanvasSnapshot? = nil) {
        undoStack.append(snap ?? currentSnapshot())
        redoStack.removeAll()
        if undoStack.count > 60 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applySnapshot(snap)
        selection = nil
    }

    private func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applySnapshot(snap)
        selection = nil
    }

    private func generatePreview() {
        refreshCanvasImage()
        showPreview = true
        previewImage = nil
        // Read the scheme from the connected device at render time. The config can arrive after this
        // view appears; using the initial @State value would encode a 1bpp frame for a 4-gray panel.
        let w = displayWidth, h = displayHeight
        let scheme = device?.config?.colorScheme ?? colorScheme
        let dith = dithering
        let measured = useMeasuredPalette
        let tone = Double(adjustments.toneCompression)
        let snapshot = compositeSnapshot()
        DispatchQueue.global(qos: .userInitiated).async {
            let composite = Self.renderComposite(snapshot)
            let preview = ImageProcessor.preview(image: composite, width: w, height: h,
                                                 colorScheme: scheme, dithering: dith,
                                                 useMeasuredPalette: measured, toneCompression: tone)
            DispatchQueue.main.async { self.previewImage = preview }
        }
    }

    private func sendPhoto() {
        guard let device else { return }
        guard let deviceConfig = device.config else {
            device.failUpload("Waiting for a valid device configuration before encoding the image.")
            device.readConfig()
            return
        }
        // Show the sending overlay immediately, then do the (possibly slow) full-resolution render
        // and dithering pass off the main thread — otherwise the tap appears to hang for a beat
        // while the composite is rasterized before any status UI can appear.
        device.beginUpload()
        sendCompositeImage = nil   // drop any prior send's imagery before the new one renders
        sendDitheredImage = nil
        let w = displayWidth, h = displayHeight
        let scheme = deviceConfig.colorScheme
        let dith = dithering
        let measured = useMeasuredPalette
        let tone = Double(adjustments.toneCompression)
        let snapshot = compositeSnapshot()   // capture @State on the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let composite = Self.renderComposite(snapshot)
            // Surface the full-color composite the moment it's rasterized, before the dither runs.
            DispatchQueue.main.async { sendCompositeImage = composite }
            guard let result = ImageProcessor.processWithPreview(image: composite, width: w, height: h,
                                                                colorScheme: scheme, dithering: dith,
                                                                useMeasuredPalette: measured, toneCompression: tone) else {
                DispatchQueue.main.async {
                    device.failUpload("Could not render the image for this display's color scheme.")
                }
                return
            }
            DispatchQueue.main.async {
                sendDitheredImage = result.preview
                device.uploadImage(pixelData: result.packed, compressed: true)
            }
        }
    }

    /// All canvas inputs needed to rasterize the composite, captured as value types so the render
    /// can run off the main thread without touching SwiftUI `@State`.
    private struct CompositeSnapshot {
        let width: Int, height: Int
        let canvasSize: CGSize
        let baseImage: UIImage?
        let adjustments: ImageAdjustments
        let scale: CGFloat
        let pan: CGSize
        let strokes: [Stroke]
        let textItems: [TextItem]
        let qrItems: [QRItem]
    }

    private func compositeSnapshot() -> CompositeSnapshot {
        CompositeSnapshot(width: displayWidth, height: displayHeight, canvasSize: canvasSize,
                          baseImage: baseImage, adjustments: adjustments, scale: scale, pan: pan,
                          strokes: strokes, textItems: textItems, qrItems: qrItems)
    }

    /// Render the cropped, adjusted photo plus annotations at the panel's native resolution — the
    /// exact bitmap handed to `ImageProcessor.process` → JS compression → BLE upload. Pure over its
    /// snapshot so it can run off the main thread (see `compositeSnapshot`).
    private static func renderComposite(_ s: CompositeSnapshot) -> UIImage {
        let w = s.width, h = s.height
        let box = s.canvasSize.width > 0 ? s.canvasSize : CGSize(width: w, height: h)
        let k = CGFloat(w) / box.width   // canvas points → panel pixels (aspect matches)

        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { rendererCtx in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))

            // Photo: same aspect-fill + zoom + pan transform used on screen, scaled to pixels.
            if let base = s.baseImage {
                let img = ImageProcessor.adjust(base, adjustments: s.adjustments)
                let imgSize = img.size
                if imgSize.width > 0, imgSize.height > 0 {
                    let s0 = max(box.width / imgSize.width, box.height / imgSize.height)
                    let scl = s0 * s.scale
                    let drawW = imgSize.width * scl
                    let drawH = imgSize.height * scl
                    let x = (box.width - drawW) / 2 + s.pan.width
                    let y = (box.height - drawH) / 2 + s.pan.height
                    img.draw(in: CGRect(x: x * k, y: y * k, width: drawW * k, height: drawH * k))
                }
            }

            let ctx = rendererCtx.cgContext
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for stroke in s.strokes {
                guard stroke.points.count > 1 else { continue }
                UIColor(stroke.color).setStroke()
                ctx.setLineWidth(stroke.lineWidth * k)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: stroke.points[0].x * k, y: stroke.points[0].y * k))
                stroke.points.dropFirst().forEach { ctx.addLine(to: CGPoint(x: $0.x * k, y: $0.y * k)) }
                ctx.strokePath()
            }

            for item in s.textItems {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: item.fontSize * k),
                    .foregroundColor: UIColor(item.color)
                ]
                let str = NSAttributedString(string: item.text, attributes: attrs)
                let sz = str.size()
                str.draw(at: CGPoint(x: item.position.x * k - sz.width / 2,
                                     y: item.position.y * k - sz.height / 2))
            }

            for item in s.qrItems {
                guard let qrImg = odGenerateQR(content: item.content, size: item.size * k, color: item.color) else { continue }
                let side = item.size * k
                qrImg.draw(in: CGRect(x: item.position.x * k - side / 2,
                                      y: item.position.y * k - side / 2,
                                      width: side, height: side))
            }
        }
    }
}

// MARK: - Upload status overlay

/// Bundles the send-status overlay, its transition animation, terminal-state auto-dismiss, and
/// success/error haptics into one modifier — keeping the (already large) Composer `body` modifier
/// chain short enough for the Swift type-checker.
private struct UploadStatusPresenter<Overlay: View>: ViewModifier {
    let phase: ODDevice.UploadPhase?
    let overlay: Overlay
    let onAutoDismiss: () async -> Void

    func body(content: Content) -> some View {
        content
            .overlay { overlay }
            .animation(.easeInOut(duration: 0.25), value: phase)
            .task(id: phase) { await onAutoDismiss() }
            .sensoryFeedback(trigger: phase) { _, newPhase in
                switch newPhase {
                case .succeeded?: return .success
                case .failed?:    return .error
                default:          return nil
                }
            }
    }
}

/// Prominent, full-screen send-status overlay: an in-progress state (device name, big percentage,
/// determinate bar, live status line) plus terminal success/error states that report elapsed time
/// and bytes transferred. Value-typed so it previews without a live `ODDevice`.
struct UploadStatusOverlay: View {
    let phase: ODDevice.UploadPhase
    let progress: Double
    let status: String?
    let deviceName: String
    let elapsed: TimeInterval?
    let byteCount: Int?
    var compositeImage: UIImage? = nil
    var ditheredImage: UIImage? = nil
    var onDismiss: () -> Void
    var onRetry: () -> Void

    /// "2.3s · 45.2 KB" — whichever parts are available.
    private var summary: String {
        var parts: [String] = []
        if let elapsed { parts.append(String(format: "%.1fs", elapsed)) }
        if let byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    /// The image being sent: the full-color composite, with the dithered panel result revealed
    /// left→right in lockstep with `progress`. Shown across every non-idle phase once rendered.
    @ViewBuilder
    private var heroImage: some View {
        if let compositeImage {
            let aspect = compositeImage.size.width / max(compositeImage.size.height, 1)
            ZStack(alignment: .leading) {
                Image(uiImage: compositeImage)
                    .resizable().interpolation(.none)
                if let ditheredImage {
                    Image(uiImage: ditheredImage)
                        .resizable().interpolation(.none)
                        .mask(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle().frame(width: geo.size.width * min(max(progress, 0), 1))
                            }
                        }
                }
            }
            // Fill the available space at the target panel's aspect ratio — largest dimension
            // spans the screen in both portrait and landscape, rather than a fixed thumbnail.
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .animation(.easeInOut(duration: 0.3), value: progress)
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 20) {
                heroImage
                switch phase {
                case .preparing, .sending:
                    Text(deviceName).font(.headline)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    // The image reveal is the progress bar; keep a spinner only until it appears.
                    if compositeImage == nil {
                        ProgressView().progressViewStyle(.circular)
                    }
                    Text(status ?? "Preparing…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                case .succeeded:
                    Label("Sent", systemImage: "checkmark.circle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.green)
                    Text(deviceName).font(.subheadline).foregroundStyle(.secondary)
                    if !summary.isEmpty {
                        Text(summary).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    }

                case .failed(let reason):
                    Label("Send failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.title2.bold())
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if !summary.isEmpty {
                        Text(summary).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("Dismiss") { onDismiss() }
                            .buttonStyle(.bordered)
                        Button("Retry") { onRetry() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)

                case .idle:
                    EmptyView()
                }
            }
            .padding(32)
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }
}

#Preview("Sending") {
    UploadStatusOverlay(phase: .sending, progress: 0.45,
                        status: "Uploading: 45% (123/456 chunks)", deviceName: "Desk EPD",
                        elapsed: nil, byteCount: 46280, onDismiss: {}, onRetry: {})
}

#Preview("Refreshing") {
    UploadStatusOverlay(phase: .sending, progress: 1.0,
                        status: "Upload complete (2.3s), refreshing display…", deviceName: "Desk EPD",
                        elapsed: nil, byteCount: 46280, onDismiss: {}, onRetry: {})
}

#Preview("Sent") {
    UploadStatusOverlay(phase: .succeeded, progress: 1, status: nil, deviceName: "Desk EPD",
                        elapsed: 2.3, byteCount: 46280, onDismiss: {}, onRetry: {})
}

#Preview("Failed") {
    UploadStatusOverlay(phase: .failed("Image upload timed out. The display stopped responding."),
                        progress: 0.62, status: nil, deviceName: "Desk EPD",
                        elapsed: 12.0, byteCount: 46280, onDismiss: {}, onRetry: {})
}
