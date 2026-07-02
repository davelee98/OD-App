import SwiftUI
import UniformTypeIdentifiers
import Combine
import CoreBluetooth

struct ToolboxView: View {
    @EnvironmentObject private var ble: BLEManager

    private let catalog = ToolboxResources.catalog
    @State private var schema = ToolboxResources.schema
    @State private var schemaText = ToolboxResources.schemaText
    @State private var configuration = ToolboxConfiguration()
    @State private var mode: Mode = .simple

    @State private var boardID: String?
    @State private var displayID: String?
    @State private var powerID: String?
    @State private var deepSleepMinutes = 0.0
    @State private var isLocked = false
    @State private var encryptionKey = ""
    @State private var firmwareAcknowledged = false
    @State private var deviceConfigured = false

    @State private var selectedPacketID: UUID?
    @State private var showPacketEditor = false
    @State private var showSchemaEditor = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = ToolboxJSONDocument()
    @State private var exportFilename = "oep_config.json"
    @State private var showRebootConfirm = false
    @State private var showDFUConfirm = false
    @State private var showConnectionSheet = false
    @State private var writeAfterConnecting = false
    @State private var rebootAfterWrite = false
    @State private var isConfiguring = false
    @State private var configureProgress = 0.0
    @State private var statusLog: [StatusEntry] = []

    enum Mode: String, CaseIterable, Identifiable {
        case simple = "Setup"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            connectionSection

            Section {
                Picker("Toolbox mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if mode == .simple {
                presetSection
                hardwareSection
                optionsSection
                firmwareSection
                configureSection
            } else {
                packetEditorSection
                packageBytesSection
                importExportSection
                schemaSection
            }

            deviceActionsSection
            if !statusLog.isEmpty { logSection }
        }
        .navigationTitle("Toolbox")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadDeviceConfiguration)
        .onReceive(deviceConfigPublisher) { config in
            guard let config else { return }
            configuration = config.toolbox
            syncSimpleSelections()
            addLog("Configuration read successfully", type: .success)
        }
        .onReceive(deviceErrorPublisher) { error in
            if let error { addLog(error, type: .error) }
        }
        .onChange(of: ble.connectedDevice) { _, connected in
            guard connected != nil else { return }
            showConnectionSheet = false
            if writeAfterConnecting {
                configureProgress = 0.3
                writeAfterConnecting = false
                let shouldReboot = rebootAfterWrite
                rebootAfterWrite = false
                writeConfiguration(rebootWhenDone: shouldReboot)
            }
        }
        .onChange(of: boardID) { _, _ in applyBoardDefaults() }
        .onChange(of: isLocked) { _, locked in
            if locked && encryptionKey.count != 32 { encryptionKey = randomKey() }
            if !locked { encryptionKey = "" }
        }
        .sheet(isPresented: $showPacketEditor) { packetEditorSheet }
        .sheet(isPresented: $showSchemaEditor) { schemaEditorSheet }
        .sheet(isPresented: $showConnectionSheet, onDismiss: {
            if ble.connectedDevice == nil {
                writeAfterConnecting = false
                rebootAfterWrite = false
                isConfiguring = false
                configureProgress = 0
            }
        }) { ToolboxConnectionSheet().environmentObject(ble) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { importResult($0) }
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .json, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { addLog(error.localizedDescription, type: .error) }
        }
        .alert("Reboot device?", isPresented: $showRebootConfirm) {
            Button("Reboot", role: .destructive) { device?.reboot() }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Enter DFU / Bootloader?", isPresented: $showDFUConfirm) {
            Button("Enter DFU", role: .destructive) { device?.enterDFU() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            if let device {
                ToolboxConnectionStatus(device: device)
                if let firmware = device.firmwareVersion { LabeledContent("Firmware", value: firmware) }
                if device.isAuthenticated {
                    Label("Authenticated", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                } else if device.psk != nil {
                    Button("Authenticate") { if let key = device.psk { device.authenticate(psk: key) } }
                }
                Button(role: .destructive) { ble.disconnect() } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
            } else {
                Text("Configure your setup offline, then connect when you are ready to read or write it.")
                    .foregroundStyle(.secondary)
                Button { showConnectionSheet = true } label: {
                    Label("Connect to OpenDisplay", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        } header: {
            Label("Bluetooth Connection", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    // MARK: - Simple mode

    private var presetSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
                ForEach(premadePresets) { preset in
                    Button {
                        boardID = preset.board
                        displayID = preset.display
                        powerID = preset.power
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.title2)
                            Text(preset.name).font(.caption).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("Choose a device")
        } footer: {
            Text("Choose a complete preset, or select the hardware manually below.")
        }
    }

    private var hardwareSection: some View {
        Section {
            Picker("Driver Board", selection: $boardID) {
                Text("Select driver board").tag(String?.none)
                ForEach(catalog.driverBoards) { Text($0.name).tag(Optional($0.id)) }
            }

            Picker("Display", selection: $displayID) {
                Text("Select display").tag(String?.none)
                ForEach(compatibleDisplays) { Text($0.name).tag(Optional($0.id)) }
            }
            .disabled(selectedBoard == nil)

            Picker("Power", selection: $powerID) {
                Text("Select power option").tag(String?.none)
                ForEach(catalog.powerOptions) { Text($0.name).tag(Optional($0.id)) }
            }

            checklistRow("Driver board selected", done: selectedBoard != nil)
            checklistRow("Display selected", done: selectedDisplay != nil)
            checklistRow("Power option selected", done: selectedPower != nil)
            checklistRow("Firmware installed", done: firmwareAcknowledged)
            checklistRow("Device configured", done: deviceConfigured)
        } header: {
            Label("1. Choose Hardware", systemImage: "cpu")
        }
    }

    private var optionsSection: some View {
        Section {
            HStack {
                Label(isLocked ? "Locked" : "Unlocked", systemImage: isLocked ? "lock.fill" : "lock.open")
                Spacer()
                Toggle("Encryption", isOn: $isLocked).labelsHidden()
            }
            if isLocked {
                TextField("32-character encryption key", text: $encryptionKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                Button("Generate Random Key") { encryptionKey = randomKey() }
                if let device, encryptionKey.count == 32, !device.isAuthenticated {
                    Button("Authenticate with This Key") {
                        if let key = Data(hexString: encryptionKey) {
                            device.psk = key
                            device.authenticate(psk: key)
                        }
                    }
                }
            }
            if selectedBoard?.installConfig?.type == "esp32" {
                VStack(alignment: .leading) {
                    Text("Deep sleep between updates: \(Int(deepSleepMinutes)) min")
                    Slider(value: $deepSleepMinutes, in: 0...720, step: 1)
                }
            }
        } header: {
            Text("More Options")
        } footer: {
            Text(isLocked ? "Save or share the generated key; it is required to reconnect." : "Bluetooth application-layer encryption is disabled.")
        }
    }

    @ViewBuilder
    private var firmwareSection: some View {
        Section {
            if let install = selectedBoard?.installConfig {
                if let url = firmwareURL(install) {
                    Link(destination: url) {
                        Label("Open Firmware Package", systemImage: "square.and.arrow.up")
                    }
                }
                if let repo = install.githubRepo, let url = URL(string: repo) {
                    Link(destination: url) { Label("Firmware Repository", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
                Toggle("Firmware installed", isOn: $firmwareAcknowledged)
            } else {
                Text("No automatic firmware package is defined for this board.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label("2. Install Firmware", systemImage: "cable.connector")
        } footer: {
            Text("iPhone does not expose WebUSB/Web Serial. Open or share the package, then flash it from a supported USB host.")
        }
    }

    private var configureSection: some View {
        Section {
            Button {
                isConfiguring = true
                configureProgress = 0.1
                buildSimpleConfiguration()
                rebootAfterWrite = true
                if device == nil {
                    writeAfterConnecting = true
                    showConnectionSheet = true
                } else {
                    rebootAfterWrite = false
                    writeConfiguration(rebootWhenDone: true)
                }
            } label: {
                Label("Configure over Bluetooth", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!simpleSelectionComplete || isConfiguring)

            if isConfiguring {
                ProgressView(value: configureProgress)
                Text(configureProgressText).font(.caption).foregroundStyle(.secondary)
            }

            if let url = simpleShareURL ?? shareURL {
                ShareLink(item: url) { Label("Share Toolbox Setup", systemImage: "square.and.arrow.up") }
            }

            Button("Advanced: Edit Packets") {
                if simpleSelectionComplete { buildSimpleConfiguration() }
                mode = .advanced
            }
        } header: {
            Label("3. Configure", systemImage: "antenna.radiowaves.left.and.right")
        } footer: {
            Text(simpleSelectionComplete ? "Ready to build and write the selected configuration." : "Select a driver board, display, and power option to continue.")
        }
    }

    // MARK: - Advanced mode

    private var packetEditorSection: some View {
        Section {
            ForEach(configuration.packets) { packet in
                Button {
                    selectedPacketID = packet.uuid
                    showPacketEditor = true
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(packetName(packet.packetType)).foregroundStyle(.primary)
                            Text("ID \(packet.packetType) • \(packet.fields.count) fields")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { configuration.packets.remove(atOffsets: $0) }
            .onMove { configuration.packets.move(fromOffsets: $0, toOffset: $1) }

            Menu {
                ForEach(sortedPacketTypeIDs, id: \.self) { id in
                    if let definition = schema.packetTypes[id] {
                    Button("\(id) — \(definition.name)") {
                        let fields = Dictionary(uniqueKeysWithValues: definition.fields.map { ($0.name, "0x0") })
                        configuration.packets.append(ToolboxPacket(packetType: Int(id) ?? 0, fields: fields))
                    }
                    }
                }
            } label: {
                Label("Add Packet", systemImage: "plus.circle")
            }
        } header: {
            Label("Packet Editor", systemImage: "square.stack.3d.up")
        } footer: {
            Text("Packets are encoded in this order; sequence numbers are generated automatically.")
        }
    }

    private var packageBytesSection: some View {
        Section {
            if let bytes = encodedConfiguration {
                LabeledContent("Length", value: "\(bytes.count) bytes")
                LabeledContent("CRC", value: bytes.suffix(2).map { String(format: "%02X", $0) }.joined(separator: " "))
                Text(ToolboxPacketCodec.hex(bytes))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("The current packet set cannot be encoded.").foregroundStyle(.red)
            }
        } header: {
            Text("Finished Package Bytes")
        }
    }

    private var importExportSection: some View {
        Section {
            Button { showImporter = true } label: { Label("Import JSON", systemImage: "square.and.arrow.down") }
            Button(action: exportConfiguration) { Label("Export JSON", systemImage: "square.and.arrow.up") }
            if let url = shareURL {
                ShareLink(item: url) { Label("Share Toolbox URL", systemImage: "link") }
            }
            Button("Reset Packet UI", role: .destructive) { configuration = ToolboxConfiguration() }
        } header: {
            Text("Import, Export & Share")
        }
    }

    private var schemaSection: some View {
        Section {
            LabeledContent("Version", value: "\(schema.version).\(schema.minorVersion)")
            LabeledContent("Packet Types", value: "\(schema.packetTypes.count)")
            Button("Edit Schema") { showSchemaEditor = true }
            Button("Reload Bundled Schema") {
                schema = ToolboxResources.schema
                schemaText = ToolboxResources.schemaText
                addLog("Bundled schema reloaded", type: .success)
            }
            Button("Download Schema JSON") {
                exportDocument = ToolboxJSONDocument(text: schemaText)
                exportFilename = "toolbox-schema.json"
                showExporter = true
            }
        } header: {
            Text("Configuration Schema")
        }
    }

    // MARK: - Device and logs

    private var deviceActionsSection: some View {
        Section {
            Button {
                addLog("Reading configuration…", type: .info)
                if let device { device.readConfig() } else { showConnectionSheet = true }
            } label: { Label("Read Toolbox", systemImage: "arrow.down.circle") }

            Button {
                writeConfiguration()
            } label: {
                Label("Write Toolbox", systemImage: "arrow.up.circle")
            }
            .disabled(device == nil || configuration.packets.isEmpty || encodedConfiguration == nil)

            Button(role: .destructive) { showRebootConfirm = true } label: {
                Label("Reboot", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) { showDFUConfirm = true } label: {
                Label("Enter DFU / Bootloader", systemImage: "square.and.arrow.down")
            }
            .disabled(device == nil)
        } header: {
            Text("Device")
        }
    }

    private var logSection: some View {
        Section {
            ForEach(statusLog.suffix(30)) { entry in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(entry.type.color).frame(width: 7, height: 7).padding(.top, 5)
                    Text(entry.message).font(.caption.monospaced())
                    Spacer()
                    Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Button("Clear Log", role: .destructive) { statusLog.removeAll() }
        } header: {
            Text("Status Log")
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private var packetEditorSheet: some View {
        if let index = selectedPacketIndex,
           let definition = schema.packetTypes[String(configuration.packets[index].packetType)] {
            ToolboxPacketEditor(packet: $configuration.packets[index], definition: definition) {
                configuration.packets.remove(at: index)
                showPacketEditor = false
            }
        } else {
            ContentUnavailableView("Packet unavailable", systemImage: "exclamationmark.triangle")
        }
    }

    private var schemaEditorSheet: some View {
        NavigationStack {
            TextEditor(text: $schemaText)
                .font(.caption.monospaced())
                .padding(8)
                .navigationTitle("Toolbox Schema")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showSchemaEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            do {
                                schema = try ToolboxResources.decodeSchema(schemaText)
                                addLog("Custom schema applied", type: .success)
                                showSchemaEditor = false
                            } catch { addLog(error.localizedDescription, type: .error) }
                        }
                    }
                }
        }
    }

    // MARK: - Data operations

    private func loadDeviceConfiguration() {
        if let config = device?.config {
            configuration = config.toolbox
            syncSimpleSelections()
        } else if let device {
            addLog("Reading configuration…", type: .info)
            device.readConfig()
        }
    }

    private func buildSimpleConfiguration() {
        guard let board = selectedBoard, let display = selectedDisplay, let power = selectedPower else { return }
        let built = ToolboxConfigurationBuilder.build(
            board: board, display: display, power: power,
            deepSleepSeconds: Int(deepSleepMinutes * 60),
            encryptionKey: isLocked ? encryptionKey : nil
        )
        var merged = configuration
        merged.version = built.version
        merged.minorVersion = built.minorVersion
        for packet in built.packets {
            merged.upsert(packet.packetType, fields: packet.fields,
                          instance: packet.fields["instance_number"])
        }
        configuration = merged
        addLog("Built \(configuration.packets.count) Toolbox packets", type: .success)
    }

    private func writeConfiguration(rebootWhenDone: Bool = false) {
        guard let device else {
            writeAfterConnecting = true
            showConnectionSheet = true
            return
        }
        guard encodedConfiguration != nil else {
            isConfiguring = false
            addLog("Configuration cannot be encoded", type: .error); return
        }
        if rebootWhenDone { configureProgress = 0.5 }
        if isLocked, let key = Data(hexString: encryptionKey) { device.psk = key }
        device.writeConfig(ODConfigModel(toolbox: configuration)) { succeeded in
            deviceConfigured = succeeded
            addLog(succeeded ? "Configuration written successfully" : "Configuration write failed",
                   type: succeeded ? .success : .error)
            if succeeded && rebootWhenDone {
                configureProgress = 0.9
                addLog("Rebooting device…", type: .info)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    device.reboot()
                    configureProgress = 1
                    isConfiguring = false
                }
            } else if rebootWhenDone {
                configureProgress = 0
                isConfiguring = false
            }
        }
        addLog("Writing \(configuration.packets.count) packets…", type: .info)
    }

    private func exportConfiguration() {
        do {
            let object: [String: Any] = [
                "version": configuration.version,
                "minor_version": configuration.minorVersion,
                "packets": configuration.packets.map { packet in
                    ["id": String(packet.packetType),
                     "name": schema.packetTypes[String(packet.packetType)]?.name ?? "Unknown",
                     "fields": packet.fields] as [String: Any]
                },
                "exported_at": ISO8601DateFormatter().string(from: Date()),
                "exported_by": "OpenDisplay Toolbox for iOS"
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            exportDocument = ToolboxJSONDocument(text: String(decoding: data, as: UTF8.self))
            exportFilename = "oep_config.json"
            showExporter = true
        } catch { addLog(error.localizedDescription, type: .error) }
    }

    private func importResult(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            configuration = try JSONDecoder.toolbox.decode(ToolboxConfiguration.self, from: data)
            mode = .advanced
            syncSimpleSelections()
            addLog("Imported \(configuration.packets.count) packets", type: .success)
        } catch { addLog("Import failed: \(error.localizedDescription)", type: .error) }
    }

    private func syncSimpleSelections() {
        guard let manufacturer = configuration.packets.first(where: { $0.packetType == 2 }) else { return }
        boardID = idFromIndex(manufacturer.fields["simple_config_driver_index"], values: catalog.driverBoards)
        displayID = idFromIndex(manufacturer.fields["simple_config_display_index"], values: catalog.displays)
        powerID = idFromIndex(manufacturer.fields["simple_config_power_index"], values: catalog.powerOptions)
        if let security = configuration.packets.first(where: { $0.packetType == 39 }),
           parseInteger(security.fields["encryption_enabled"]) != 0 {
            isLocked = true
            encryptionKey = security.fields["encryption_key"] ?? ""
        }
        if let power = configuration.packets.first(where: { $0.packetType == 4 }),
           let seconds = parseInteger(power.fields["deep_sleep_time_seconds"]) {
            deepSleepMinutes = Double(seconds) / 60
        }
    }

    private func idFromIndex<T: Identifiable>(_ raw: String?, values: [T]) -> T.ID? where T.ID == String {
        guard let index = parseInteger(raw), index > 0, index <= values.count else { return nil }
        return values[index - 1].id
    }

    private func applyBoardDefaults() {
        guard let board = selectedBoard else { displayID = nil; return }
        if let selected = selectedDisplay, !compatibleDisplays.contains(where: { $0.id == selected.id }) { displayID = nil }
        if displayID == nil { displayID = board.defaultDisplay }
        if powerID == nil { powerID = board.defaultPower }
        firmwareAcknowledged = false
        deviceConfigured = false
    }

    private func randomKey() -> String {
        ODAuth.randomPSK().map { String(format: "%02x", $0) }.joined()
    }

    private func addLog(_ message: String, type: StatusEntry.EntryType) {
        statusLog.append(StatusEntry(message: message, type: type))
    }

    // MARK: - Derived values

    private var device: ODDevice? { ble.connectedDevice }

    private var deviceConfigPublisher: AnyPublisher<ODConfigModel?, Never> {
        device?.$config.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    private var deviceErrorPublisher: AnyPublisher<String?, Never> {
        device?.$lastError.eraseToAnyPublisher() ?? Just(nil).eraseToAnyPublisher()
    }

    private var selectedBoard: ToolboxBoard? { catalog.driverBoards.first { $0.id == boardID } }
    private var selectedDisplay: ToolboxDisplay? { catalog.displays.first { $0.id == displayID } }
    private var selectedPower: ToolboxPower? { catalog.powerOptions.first { $0.id == powerID } }

    private var compatibleDisplays: [ToolboxDisplay] {
        guard let board = selectedBoard else { return [] }
        return catalog.displays.filter { !Set($0.connectorPins).isDisjoint(with: board.connectorPins) }
    }

    private var simpleSelectionComplete: Bool {
        selectedBoard != nil && selectedDisplay != nil && selectedPower != nil && (!isLocked || encryptionKey.count == 32)
    }

    private var configureProgressText: String {
        switch configureProgress {
        case ..<0.3: "Preparing configuration…"
        case ..<0.5: "Connected; preparing device…"
        case ..<0.9: "Writing configuration…"
        case ..<1: "Rebooting device…"
        default: "Complete"
        }
    }

    private var encodedConfiguration: Data? { try? ToolboxPacketCodec.encode(configuration, schema: schema) }

    private var shareURL: URL? {
        guard let bytes = encodedConfiguration else { return nil }
        return toolboxURL(for: bytes)
    }

    private var simpleShareURL: URL? {
        guard let board = selectedBoard, let display = selectedDisplay, let power = selectedPower else { return nil }
        let config = ToolboxConfigurationBuilder.build(
            board: board, display: display, power: power,
            deepSleepSeconds: Int(deepSleepMinutes * 60),
            encryptionKey: isLocked ? encryptionKey : nil
        )
        guard let bytes = try? ToolboxPacketCodec.encode(config, schema: schema) else { return nil }
        return toolboxURL(for: bytes)
    }

    private func toolboxURL(for bytes: Data) -> URL? {
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "https://opendisplay.org/firmware/toolbox/?config=\(encoded)")
    }

    private var selectedPacketIndex: Int? {
        guard let selectedPacketID else { return nil }
        return configuration.packets.firstIndex { $0.uuid == selectedPacketID }
    }

    private var sortedPacketTypeIDs: [String] {
        schema.packetTypes.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    private func packetName(_ type: Int) -> String {
        schema.packetTypes[String(type)]?.name.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown Packet"
    }

    private func firmwareURL(_ install: ToolboxInstallConfig) -> URL? {
        [install.downloadFile, install.manifest].compactMap { $0 }.compactMap(URL.init(string:)).first
    }

    private func checklistRow(_ label: String, done: Bool) -> some View {
        Label(label, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? .green : .secondary)
    }

    private func parseInteger(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        if raw.lowercased().hasPrefix("0x") { return Int(raw.dropFirst(2), radix: 16) }
        return Int(raw)
    }

    private let premadePresets: [PremadePreset] = [
        .init(id: "reterminal-e1001", name: "reTerminal E1001", board: "reterminal-e1001", display: "ep75-800x480", power: "battery-2000"),
        .init(id: "reterminal-e1002", name: "reTerminal E1002", board: "reterminal-e1002", display: "ep73-spectra-800x480", power: "battery-2000"),
        .init(id: "reterminal-e1003", name: "reTerminal E1003", board: "reterminal-e1003", display: "seeed-ed103-1872x1404", power: "battery-3000"),
        .init(id: "esp32-s3-wspp", name: "Waveshare PhotoPainter", board: "esp32-s3-wspp", display: "ep73-spectra-800x480", power: "battery-2000"),
        .init(id: "xiao-75-c3", name: "Seeed XIAO 7.5\"", board: "xiao-75-c3", display: "ep75-800x480", power: "battery-2000"),
        .init(id: "xiao-75-s3-og", name: "Seeed 7.5\" DIY", board: "ee04", display: "ep75-800x480", power: "battery-2000")
    ]

    private struct PremadePreset: Identifiable {
        let id, name, board, display, power: String
    }

    private struct StatusEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let message: String
        let type: EntryType
        enum EntryType {
            case info, success, error
            var color: Color { switch self { case .info: .blue; case .success: .green; case .error: .red } }
        }
    }
}

private struct ToolboxPacketEditor: View {
    @Binding var packet: ToolboxPacket
    let definition: ToolboxPacketDefinition
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(definition.fields) { field in
                        if let choices = field.choices, !choices.isEmpty {
                            Picker(field.name.replacingOccurrences(of: "_", with: " ").capitalized,
                                   selection: choiceBinding(field.name)) {
                                ForEach(choices.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }), id: \.self) { key in
                                    Text(choices[key]?.name ?? key).tag(key)
                                }
                            }
                        } else if let conditional = field.conditionalChoices,
                                  let choices = conditional.values[decimalKey(packet.fields[conditional.dependsOn])],
                                  !choices.isEmpty {
                            Picker(field.name.replacingOccurrences(of: "_", with: " ").capitalized,
                                   selection: choiceBinding(field.name)) {
                                ForEach(choices.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }), id: \.self) { key in
                                    Text(choices[key]?.name ?? key).tag(key)
                                }
                            }
                        } else if let bits = field.bits, !bits.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(field.name.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.subheadline)
                                ForEach(bits.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }), id: \.self) { key in
                                    if let bit = Int(key) {
                                        Toggle(bits[key]?.name ?? "Bit \(key)", isOn: bitBinding(field.name, bit: bit))
                                    }
                                }
                                if let description = field.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.name.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.subheadline)
                                TextField("0", text: valueBinding(field.name))
                                    .font(.body.monospaced())
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                if let description = field.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Delete Packet", role: .destructive, action: onDelete)
                }
            }
            .navigationTitle(definition.name.replacingOccurrences(of: "_", with: " ").capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func valueBinding(_ key: String) -> Binding<String> {
        Binding(get: { packet.fields[key] ?? "0x0" }, set: { packet.fields[key] = $0 })
    }

    private func bitBinding(_ key: String, bit: Int) -> Binding<Bool> {
        Binding {
            (integer(packet.fields[key]) & (1 << bit)) != 0
        } set: { enabled in
            var value = integer(packet.fields[key])
            if enabled { value |= (1 << bit) } else { value &= ~(1 << bit) }
            packet.fields[key] = String(value)
        }
    }

    private func choiceBinding(_ key: String) -> Binding<String> {
        Binding(get: { decimalKey(packet.fields[key]) }, set: { packet.fields[key] = $0 })
    }

    private func integer(_ raw: String?) -> Int {
        guard let raw else { return 0 }
        if raw.lowercased().hasPrefix("0x") { return Int(raw.dropFirst(2), radix: 16) ?? 0 }
        return Int(raw) ?? 0
    }

    private func decimalKey(_ raw: String?) -> String { String(integer(raw)) }
}

private struct ToolboxConnectionStatus: View {
    @ObservedObject var device: ODDevice

    var body: some View {
        LabeledContent("Device") {
            VStack(alignment: .trailing, spacing: 3) {
                Text(device.name)
                Label(statusText, systemImage: device.connectionState == .connected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(device.connectionState == .connected ? .green : .secondary)
            }
        }
    }

    private var statusText: String {
        switch device.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        case .failed: "Connection failed"
        }
    }
}

private struct ToolboxConnectionSheet: View {
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var namePrefix = "OD"

    var body: some View {
        NavigationStack {
            Group {
                switch ble.bluetoothState {
                case .poweredOn: deviceList
                case .poweredOff:
                    ContentUnavailableView("Bluetooth Off", systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text("Enable Bluetooth in Settings to connect."))
                case .unauthorized:
                    ContentUnavailableView("Bluetooth Access Denied", systemImage: "lock",
                                           description: Text("Allow Bluetooth access in Settings."))
                case .unsupported:
                    ContentUnavailableView("Bluetooth Unavailable", systemImage: "antenna.radiowaves.left.and.right.slash")
                case .resetting, .unknown:
                    ProgressView("Initializing Bluetooth…")
                @unknown default:
                    ProgressView("Initializing Bluetooth…")
                }
            }
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if ble.isScanning {
                            ble.stopScan()
                        } else {
                            ble.namePrefixes = namePrefix.split(separator: ",").map {
                                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            ble.startScan()
                        }
                    } label: {
                        Label(ble.isScanning ? "Stop" : "Scan",
                              systemImage: ble.isScanning ? "stop.circle" : "arrow.clockwise")
                    }
                    .disabled(ble.bluetoothState != .poweredOn)
                }
            }
            .onChange(of: ble.connectedDevice) { _, device in if device != nil { dismiss() } }
            .onDisappear { ble.stopScan() }
        }
    }

    private var deviceList: some View {
        List {
            Section("Device Filter") {
                TextField("OD (comma separated)", text: $namePrefix)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            if ble.discoveredDevices.isEmpty {
                ContentUnavailableView(
                    ble.isScanning ? "Scanning…" : "Ready to Scan",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(ble.isScanning ? "Looking for OpenDisplay devices." : "Tap Scan to look for nearby devices.")
                )
                .listRowBackground(Color.clear)
            } else {
                Section("OpenDisplay Devices") {
                    ForEach(ble.discoveredDevices) { discovered in
                        DeviceRowView(device: discovered)
                            .contentShape(Rectangle())
                            .onTapGesture { ble.connect(discovered) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
