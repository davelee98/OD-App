import SwiftUI
import PhotosUI
import CoreImage.CIFilterBuiltins

struct DisplayToolView: View {
    @EnvironmentObject private var ble: BLEManager
    @State private var showBLEPicker = false

    // Canvas / drawing
    @State private var drawMode: DrawMode = .draw
    @State private var strokes: [Stroke]  = []
    @State private var currentStroke: Stroke?
    @State private var textItems: [TextItem] = []
    @State private var qrItems:   [QRItem]   = []
    @State private var selectedTextID: UUID?
    @State private var selectedQRID:   UUID?

    // Image
    @State private var photoItem: PhotosPickerItem?
    @State private var baseImage: UIImage?
    @State private var previewImage: UIImage?

    // Upload settings
    @State private var dithering: DitheringMode = .floydSteinberg
    @State private var colorScheme: UInt8 = 0
    @State private var showUploadProgress = false

    // Draw tools
    @State private var drawColorIndex: Int = 0
    @State private var drawLineWidth: CGFloat = 3

    // Text tool
    @State private var pendingText = ""
    @State private var pendingTextSize: CGFloat = 32
    @State private var textColorIndex: Int = 0
    @State private var showTextEntry = false

    // QR tool
    @State private var pendingQRContent = "https://opendisplay.org"
    @State private var pendingQRSize: CGFloat = 120
    @State private var qrColorIndex: Int = 0

    // Palette-derived colors (index into schemePaletteColors)
    private var drawColor: Color { schemePaletteColors[safe: drawColorIndex] ?? .black }
    private var pendingTextColor: Color { schemePaletteColors[safe: textColorIndex] ?? .black }
    private var pendingQRColor: Color { schemePaletteColors[safe: qrColorIndex] ?? .black }

    // Canvas rendering
    @State private var canvasSize: CGSize = .zero

    // Debug
    @State private var debugHex = ""
    @State private var deviceSectionExpanded = false
    @State private var advertisingSectionExpanded = true

    // Partial update demo
    @State private var partialDemoMode: PartialDemoMode = .clock
    @State private var partialDemoRunning = false

    // Display dimensions from config
    private var device: ODDevice? { ble.connectedDevice }
    private var displayWidth:  Int { device?.config?.displayWidth  ?? 800 }
    private var displayHeight: Int { device?.config?.displayHeight ?? 480 }
    private var aspectRatio:   Double { Double(displayWidth) / Double(displayHeight) }

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            canvasArea
            modeBar
            drawModeControls()
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    imageSection
                    if device != nil {
                        Divider()
                        deviceSection
                        Divider()
                        advertisingSection
                    }
                }
            }
            if device != nil {
                Divider()
                bleLogPanel
            }
        }
        .navigationTitle("BLE Tester")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { uploadToolbarButton }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .onChange(of: dithering)    { _, _ in updatePreview() }
        .onChange(of: colorScheme) { _, _ in updatePreview() }
        .onChange(of: device?.config?.colorScheme) { _, newScheme in
            guard let newScheme else { return }
            colorScheme = newScheme
            drawColorIndex = 0; textColorIndex = 0; qrColorIndex = 0
        }
        .onChange(of: ble.connectedDevice) { _, connectedDevice in
            if let connectedDevice {
                colorScheme = connectedDevice.config?.colorScheme ?? colorScheme
                showBLEPicker = false
                if connectedDevice.config == nil { connectedDevice.readConfig() }
                if !connectedDevice.isReadingAdvertisement { connectedDevice.readMSD() }
            }
        }
        .onAppear {
            guard let device else { return }
            if device.config == nil { device.readConfig() }
            if !device.isReadingAdvertisement { device.readMSD() }
        }
        .sheet(isPresented: $showTextEntry) { textEntrySheet }
        .sheet(isPresented: $showBLEPicker, onDismiss: {
            if ble.connectedDevice == nil { ble.deactivate() }
        }) {
            BLEPickerView()
                .environmentObject(ble)
        }
    }

    // MARK: - Connection

    private var connectionBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: device == nil
                      ? "antenna.radiowaves.left.and.right.slash"
                      : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(device == nil ? Color.secondary : Color.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device?.name ?? "Not Connected")
                        .font(.subheadline.weight(.semibold))
                    Text(device == nil ? "Bluetooth is off" : "Bluetooth LE connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(device == nil ? "Connect" : "Disconnect") {
                    if device == nil {
                        ble.activate()
                        showBLEPicker = true
                    } else {
                        ble.deactivate()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(device == nil ? Color.accentColor : Color.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            if device != nil {
                Divider()
                deviceStatusRow
            }
        }
    }

    private var deviceStatusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                // Battery
                if let pct = device?.batteryPercent {
                    statusItem(
                        icon: (device?.isCharging ?? false) ? "battery.100.bolt" : batteryIcon(for: pct),
                        label: "\(pct)%",
                        color: (device?.isCharging ?? false) ? Color.green : batteryColor(for: pct)
                    )
                } else {
                    statusItem(icon: "battery.0", label: "—")
                }

                if let config = device?.config {
                    // Resolution
                    statusItem(icon: "squareshape.split.2x2",
                               label: "\(config.displayWidth)×\(config.displayHeight)")

                    // Display size
                    if let diag = config.displayDiagonalInches {
                        statusItem(icon: "ruler",
                                   label: String(format: "%.1f\"", diag))
                    }

                    // Color type
                    statusItem(icon: "paintpalette", label: config.colorSchemeName)
                }

                // Firmware version
                if let fw = device?.firmwareVersion {
                    statusItem(icon: "tag", label: fw)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func statusItem(icon: String, label: String, color: Color = .secondary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(color)
    }

    private func batteryIcon(for percent: Int) -> String {
        switch percent {
        case 76...: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        case 11...25: return "battery.25"
        default: return "battery.0"
        }
    }

    private func batteryColor(for percent: Int) -> Color {
        switch percent {
        case 21...: return .secondary
        case 11...20: return .orange
        default: return .red
        }
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let canvasW = geo.size.width
            let canvasH = canvasW / aspectRatio

            ZStack(alignment: .topLeading) {
                // Background
                Color.white

                // Base image or preview
                if let img = previewImage ?? baseImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: canvasW, height: canvasH)
                        .clipped()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 36))
                            .foregroundStyle(Color(.systemGray3))
                        Text("Pick an image or draw")
                            .font(.caption)
                            .foregroundStyle(Color(.systemGray2))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Stroke canvas (draw mode)
                Canvas { ctx, size in
                    for stroke in strokes {
                        guard stroke.points.count > 1 else { continue }
                        var path = Path()
                        path.move(to: stroke.points[0])
                        stroke.points.dropFirst().forEach { path.addLine(to: $0) }
                        ctx.stroke(path, with: .color(stroke.color), lineWidth: stroke.lineWidth)
                    }
                    if let s = currentStroke, s.points.count > 1 {
                        var path = Path()
                        path.move(to: s.points[0])
                        s.points.dropFirst().forEach { path.addLine(to: $0) }
                        ctx.stroke(path, with: .color(s.color), lineWidth: s.lineWidth)
                    }
                }
                .gesture(drawMode == .draw ? drawGesture(canvasW: canvasW, canvasH: canvasH) : nil)

                // Text overlays
                ForEach($textItems) { $item in
                    Text(item.text)
                        .font(.system(size: item.fontSize))
                        .foregroundColor(item.color)
                        .position(item.position)
                        .onTapGesture { selectedTextID = item.id }
                        .gesture(dragGesture(for: $item.position))
                        .overlay(
                            selectedTextID == item.id ?
                            RoundedRectangle(cornerRadius: 2).stroke(Color.blue, lineWidth: 1) : nil
                        )
                }

                // QR overlays
                ForEach($qrItems) { $item in
                    if let qrImg = generateQR(content: item.content, size: item.size, color: item.color) {
                        Image(uiImage: qrImg)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: item.size, height: item.size)
                            .position(item.position)
                            .gesture(dragGesture(for: $item.position))
                    }
                }

                // QR placement tap (QR mode)
                if drawMode == .qr {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { loc in
                            qrItems.append(QRItem(content: pendingQRContent,
                                                   size: pendingQRSize,
                                                   color: pendingQRColor,
                                                   position: loc))
                        }
                }

                // Text placement tap (Text mode)
                if drawMode == .text {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { loc in
                            if !pendingText.isEmpty {
                                textItems.append(TextItem(text: pendingText,
                                                           fontSize: pendingTextSize,
                                                           color: pendingTextColor,
                                                           position: loc))
                            } else {
                                showTextEntry = true
                            }
                        }
                }

                // Upload progress overlay
                if let device, device.isUploading {
                    ZStack {
                        Color.black.opacity(0.5)
                        VStack(spacing: 12) {
                            ProgressView(value: device.uploadProgress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: 200)
                            Text("\(Int(device.uploadProgress * 100))%")
                                .foregroundStyle(.white)
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(width: canvasW, height: canvasH)
            .clipped()
            .onAppear { canvasSize = CGSize(width: canvasW, height: canvasH) }
            .onChange(of: canvasW) { _, w in canvasSize = CGSize(width: w, height: w / aspectRatio) }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .border(Color.gray.opacity(0.4), width: 1)
    }

    private var modeBar: some View {
        Picker("Mode", selection: $drawMode) {
            Label("Draw", systemImage: "pencil.tip").tag(DrawMode.draw)
            Label("Text", systemImage: "textformat").tag(DrawMode.text)
            Label("QR Code", systemImage: "qrcode").tag(DrawMode.qr)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Image Section

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Image", icon: "photo") {}

            VStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(baseImage == nil ? "Choose Image" : "Change Image",
                          systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Picker("Dithering", selection: $dithering) {
                    ForEach(DitheringMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }

                HStack {
                    Button("Undo Last") { undoLast() }
                        .buttonStyle(.bordered)
                        .disabled(strokes.isEmpty && textItems.isEmpty && qrItems.isEmpty)
                    Button("Clear Canvas") {
                        strokes.removeAll(); textItems.removeAll(); qrItems.removeAll()
                        baseImage = nil; previewImage = nil; photoItem = nil
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(strokes.isEmpty && textItems.isEmpty && qrItems.isEmpty && baseImage == nil)
                }

                // Partial demo (B/W only)
                if colorScheme == 0 {
                    Divider()
                    HStack {
                        Text("Partial Demo").font(.subheadline).bold()
                        Spacer()
                        Picker("", selection: $partialDemoMode) {
                            Text("Clock").tag(PartialDemoMode.clock)
                            Text("Counter").tag(PartialDemoMode.counter)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        Button(partialDemoRunning ? "Stop" : "Start") {
                            partialDemoRunning ? stopPartialDemo() : startPartialDemo()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: - Device Section

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Device", icon: "bolt.circle") { deviceSectionExpanded.toggle() }
            if deviceSectionExpanded {
                VStack(spacing: 10) {
                    if let fw = device?.firmwareVersion {
                        LabeledContent("Firmware", value: fw)
                    }
                    Divider()
                    HStack(spacing: 12) {
                        deviceButton("Reboot",    icon: "arrow.clockwise",          tint: .orange) { device?.reboot() }
                        deviceButton("Deep Sleep", icon: "moon.zzz",                 tint: .indigo) { device?.sendDeepSleep() }
                        deviceButton("DFU",        icon: "square.and.arrow.down",    tint: .red)    { device?.enterDFU() }
                    }
                }
                .padding()
            }
        }
    }

    private var advertisingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Advertising Data", icon: "dot.radiowaves.left.and.right") {
                advertisingSectionExpanded.toggle()
            }
            if advertisingSectionExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = device?.advertisementError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let advertisement = device?.advertisement {
                        Text(advertisement.formattedDescription)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        Text(device?.isReadingAdvertisement == true
                             ? "Reading…"
                             : "No advertising data has been read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        device?.readMSD()
                    } label: {
                        HStack {
                            if device?.isReadingAdvertisement == true {
                                ProgressView().controlSize(.small)
                            }
                            Text("Read advertising data")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(device?.isReadingAdvertisement == true)
                }
                .padding()
            }
        }
    }

    // MARK: - BLE Log Panel

    private var bleLogPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("BLE Log", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                TextField("Hex cmd (e.g. 0040)", text: $debugHex)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(maxWidth: 160)

                Button("Send") {
                    guard let data = Data(hexString: debugHex.replacingOccurrences(of: "0x", with: "")) else { return }
                    device?.sendRaw(data, label: "Debug")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(Data(hexString: debugHex.replacingOccurrences(of: "0x", with: "")) == nil)

                Button(role: .destructive) { device?.log.removeAll() } label: {
                    Image(systemName: "trash")
                }
                .font(.caption)
                .disabled(device?.log.isEmpty != false)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array((device?.log ?? []).suffix(50))) { entry in
                            LogEntryRow(entry: entry)
                                .padding(.horizontal, 8)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(height: 180)
                .background(Color(.systemBackground))
                .onChange(of: device?.log.count) { _, _ in
                    if let last = device?.log.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var uploadToolbarButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                uploadImage()
            } label: {
                Label("Upload", systemImage: "arrow.up.to.line")
            }
            .disabled(device == nil || device?.isUploading == true ||
                      (baseImage == nil && strokes.isEmpty && textItems.isEmpty && qrItems.isEmpty))
        }
    }

    // MARK: - Text Entry Sheet

    private var textEntrySheet: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextField("Enter text", text: $pendingText)
                }
                Section("Style") {
                    HStack {
                        Text("Size")
                        Slider(value: $pendingTextSize, in: 8...200, step: 2)
                        Text("\(Int(pendingTextSize))pt").frame(width: 48)
                    }
                }
                Section("Color") {
                    colorSwatchPicker(selection: $textColorIndex)
                        .listRowInsets(EdgeInsets())
                        .padding()
                }
            }
            .navigationTitle("Add Text")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { showTextEntry = false }
                        .disabled(pendingText.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showTextEntry = false }
                }
            }
        }
    }

    // MARK: - Draw Mode Controls (shown in canvas area via mode bar)

    // Draw tool controls float below mode bar when draw mode active
    @ViewBuilder
    private func drawModeControls() -> some View {
        if drawMode == .draw {
            VStack(alignment: .leading, spacing: 8) {
                colorSwatchPicker(selection: $drawColorIndex)
                HStack {
                    Image(systemName: "line.diagonal")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $drawLineWidth, in: 1...20, step: 1)
                    Text("\(Int(drawLineWidth))px")
                        .font(.caption)
                        .frame(width: 40)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        } else if drawMode == .text {
            VStack(alignment: .leading, spacing: 8) {
                colorSwatchPicker(selection: $textColorIndex)
                HStack {
                    Image(systemName: "textformat.size")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Slider(value: $pendingTextSize, in: 8...200, step: 2)
                    Text("\(Int(pendingTextSize))pt")
                        .font(.caption)
                        .frame(width: 40)
                    Button("+") { showTextEntry = true }.buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        } else if drawMode == .qr {
            VStack(alignment: .leading, spacing: 8) {
                colorSwatchPicker(selection: $qrColorIndex)
                TextField("QR content (URL or text)", text: $pendingQRContent)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Gestures

    private func drawGesture(canvasW: CGFloat, canvasH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let pt = value.location
                if currentStroke == nil {
                    currentStroke = Stroke(color: drawColor, lineWidth: drawLineWidth, points: [pt])
                } else {
                    currentStroke?.points.append(pt)
                }
            }
            .onEnded { _ in
                if let s = currentStroke { strokes.append(s) }
                currentStroke = nil
            }
    }

    private func dragGesture(for position: Binding<CGPoint>) -> some Gesture {
        DragGesture().onChanged { v in position.wrappedValue = v.location }
    }

    // MARK: - Actions

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        item.loadTransferable(type: Data.self) { result in
            DispatchQueue.main.async {
                if case .success(let data) = result, let data, let img = UIImage(data: data) {
                    self.baseImage = img.orientationNormalized()
                    self.updatePreview()
                }
            }
        }
    }

    private func updatePreview() {
        guard let img = baseImage else { previewImage = nil; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = ImageProcessor.preview(image: img,
                                                  width: self.displayWidth,
                                                  height: self.displayHeight,
                                                  colorScheme: self.colorScheme,
                                                  dithering: self.dithering)
            DispatchQueue.main.async { self.previewImage = preview }
        }
    }

    private func renderComposite() -> UIImage {
        let w = displayWidth, h = displayHeight
        let cw = canvasSize.width > 0 ? canvasSize.width : CGFloat(w)
        let ch = canvasSize.height > 0 ? canvasSize.height : CGFloat(h)
        let sx = CGFloat(w) / cw, sy = CGFloat(h) / ch

        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            if let img = baseImage {
                img.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            } else {
                UIColor.white.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: w, height: h))
            }

            let ctx = UIGraphicsGetCurrentContext()!
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for stroke in strokes {
                guard stroke.points.count > 1 else { continue }
                UIColor(stroke.color).setStroke()
                ctx.setLineWidth(stroke.lineWidth * sx)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: stroke.points[0].x * sx, y: stroke.points[0].y * sy))
                stroke.points.dropFirst().forEach {
                    ctx.addLine(to: CGPoint(x: $0.x * sx, y: $0.y * sy))
                }
                ctx.strokePath()
            }

            for item in textItems {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: item.fontSize * sx),
                    .foregroundColor: UIColor(item.color)
                ]
                let str = NSAttributedString(string: item.text, attributes: attrs)
                let sz = str.size()
                str.draw(at: CGPoint(x: item.position.x * sx - sz.width / 2,
                                     y: item.position.y * sy - sz.height / 2))
            }

            for item in qrItems {
                guard let qrImg = generateQR(content: item.content,
                                              size: item.size * sx, color: item.color) else { continue }
                let scaledSz = CGSize(width: item.size * sx, height: item.size * sy)
                qrImg.draw(in: CGRect(x: item.position.x * sx - scaledSz.width / 2,
                                       y: item.position.y * sy - scaledSz.height / 2,
                                       width: scaledSz.width, height: scaledSz.height))
            }
        }
    }

    private func uploadImage() {
        guard let device else { return }
        let composite = renderComposite()
        let w = displayWidth, h = displayHeight
        let scheme = colorScheme, dith = dithering
        DispatchQueue.global(qos: .userInitiated).async {
            if let pixels = ImageProcessor.process(image: composite, width: w, height: h,
                                                    colorScheme: scheme, dithering: dith) {
                DispatchQueue.main.async {
                    device.uploadImage(pixelData: pixels, compressed: true)
                }
            }
        }
    }

    private func undoLast() {
        if !strokes.isEmpty { strokes.removeLast() }
        else if !textItems.isEmpty { textItems.removeLast() }
        else if !qrItems.isEmpty { qrItems.removeLast() }
    }

    private func startPartialDemo() {
        partialDemoRunning = true
        // TODO: implement partial update demo loop
    }

    private func stopPartialDemo() {
        partialDemoRunning = false
    }

    // MARK: - Palette & Color Swatches

    private var schemePaletteColors: [Color] {
        let rgb = ImageProcessor.palettes[colorScheme] ?? ImageProcessor.palettes[0]!
        return rgb.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) }
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
                                .stroke(
                                    selection.wrappedValue == i ? Color.accentColor : Color(.systemGray4),
                                    lineWidth: selection.wrappedValue == i ? 3 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - QR Generation

    private func generateQR(content: String, size: CGFloat, color: Color) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = size / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return UIImage(ciImage: scaled)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline).bold()
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))
        }
        .buttonStyle(.plain)
    }

    private func deviceButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }
}

// MARK: - BLE Picker

private struct BLEPickerView: View {
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch ble.bluetoothState {
                case .poweredOn:
                    deviceList
                case .poweredOff:
                    unavailable("Bluetooth Off",
                                message: "Enable Bluetooth in Settings, then try again.")
                case .unauthorized:
                    unavailable("Bluetooth Access Denied",
                                message: "Allow Bluetooth access in Settings to connect an OpenDisplay device.")
                case .unsupported:
                    unavailable("Bluetooth Unavailable",
                                message: "Bluetooth LE requires a physical iPhone or iPad.")
                case .resetting, .unknown:
                    ProgressView("Starting Bluetooth…")
                @unknown default:
                    ProgressView("Starting Bluetooth…")
                }
            }
            .navigationTitle("Choose BLE Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if ble.bluetoothState == .poweredOn {
                        Button(ble.isScanning ? "Stop" : "Scan") {
                            ble.isScanning ? ble.stopScan() : ble.startScan()
                        }
                    }
                }
            }
        }
        .onAppear { startScanningIfReady() }
        .onChange(of: ble.bluetoothState) { _, _ in startScanningIfReady() }
        .onChange(of: ble.connectedDevice) { _, device in
            if device != nil { dismiss() }
        }
        .onDisappear { ble.stopScan() }
    }

    private var deviceList: some View {
        List {
            if ble.discoveredDevices.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if ble.isScanning { ProgressView() }
                        Text(ble.isScanning
                             ? "Scanning for OpenDisplay devices…"
                             : "No devices found")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 32)
                    Spacer()
                }
            } else {
                Section("Discovered Devices") {
                    ForEach(ble.discoveredDevices) { discovered in
                        Button {
                            ble.connect(discovered)
                        } label: {
                            DeviceRowView(device: discovered)
                        }
                        .buttonStyle(.plain)
                        .disabled(discovered.connectionState == .connecting)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func unavailable(_ title: String, message: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "antenna.radiowaves.left.and.right.slash",
            description: Text(message)
        )
    }

    private func startScanningIfReady() {
        if ble.bluetoothState == .poweredOn, !ble.isScanning {
            ble.startScan()
        }
    }
}

// MARK: - Supporting Types

enum DrawMode { case draw, text, qr }
enum PartialDemoMode { case clock, counter }

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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
