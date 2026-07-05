import SwiftUI
import UniformTypeIdentifiers
import CoreBluetooth
import os

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

    @State private var packetEditorTarget: PacketEditorTarget?
    @State private var showSchemaEditor = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument = ToolboxJSONDocument()
    @State private var exportFilename = "oep_config.json"
    @State private var exportContentType: UTType = .json
    @State private var showRebootConfirm = false
    @State private var showConnectionSheet = false
    @State private var writeAfterConnecting = false
    @State private var rebootAfterWrite = false
    @State private var isConfiguring = false
    @State private var configureProgress = 0.0
    @State private var statusLog: [StatusEntry] = []
    @State private var suppressAdvancedModeOnConfigChange = false

    // Cached JavaScriptCore-derived outputs. Recomputed only when `configuration` or the active
    // schema changes (see `recomputeDerivedConfiguration`), rather than on every body evaluation —
    // ToolboxView re-renders on every BLE notification, and each encode/validate is a synchronous
    // main-thread JS round-trip.
    @State private var encodedConfiguration: Data?
    @State private var configurationValidation: ToolboxValidation?

    enum Mode: String, CaseIterable, Identifiable {
        case simple = "Simple Setup"
        case advanced = "Advanced Mode"
        var id: String { rawValue }
    }

    struct PacketEditorTarget: Identifiable {
        let id: UUID
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
            } else {
                packetEditorSection
                packageBytesSection
                importExportSection
                schemaSection
            }

            deviceActionsSection
            if !statusLog.isEmpty { logSection }
        }
        .navigationTitle("OpenDisplay Device Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadDeviceConfiguration()
            recomputeDerivedConfiguration()
        }
        .onChange(of: configuration) { _, _ in recomputeDerivedConfiguration() }
        .onChange(of: schemaText) { _, _ in recomputeDerivedConfiguration() }
        // `.onReceive` with a publisher built fresh on every `body` evaluation (the old
        // `deviceConfigPublisher`/`deviceErrorPublisher` computed properties) resubscribes each
        // render, and `@Published` always replays its *current* value to a new subscriber. That
        // made this closure fire → mutate state → trigger another `body` evaluation → resubscribe
        // → replay → fire again, forever, pegging the main thread. `.onChange(of:)` diffs the
        // actual value instead of resubscribing, so it only fires on a real change.
        //
        // Status logging for a read triggered *from this view* (Read Toolbox button, initial
        // auto-read) is reported directly from `readConfig`'s completion, not from here — an
        // `@Published` value diff can't tell two consecutive identical failures apart, so relying
        // on it alone silently drops the second "still failing" message. This handler only keeps
        // the picker/packet state in sync if the config changes for some other reason (e.g. a
        // read kicked off from another screen while reconnecting).
        .onChange(of: device?.config) { _, config in
            guard let config else { return }
            configuration = config.toolbox
            syncSimpleSelections()
            // A write (e.g. "Configure over Bluetooth") also updates `device.config` on success,
            // but that shouldn't yank the user into Advanced mode — only an actual config *read*
            // should.
            if suppressAdvancedModeOnConfigChange {
                suppressAdvancedModeOnConfigChange = false
            } else {
                mode = .advanced
            }
        }
        // Catch-all for error sources that don't have their own completion-based status
        // reporting (authentication, MSD reads, misc `ble-common.js` runtime errors). Read/Write
        // Toolbox report their own status directly (see above and `writeConfiguration`) so a
        // repeat of the identical error isn't silently dropped by this value diff.
        .onChange(of: device?.lastError) { _, error in
            if let error { addLog(error, type: .error) }
        }
        .onChange(of: ble.connectedDevice) { _, connected in
            guard connected != nil else { return }
            showConnectionSheet = false
        }
        // `ble.connectedDevice` is set as soon as CoreBluetooth's `didConnect` fires, well before
        // GATT service/characteristic discovery and notifications are set up — writing that early
        // hit the characteristic before it existed and just timed out. `connectionState` only
        // reaches `.connected` once `CoreBluetoothTransport.onReady` fires, so wait for that instead.
        .onChange(of: device?.connectionState) { _, state in
            ODLog.toolbox.debug("device.connectionState changed to \(String(describing: state), privacy: .public); writeAfterConnecting=\(writeAfterConnecting)")
            guard state == .connected, writeAfterConnecting else { return }
            configureProgress = 0.3
            writeAfterConnecting = false
            let shouldReboot = rebootAfterWrite
            rebootAfterWrite = false
            ODLog.toolbox.info("deferred write firing now (rebootWhenDone=\(shouldReboot))")
            writeConfiguration(rebootWhenDone: shouldReboot)
        }
        .onChange(of: boardID) { _, _ in applyBoardDefaults() }
        .onChange(of: mode) { _, newMode in
            if newMode == .advanced && configuration.packets.isEmpty { resetConfiguration() }
        }
        .onChange(of: isLocked) { _, locked in
            if locked && encryptionKey.count != 32 { encryptionKey = randomKey() }
            if !locked { encryptionKey = "" }
        }
        // `.sheet(item:)` instead of `.sheet(isPresented:)` + a separately-set selection ID: the
        // latter isn't atomic on first presentation (the sheet controller doesn't exist yet, so
        // SwiftUI can build its content from a stale snapshot before the ID state propagates),
        // which showed "Packet unavailable" on the very first tap and only worked afterward.
        // Binding the sheet directly to the item that drives it removes that race entirely.
        .sheet(item: $packetEditorTarget) { target in packetEditorSheet(for: target.id) }
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
                      contentType: exportContentType, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { addLog(error.localizedDescription, type: .error) }
        }
        .alert("Reboot device?", isPresented: $showRebootConfirm) {
            Button("Reboot", role: .destructive) { device?.reboot() }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            if let device {
                ToolboxConnectionStatus(device: device)
                // A single `if let` over one precomputed value instead of an `if / else if` chain —
                // List/Form rows built from a chained conditional can leave a blank row (with its
                // own separator line) when neither branch applies, which showed up as extra
                // vertical space and a stray divider under the connection status row above.
                if let authRow = authenticationRowState(for: device) {
                    switch authRow {
                    case .authenticated:
                        Label("Authenticated", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                    case .canAuthenticate(let key):
                        Button("Authenticate") { device.authenticate(psk: key) }
                    }
                }
                Button(role: .destructive) { ble.disconnect() } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
            } else {
                Button { showConnectionSheet = true } label: {
                    Label("Connect to OpenDisplay", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
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

    @ViewBuilder
    private var hardwareSection: some View {
        Text("1. Choose Hardware")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        HardwareSectionView(catalog: catalog, boardID: $boardID, displayID: $displayID, powerID: $powerID)
            .equatable()
    }


    // MARK: - Advanced mode

    private var packetEditorSection: some View {
        Section {
            ForEach(configuration.packets) { packet in
                Button {
                    packetEditorTarget = PacketEditorTarget(id: packet.uuid)
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
                .deleteDisabled(schema.packetTypes[String(packet.packetType)]?.required == true || !configuration.unknownPacketTail.isEmpty)
            }
            .onDelete { offsets in
                guard configuration.unknownPacketTail.isEmpty else { return }
                let removable = offsets.filter {
                    schema.packetTypes[String(configuration.packets[$0].packetType)]?.required != true
                }
                configuration.packets.remove(atOffsets: IndexSet(removable))
            }
            .onMove {
                guard configuration.unknownPacketTail.isEmpty else { return }
                configuration.packets.move(fromOffsets: $0, toOffset: $1)
            }

            Menu {
                ForEach(sortedPacketTypeIDs, id: \.self) { id in
                    if let definition = schema.packetTypes[id] {
                    Button("\(id) — \(definition.name)") {
                        addPacket(id: id, definition: definition)
                    }
                    .disabled(!canAddPacket(id: id, definition: definition))
                    }
                }
            } label: {
                Label("Add Packet", systemImage: "plus.circle")
            }
        } header: {
            Label("Packet Editor", systemImage: "square.stack.3d.up")
        } footer: {
            if configuration.unknownPacketTail.isEmpty {
                Text("Packets are encoded in this order; sequence numbers are generated automatically.")
            } else {
                Text("An unknown packet tail is being preserved. Structural edits are disabled to keep its sequence numbers intact.")
            }
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
            if let validation = configurationValidation {
                ForEach(validation.issues) { issue in
                    Label(issue.message, systemImage: issue.severity == "error" ? "xmark.octagon" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(issue.severity == "error" ? .red : .orange)
                }
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
            Button("Reset Packet UI", role: .destructive, action: resetConfiguration)
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
                do {
                    schema = try ToolboxResources.resetSchema()
                    schemaText = ToolboxResources.schemaText
                    addLog("Bundled YAML schema reloaded", type: .success)
                } catch { addLog(error.localizedDescription, type: .error) }
            }
            Button("Download YAML") {
                exportDocument = ToolboxJSONDocument(text: schemaText)
                exportFilename = "config.yaml"
                exportContentType = .plainText
                showExporter = true
            }
        } header: {
            Text("Configuration Schema")
        }
    }

    // MARK: - Device and logs

    private var deviceActionsSection: some View {
        Section {
            if mode == .simple {
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

                HStack {
                    Label(isLocked ? "Locked" : "Unlocked", systemImage: isLocked ? "lock.fill" : "lock.open")
                    Spacer()
                    Toggle("Encryption", isOn: $isLocked).labelsHidden()
                }
                if isLocked {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("32-character encryption key", text: $encryptionKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .font(.caption.monospaced())
                            .onChange(of: encryptionKey) { _, newValue in
                                let filtered = String(newValue.lowercased().filter(\.isHexDigit).prefix(32))
                                if filtered != newValue { encryptionKey = filtered }
                            }
                        Text("\(encryptionKey.count)/32")
                            .font(.caption2)
                            .foregroundStyle(encryptionKey.count == 32 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
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
            }

            if mode == .advanced {
                Button {
                    if let device { readConfiguration(from: device) } else { showConnectionSheet = true }
                } label: { Label("Read Toolbox", systemImage: "arrow.down.circle") }

                Button {
                    writeConfiguration()
                } label: {
                    Label("Write Toolbox", systemImage: "arrow.up.circle")
                }
                .disabled(device == nil || configuration.packets.isEmpty || encodedConfiguration == nil)
            }

            Button(role: .destructive) { showRebootConfirm = true } label: {
                Label("Reboot Display", systemImage: "arrow.clockwise")
            }
            .disabled(device == nil)
        } header: {
            Text("Device Actions")
        } footer: {
            if mode == .simple {
                Text(isLocked ? "Save or share the generated key; it is required to reconnect." : "Bluetooth application-layer encryption is disabled.")
            }
        }
    }

    private var logSection: some View {
        Section {
            ForEach(statusLog.suffix(50)) { entry in
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
    private func packetEditorSheet(for packetID: UUID) -> some View {
        if let index = configuration.packets.firstIndex(where: { $0.uuid == packetID }),
           let definition = schema.packetTypes[String(configuration.packets[index].packetType)] {
            ToolboxPacketEditor(packet: $configuration.packets[index], definition: definition,
                                allowsDelete: definition.required != true && configuration.unknownPacketTail.isEmpty) {
                configuration.packets.remove(at: index)
                packetEditorTarget = nil
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
                .navigationTitle("Toolbox YAML")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showSchemaEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            do {
                                schema = try ToolboxResources.decodeSchema(schemaText)
                                // Apply updates the runtime's active schema but not `schemaText`
                                // (it is the input), so re-encode explicitly here.
                                recomputeDerivedConfiguration()
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
            readConfiguration(from: device)
        }
    }

    /// Reports a definitive status line for this specific read — success or failure — every
    /// time, including a repeat of the same error on a retry (see the note on
    /// `.onChange(of: device?.config)` above for why that can't be left to a value diff).
    private func readConfiguration(from device: ODDevice) {
        addLog("Reading configuration…", type: .info)
        device.readConfig { result in
            switch result {
            case .success(let model):
                addLog("Configuration read successfully (\(model.toolbox.packets.count) packets)", type: .success)
            case .failure(let error):
                addLog(error.localizedDescription, type: .error)
            }
        }
    }

    private func buildSimpleConfiguration() {
        guard let board = selectedBoard, let display = selectedDisplay, let power = selectedPower else { return }
        do {
            configuration = try ToolboxConfigRuntime.shared.buildSimple(
                boardID: board.id,
                displayID: display.id,
                powerID: power.id,
                deepSleepSeconds: Int(deepSleepMinutes * 60),
                encryptionKey: isLocked ? encryptionKey : nil,
                base: configuration
            )
            addLog("Built \(configuration.packets.count) Toolbox packets from YAML and presets", type: .success)
        } catch {
            addLog("Configuration build failed: \(error.localizedDescription)", type: .error)
        }
    }

    private func writeConfiguration(rebootWhenDone: Bool = false) {
        guard let device else {
            ODLog.toolbox.warning("writeConfiguration called with no device; deferring")
            writeAfterConnecting = true
            showConnectionSheet = true
            return
        }
        ODLog.toolbox.info("writeConfiguration starting; appState=\(String(describing: device.connectionState), privacy: .public) rebootWhenDone=\(rebootWhenDone)")
        guard encodedConfiguration != nil else {
            isConfiguring = false
            addLog("Configuration cannot be encoded", type: .error); return
        }
        if rebootWhenDone { configureProgress = 0.5 }
        if isLocked, let key = Data(hexString: encryptionKey) { device.psk = key }
        suppressAdvancedModeOnConfigChange = true
        device.writeConfig(ODConfigModel(toolbox: configuration)) { succeeded in
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
            exportContentType = .json
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
        // The Display picker only ever offers `compatibleDisplays` (filtered by the board just
        // selected above), not the full `catalog.displays` list. Assigning a display outside
        // that filtered set — which `idFromIndex` alone can't know about — leaves the Picker's
        // `selection` pointing at a value with no matching `tag`, and relying on the
        // `onChange(of: boardID)` → `applyBoardDefaults()` side effect to clean it up doesn't
        // work when boardID happens to be unchanged from the last read (onChange never fires).
        // Validate directly instead of depending on that side effect.
        let candidateDisplayID = idFromIndex(manufacturer.fields["simple_config_display_index"], values: catalog.displays)
        displayID = compatibleDisplays.first(where: { $0.id == candidateDisplayID })?.id ?? selectedBoard?.defaultDisplay
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
    }

    private func randomKey() -> String {
        guard let psk = ODAuth.randomPSK() else {
            addLog("Could not generate a secure encryption key.", type: .error)
            return ""
        }
        return psk.map { String(format: "%02x", $0) }.joined()
    }

    private func addLog(_ message: String, type: StatusEntry.EntryType) {
        statusLog.append(StatusEntry(message: message, type: type))
        if statusLog.count > 50 { statusLog.removeFirst(statusLog.count - 50) }
    }

    // MARK: - Derived values

    private var device: ODDevice? { ble.connectedDevice }

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

    /// Refreshes the cached `encodedConfiguration`/`configurationValidation` by running the two
    /// JavaScriptCore round-trips once. Called from `.onAppear`, `.onChange(of: configuration)`,
    /// `.onChange(of: schemaText)`, and after a schema Apply — never from `body`.
    private func recomputeDerivedConfiguration() {
        encodedConfiguration = try? ToolboxPacketCodec.encode(configuration, schema: schema)
        let engineValidation = try? ToolboxConfigRuntime.shared.validate(configuration)
        let extra = ToolboxSwiftValidation.issues(for: configuration, schema: schema)
        if extra.isEmpty {
            configurationValidation = engineValidation
        } else {
            configurationValidation = ToolboxValidation(
                issues: (engineValidation?.issues ?? []) + extra,
                encodedLength: engineValidation?.encodedLength ?? encodedConfiguration?.count ?? 0
            )
        }
    }

    private var shareURL: URL? {
        guard let bytes = encodedConfiguration else { return nil }
        return toolboxURL(for: bytes)
    }

    private func toolboxURL(for bytes: Data) -> URL? {
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "https://opendisplay.org/firmware/toolbox/?config=\(encoded)")
    }


    private var sortedPacketTypeIDs: [String] {
        schema.packetTypes.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    private enum AuthenticationRowState {
        case authenticated
        case canAuthenticate(Data)
    }

    private func authenticationRowState(for device: ODDevice) -> AuthenticationRowState? {
        if device.isAuthenticated { return .authenticated }
        if let key = device.psk { return .canAuthenticate(key) }
        return nil
    }

    private func packetName(_ type: Int) -> String {
        schema.packetTypes[String(type)]?.name.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown Packet"
    }

    private func canAddPacket(id: String, definition: ToolboxPacketDefinition) -> Bool {
        guard configuration.unknownPacketTail.isEmpty, configuration.packets.count < 256 else { return false }
        let count = configuration.packets.filter { $0.packetType == Int(id) }.count
        if definition.repeatable != true { return count == 0 }
        return count < instanceCapacity(definition)
    }

    private func addPacket(id: String, definition: ToolboxPacketDefinition) {
        guard canAddPacket(id: id, definition: definition) else { return }
        // Seed by `isTextField`, not `type == "text"` — the engine treats ssid/password as
        // text by name, so seeding them "0x0" wrote those literal characters as the SSID.
        var fields = Dictionary(uniqueKeysWithValues: definition.fields.map {
            ($0.name, $0.isTextField ? "" : "0x0")
        })
        if definition.repeatable == true,
           definition.fields.contains(where: { $0.name == "instance_number" }) {
            let used = Set(configuration.packets
                .filter { $0.packetType == Int(id) }
                .compactMap { parseInteger($0.fields["instance_number"]) })
            if let next = (0..<instanceCapacity(definition)).first(where: { !used.contains($0) }) {
                fields["instance_number"] = "0x\(String(next, radix: 16))"
            }
        }
        configuration.packets.append(ToolboxPacket(packetType: Int(id) ?? 0, fields: fields))
    }

    private func instanceCapacity(_ definition: ToolboxPacketDefinition) -> Int {
        guard let bytes = definition.fields.first(where: { $0.name == "instance_number" })?.size.byteCount else {
            return 256
        }
        return bytes >= 4 ? Int.max : (0..<bytes).reduce(1) { value, _ in value * 256 }
    }

    private func resetConfiguration() {
        guard configuration.unknownPacketTail.isEmpty else { return }
        configuration = ToolboxConfiguration(version: schema.version, minorVersion: schema.minorVersion)
        for id in sortedPacketTypeIDs {
            if let definition = schema.packetTypes[id], definition.required == true {
                addPacket(id: id, definition: definition)
            }
        }
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

/// Split out of `ToolboxView` so these Pickers only re-render when the hardware selection
/// itself actually changes. `ToolboxView` re-evaluates its whole body on every BLE
/// notification during a config read (progress ticks + log appends both propagate through
/// `BLEManager`'s forwarded `objectWillChange`); inlined as a computed property, this section's
/// Pickers were reconstructed — and re-validated their `selection` against `tag` — on every one
/// of those passes. `.equatable()` at the call site lets SwiftUI skip re-invoking `body` unless
/// the selection values it's bound to actually differ, so it renders once against the fully
/// decoded config rather than once per chunk.
private struct HardwareSectionView: View, Equatable {
    let catalog: ToolboxPresetCatalog
    @Binding var boardID: String?
    @Binding var displayID: String?
    @Binding var powerID: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.boardID == rhs.boardID && lhs.displayID == rhs.displayID && lhs.powerID == rhs.powerID
    }

    private var selectedBoard: ToolboxBoard? { catalog.driverBoards.first { $0.id == boardID } }

    /// Must mirror `ToolboxView.compatibleDisplays` exactly — the Display picker's selection is
    /// only ever valid if it was chosen from (or already validated against) this same list.
    private var compatibleDisplays: [ToolboxDisplay] {
        guard let board = selectedBoard else { return catalog.displays }
        return catalog.displays.filter { !Set($0.connectorPins).isDisjoint(with: board.connectorPins) }
    }

    var body: some View {
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
        }
    }
}

private struct ToolboxPacketEditor: View {
    @Binding var packet: ToolboxPacket
    let definition: ToolboxPacketDefinition
    let allowsDelete: Bool
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(definition.fields) { field in
                        if field.name.lowercased().hasPrefix("reserved") {
                            EmptyView()
                        } else if let choices = field.choices, !choices.isEmpty {
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
                        } else if field.isTextField {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(field.name.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.subheadline)
                                TextField("", text: textBinding(field.name))
                                    .font(.body.monospaced())
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .utf8ByteLimit(field.maxTextContentBytes, text: textBinding(field.name))
                                if let limit = field.maxTextContentBytes {
                                    let used = (packet.fields[field.name] ?? "").utf8.count
                                    Text("\(used)/\(limit) bytes")
                                        .font(.caption2)
                                        .foregroundStyle(used >= limit ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
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
                if allowsDelete {
                    Section {
                        Button("Delete Packet", role: .destructive, action: onDelete)
                    }
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

    /// Text fields fall back to an empty string, not "0x0" — a missing string value must not
    /// display (or encode, see `addPacket`) as the literal characters `0x0`.
    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { packet.fields[key] ?? "" }, set: { packet.fields[key] = $0 })
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

/// Mirrors `DeviceRowView`'s layout (name on the left, status on the right) so a connected
/// display looks the same here as it does in the device picker list.
private struct ToolboxConnectionStatus: View {
    @ObservedObject var device: ODDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                if device.firmwareVersion != nil || device.config != nil {
                    HStack(spacing: 4) {
                        if let firmware = device.firmwareVersion {
                            Text("FW v\(firmware)")
                        }
                        if device.firmwareVersion != nil, device.config != nil {
                            Text("•")
                        }
                        if let config = device.config {
                            Text("\(config.displayWidth)×\(config.displayHeight) • \(config.colorSchemeName)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            statusBadge
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        Group {
            switch device.connectionState {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .connecting:
                ProgressView().scaleEffect(0.7)
            case .disconnected:
                Label("Disconnected", systemImage: "circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ToolboxConnectionSheet: View {
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DevicePickerContent()
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if ble.isScanning {
                            ble.stopScan()
                        } else {
                            ble.startScan()
                        }
                    } label: {
                        Label(ble.isScanning ? "Stop" : "Scan",
                              systemImage: ble.isScanning ? "stop.circle" : "arrow.clockwise")
                    }
                    .disabled(ble.bluetoothState != .poweredOn)
                }
            }
            .onAppear {
                ble.activate()
                if ble.bluetoothState == .poweredOn { ble.startScan() }
            }
            .onChange(of: ble.bluetoothState) { _, state in
                if state == .poweredOn, ble.connectedDevice == nil, !ble.isScanning {
                    ble.startScan()
                }
            }
            .onChange(of: ble.connectedDevice) { _, device in if device != nil { dismiss() } }
            .onDisappear { ble.stopScan() }
        }
    }
}
