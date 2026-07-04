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

    // Annotations.
    @State private var mode: CanvasMode = .move
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
    @State private var showTextEntry = false
    @State private var pendingQRContent = "https://opendisplay.org"
    @State private var pendingQRSize: CGFloat = 120
    @State private var qrColorIndex = 0

    // Adjustments (neutral defaults = pass-through).
    @State private var adjustments = ImageAdjustments()

    // Dithering (smart default, overridable in Advanced).
    @State private var colorScheme: UInt8 = 0
    @State private var dithering: DitheringMode = .floydSteinberg
    @State private var ditheringOverridden = false
    @State private var showAdvanced = false

    // Preview.
    @State private var previewImage: UIImage?
    @State private var showPreview = false

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
        .onAppear {
            ensureConnection()
        }
        .onDisappear { connectionTimeoutTask?.cancel() }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .onChange(of: adjustments) { _, _ in refreshCanvasImage() }
        .onChange(of: mode) { _, newMode in if newMode == .draw { selection = nil } }
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
        .sheet(isPresented: $showTextEntry) { textEntrySheet }
        .sheet(isPresented: $showPreview) { previewSheet }
        .alert("Unable to Connect", isPresented: connectionAlertIsPresented) {
            Button("OK") { dismiss() }
        } message: {
            Text(connectionAlertMessage ?? "The display could not be reached.")
        }
    }

    // MARK: - Layouts

    /// Portrait (regular height): canvas on top, controls stacked and scrolling below.
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            canvas
            modeBar
            toolControls
            Divider()
            ScrollView { controlPanel }
        }
    }

    /// Landscape (compact height): canvas on the left, a fixed-width scrolling control column right.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            canvas
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    modeBar
                    toolControls
                    controlPanel
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
            pan: $pan, scale: $scale,
            strokes: $strokes, textItems: $textItems, qrItems: $qrItems,
            canvasSize: $canvasSize,
            selection: $selection,
            drawColorIndex: drawColorIndex, drawLineWidth: drawLineWidth,
            pendingText: pendingText, pendingTextSize: pendingTextSize, textColorIndex: textColorIndex,
            pendingQRContent: pendingQRContent, pendingQRSize: pendingQRSize, qrColorIndex: qrColorIndex,
            onRequestTextEntry: { showTextEntry = true }
        )
        .padding(.horizontal)
        .padding(.top, 8)
        .overlay { if let device, device.isUploading { uploadOverlay(device) } }
    }

    private func uploadOverlay(_ device: ODDevice) -> some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 12) {
                ProgressView(value: device.uploadProgress).progressViewStyle(.linear).tint(.white).frame(width: 200)
                Text("Sending… \(Int(device.uploadProgress * 100))%").foregroundStyle(.white).font(.caption)
            }
        }
        .allowsHitTesting(true)
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

    private var modeBar: some View {
        Picker("Mode", selection: $mode) {
            ForEach(CanvasMode.allCases) { m in
                Label(m.title, systemImage: m.systemImage).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Tool controls (per mode)

    @ViewBuilder
    private var toolControls: some View {
        switch mode {
        case .move:
            HStack {
                Label("Pinch to zoom · drag to reposition", systemImage: "hand.draw")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { pan = .zero; scale = 1 }
                    .font(.caption).buttonStyle(.bordered)
                    .disabled(pan == .zero && scale == 1)
            }
            .padding(.horizontal).padding(.bottom, 6)
        case .draw:
            VStack(alignment: .leading, spacing: 8) {
                colorSwatchPicker(selection: $drawColorIndex)
                HStack {
                    Image(systemName: "line.diagonal").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $drawLineWidth, in: 1...20, step: 1)
                    Text("\(Int(drawLineWidth))px").font(.caption).frame(width: 40)
                }
            }
            .padding(.horizontal).padding(.bottom, 6)
        case .text:
            VStack(alignment: .leading, spacing: 8) {
                colorSwatchPicker(selection: $textColorIndex)
                HStack {
                    Image(systemName: "textformat.size").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $pendingTextSize, in: 8...200, step: 2)
                    Text("\(Int(pendingTextSize))pt").font(.caption).frame(width: 44)
                    Button("Edit") { showTextEntry = true }.buttonStyle(.bordered)
                }
            }
            .padding(.horizontal).padding(.bottom, 6)
        case .qr:
            VStack(alignment: .leading, spacing: 8) {
                colorSwatchPicker(selection: $qrColorIndex)
                TextField("QR content (URL or text)", text: $pendingQRContent)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal).padding(.bottom, 6)
        }
    }

    // MARK: - Control panel (photo, adjustments, preview, advanced)

    private var controlPanel: some View {
        VStack(spacing: 16) {
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(baseImage == nil ? "Choose Photo" : "Change Photo", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) { resetPage() } label: {
                    Label("Reset Page", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasContent)
            }

            adjustmentsSection

            HStack {
                Button { generatePreview() } label: {
                    Label("Preview", systemImage: "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!hasContent)

                Button { undoLast() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(strokes.isEmpty && textItems.isEmpty && qrItems.isEmpty)
            }

            advancedSection
        }
        .padding()
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
            Label("Adjustments", systemImage: "slider.horizontal.3").font(.subheadline).bold()
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
            if !adjustments.isNeutral {
                Button("Reset adjustments") { adjustments = .neutral }
                    .font(.caption)
            }
        }
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

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Color mode", selection: $colorScheme) {
                    ForEach(ColorScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme.rawValue)
                    }
                }
                .onChange(of: colorScheme) { _, _ in
                    if !ditheringOverridden { dithering = Self.smartDithering(for: colorScheme) }
                    refreshCanvasImage()
                    resetAnnotationColors()
                }

                Picker("Dithering", selection: $dithering) {
                    ForEach(DitheringMode.allCases) { m in Text(m.displayName).tag(m) }
                }
                .onChange(of: dithering) { _, _ in ditheringOverridden = true }

                Text("Defaults are chosen for this panel's palette. Atkinson suits black-and-white e-ink; Floyd-Steinberg suits multi-color.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .font(.subheadline.weight(.semibold))
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
                                .stroke(selection.wrappedValue == i ? Color.accentColor : Color(.systemGray4),
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
            .disabled(device?.connectionState != .connected || device?.isUploading == true || !hasContent)
        }
    }

    private var textEntrySheet: some View {
        NavigationStack {
            Form {
                Section("Text") { TextField("Enter text", text: $pendingText) }
                Section("Size") {
                    HStack {
                        Slider(value: $pendingTextSize, in: 8...200, step: 2)
                        Text("\(Int(pendingTextSize))pt").frame(width: 48)
                    }
                }
                Section("Color") {
                    colorSwatchPicker(selection: $textColorIndex).listRowInsets(EdgeInsets()).padding()
                }
            }
            .navigationTitle("Add Text")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showTextEntry = false } }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pendingText = ""; showTextEntry = false } }
            }
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
        if let scheme = device?.config?.colorScheme { applyScheme(scheme) }
        else { applyScheme(UInt8(clamping: entity.colorScheme)) }
        if device?.config == nil { device?.readConfig() }
    }

    private func applyScheme(_ scheme: UInt8) {
        colorScheme = scheme
        if !ditheringOverridden { dithering = Self.smartDithering(for: scheme) }
        resetAnnotationColors()
    }

    private func resetAnnotationColors() {
        drawColorIndex = 0; textColorIndex = 0; qrColorIndex = 0
    }

    static func smartDithering(for scheme: UInt8) -> DitheringMode {
        scheme == 0 ? .atkinson : .floydSteinberg
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        item.loadTransferable(type: Data.self) { result in
            // `loadTransferable` already calls back off the main thread — do the heavy
            // orientation-normalize + downscale here so a large photo doesn't block the UI.
            guard case .success(let data?) = result, let img = UIImage(data: data) else { return }
            let normalized = img.orientationNormalized()
            let preview = normalized.downscaled(maxDimension: canvasPreviewMaxDimension)
            DispatchQueue.main.async {
                self.baseImage = normalized
                self.previewBase = preview
                self.pan = .zero; self.scale = 1
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
        composerCanvasQueue.async {
            let adjusted = ImageProcessor.adjust(preview, adjustments: a)
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
        pan = .zero; scale = 1

        // Annotations.
        mode = .move
        strokes.removeAll(); textItems.removeAll(); qrItems.removeAll()
        selection = nil

        // Annotation tool settings.
        drawColorIndex = 0
        drawLineWidth = 3
        pendingText = ""
        pendingTextSize = 32
        textColorIndex = 0
        showTextEntry = false
        pendingQRContent = "https://opendisplay.org"
        pendingQRSize = 120
        qrColorIndex = 0

        // Adjustments.
        adjustments = .neutral

        // Dithering. Re-derive the scheme from the connected panel so Preview and Send agree;
        // clear the override first so applyScheme reapplies the smart dithering default.
        ditheringOverridden = false
        applyScheme(device?.config?.colorScheme ?? UInt8(clamping: entity.colorScheme))
        showAdvanced = false

        // Preview.
        previewImage = nil
        showPreview = false
    }

    private func undoLast() {
        if !strokes.isEmpty { strokes.removeLast() }
        else if !textItems.isEmpty { textItems.removeLast() }
        else if !qrItems.isEmpty { qrItems.removeLast() }
        selection = nil
    }

    private func generatePreview() {
        refreshCanvasImage()
        showPreview = true
        previewImage = nil
        let composite = renderComposite()
        // Read the scheme from the connected device at render time. The config can arrive after this
        // view appears; using the initial @State value would encode a 1bpp frame for a 4-gray panel.
        let w = displayWidth, h = displayHeight
        let scheme = device?.config?.colorScheme ?? colorScheme
        let dith = dithering
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = ImageProcessor.preview(image: composite, width: w, height: h,
                                                 colorScheme: scheme, dithering: dith)
            DispatchQueue.main.async { self.previewImage = preview }
        }
    }

    private func sendPhoto() {
        guard let device else { return }
        guard let deviceConfig = device.config else {
            device.lastError = "Waiting for a valid device configuration before encoding the image"
            device.readConfig()
            return
        }
        let composite = renderComposite()
        let w = displayWidth, h = displayHeight
        let scheme = deviceConfig.colorScheme
        let dith = dithering
        DispatchQueue.global(qos: .userInitiated).async {
            guard let pixels = ImageProcessor.process(image: composite, width: w, height: h,
                                                      colorScheme: scheme, dithering: dith) else {
                DispatchQueue.main.async {
                    device.lastError = "Could not render the image for this display's color scheme."
                }
                return
            }
            DispatchQueue.main.async { device.uploadImage(pixelData: pixels, compressed: true) }
        }
    }

    /// Render the cropped, adjusted photo plus annotations at the panel's native
    /// resolution — the exact bitmap handed to `ImageProcessor.process` → JS compression → BLE upload.
    private func renderComposite() -> UIImage {
        let w = displayWidth, h = displayHeight
        let box = canvasSize.width > 0 ? canvasSize : CGSize(width: w, height: h)
        let k = CGFloat(w) / box.width   // canvas points → panel pixels (aspect matches)

        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { rendererCtx in
            UIColor.white.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))

            // Photo: same aspect-fill + zoom + pan transform used on screen, scaled to pixels.
            if let base = baseImage {
                let img = ImageProcessor.adjust(base, adjustments: adjustments)
                let imgSize = img.size
                if imgSize.width > 0, imgSize.height > 0 {
                    let s0 = max(box.width / imgSize.width, box.height / imgSize.height)
                    let s = s0 * scale
                    let drawW = imgSize.width * s
                    let drawH = imgSize.height * s
                    let x = (box.width - drawW) / 2 + pan.width
                    let y = (box.height - drawH) / 2 + pan.height
                    img.draw(in: CGRect(x: x * k, y: y * k, width: drawW * k, height: drawH * k))
                }
            }

            let ctx = rendererCtx.cgContext
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for stroke in strokes {
                guard stroke.points.count > 1 else { continue }
                UIColor(stroke.color).setStroke()
                ctx.setLineWidth(stroke.lineWidth * k)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: stroke.points[0].x * k, y: stroke.points[0].y * k))
                stroke.points.dropFirst().forEach { ctx.addLine(to: CGPoint(x: $0.x * k, y: $0.y * k)) }
                ctx.strokePath()
            }

            for item in textItems {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: item.fontSize * k),
                    .foregroundColor: UIColor(item.color)
                ]
                let str = NSAttributedString(string: item.text, attributes: attrs)
                let sz = str.size()
                str.draw(at: CGPoint(x: item.position.x * k - sz.width / 2,
                                     y: item.position.y * k - sz.height / 2))
            }

            for item in qrItems {
                guard let qrImg = odGenerateQR(content: item.content, size: item.size * k, color: item.color) else { continue }
                let side = item.size * k
                qrImg.draw(in: CGRect(x: item.position.x * k - side / 2,
                                      y: item.position.y * k - side / 2,
                                      width: side, height: side))
            }
        }
    }
}
