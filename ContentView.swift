import SwiftUI
import SwiftData
import ODProtocolKit

/// Home screen: the persistent "My Displays" registry that replaces the old live-scanning
/// two-tool launcher. Tapping a display opens its detail/Composer; the gear opens Advanced.
struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedDisplayEntity.dateAdded, order: .forward) private var displays: [SavedDisplayEntity]

    @State private var showAddSheet = false
    @State private var showAdvanced = false
    @State private var displayToEdit: SavedDisplayEntity?
    @State private var displayToDelete: SavedDisplayEntity?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pageHeader
                contentList
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAdvanced = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Advanced")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Display")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) { AddDisplaySheet().environmentObject(ble) }
        .sheet(item: $displayToEdit) { entity in
            AddDisplaySheet(entity: entity).environmentObject(ble)
        }
        .sheet(isPresented: $showAdvanced) { AdvancedView().environmentObject(ble) }
        .alert("Delete Display?", isPresented: $showDeleteConfirmation, presenting: displayToDelete) { entity in
            Button("Delete", role: .destructive) { deleteDisplay(entity) }
            Button("Cancel", role: .cancel) { displayToDelete = nil }
        } message: { entity in
            Text("\(entity.friendlyName) and its saved connection credentials will be removed.")
        }
    }

    private var pageHeader: some View {
        HStack {
            Text("OpenDisplay Utility")
                .font(.title2.weight(.semibold))
            Spacer()
            ODLogoView(height: 80)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var contentList: some View {
        if displays.isEmpty {
            emptyState
        } else {
            List {
                ForEach(displays) { entity in
                    HStack(spacing: 12) {
                        NavigationLink {
                            ComposerView(entity: entity).environmentObject(ble)
                        } label: {
                            DisplayRowLabel(entity: entity)
                        }
                        .buttonStyle(.plain)

                        Button {
                            displayToEdit = entity
                        } label: {
                            Image(systemName: "gearshape")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Modify \(entity.friendlyName)")
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            displayToDelete = entity
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Displays Yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add an OpenDisplay e-paper screen to start sending it photos.")
        } actions: {
            Button("Add Display") { showAddSheet = true }.buttonStyle(.borderedProminent)
        }
    }

    private func deleteDisplay(_ entity: SavedDisplayEntity) {
        if ble.connectedDevice?.deviceID == entity.id { ble.disconnect() }
        ODAuth.deletePSK(forDevice: entity.id)
        modelContext.delete(entity)
        displayToDelete = nil
    }
}

// MARK: - Display Row

private struct DisplayRowLabel: View {
    let entity: SavedDisplayEntity

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entity.friendlyName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(entity.width)×\(entity.height) · \(colorSchemeName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !entity.deviceLocation.isEmpty {
                Text(entity.deviceLocation)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var colorSchemeName: String {
        ODProtocolKit.ColorScheme(rawValue: UInt8(clamping: entity.colorScheme))?.displayName
            ?? "Scheme \(entity.colorScheme)"
    }
}

// MARK: - Add Display

/// Two-step: pick/connect an OD device, then give it a friendly name + location. Names are
/// user-entered — the firmware exposes no name/location field over BLE.
struct AddDisplaySheet: View {
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var friendlyName = ""
    @State private var deviceLocation = ""
    @State private var saved = false

    let entity: SavedDisplayEntity?

    init(entity: SavedDisplayEntity? = nil) {
        self.entity = entity
        _friendlyName = State(initialValue: entity?.friendlyName ?? "")
        _deviceLocation = State(initialValue: entity?.deviceLocation ?? "")
    }

    private var isEditing: Bool { entity != nil }
    private var connectedDevice: ODDevice? {
        guard let entity else { return ble.connectedDevice }
        return ble.connectedDevice?.deviceID == entity.id ? ble.connectedDevice : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    editorForm(for: connectedDevice)
                } else if let device = connectedDevice {
                    editorForm(for: device)
                } else {
                    DevicePickerContent()
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !isEditing, connectedDevice == nil, ble.bluetoothState == .poweredOn {
                    ToolbarItem(placement: .primaryAction) {
                        Button(ble.isScanning ? "Stop" : "Scan") {
                            ble.isScanning ? ble.stopScan() : ble.startScan()
                        }
                    }
                }
            }
        }
        .onAppear {
            if let entity, ble.connectedDevice?.deviceID != entity.id,
               let identifier = UUID(uuidString: entity.id) {
                ble.reconnect(to: identifier)
            } else if !isEditing {
                ble.activate()
                if ble.bluetoothState == .poweredOn { ble.startScan() }
            }
        }
        .onChange(of: ble.bluetoothState) { _, state in
            if state == .poweredOn, connectedDevice == nil, !ble.isScanning { ble.startScan() }
        }
        .onChange(of: connectedDevice) { _, device in
            // The config read is auto-kicked from ODDevice's transport.onReady once GATT is actually
            // usable — triggering it here (the instant didConnect publishes, still `.connecting`)
            // deterministically failed with "Not connected" and never retried.
            if let device = device, friendlyName.isEmpty { friendlyName = device.name }
        }
        .onDisappear {
            ble.stopScan()
            // Cancelled before saving → drop the connection we opened.
            if !isEditing, !saved { ble.deactivate() }
        }
    }

    private var navigationTitle: String {
        if isEditing { return "Display Settings" }
        return connectedDevice == nil ? "Add Display" : "Name Display"
    }

    private func editorForm(for device: ODDevice?) -> some View {
        Form {
            Section {
                HStack {
                    Image(systemName: device == nil ? "wifi.slash" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(device == nil ? Color.secondary : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device?.name ?? entity?.friendlyName ?? "Display")
                            .font(.subheadline.weight(.semibold))
                        configStatus(for: device)
                    }
                }
            }
            Section("Name") { TextField("e.g. Kitchen Display", text: $friendlyName) }
            Section("Location") { TextField("e.g. Kitchen", text: $deviceLocation) }
            if let entity {
                Section {
                    NavigationLink {
                        AdvancedSettingsView(entity: entity).environmentObject(ble)
                    } label: {
                        Label("Advanced Settings", systemImage: "wrench.and.screwdriver")
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(device) }
                    .disabled(saveDisabled(for: device))
            }
        }
    }

    /// A new display can't be saved until its real configuration has been read — persisting the
    /// fallback guess as if confirmed is the bug this flow exists to prevent. Editing an existing
    /// entry only rewrites its name/location, so it never waits on a read.
    private func saveDisabled(for device: ODDevice?) -> Bool {
        if friendlyName.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if !isEditing, device?.config == nil { return true }
        return false
    }

    @ViewBuilder
    private func configStatus(for device: ODDevice?) -> some View {
        let state = device?.configReadState ?? .unread
        if let cfg = device?.config {
            // Confirmed from hardware this session; a trailing spinner means a reconnect is refreshing it.
            HStack(spacing: 6) {
                Text("\(cfg.displayWidth)×\(cfg.displayHeight) · \(cfg.colorSchemeName)")
                    .font(.caption).foregroundStyle(.secondary)
                if state == .reading { ProgressView().controlSize(.mini) }
            }
        } else if case .failed = state {
            VStack(alignment: .leading, spacing: 4) {
                if let entity {
                    Text("\(entity.width)×\(entity.height) · \(cachedColorSchemeName(for: entity))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Couldn't refresh the configuration.")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("Couldn't read the display configuration.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button("Retry") { device?.readConfig() }
                    .font(.caption).buttonStyle(.borderless)
            }
        } else if let entity {
            // Stale cached value shown while a fresh read runs (edit mode).
            HStack(spacing: 6) {
                Text("\(entity.width)×\(entity.height) · \(cachedColorSchemeName(for: entity))")
                    .font(.caption).foregroundStyle(.secondary)
                if state == .reading { ProgressView().controlSize(.mini) }
            }
        } else {
            // New display, no cached value yet: fetching (or about to).
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading configuration…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save(_ device: ODDevice?) {
        let trimmedName = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entity {
            entity.friendlyName = trimmedName
            entity.deviceLocation = deviceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            if let config = device?.config { entity.apply(config: config) }
            saved = true
            dismiss()
            return
        }

        // Save is disabled for a new display until the config is read (see saveDisabled), so this is
        // reached only with a confirmed configuration in hand — never the fabricated 800×480 guess.
        guard let device, let config = device.config else { return }

        // Upsert: update an existing registry entry for this peripheral rather than duplicating.
        let id = device.deviceID
        let descriptor = FetchDescriptor<SavedDisplayEntity>(predicate: #Predicate { $0.id == id })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.friendlyName = trimmedName
            existing.deviceLocation = deviceLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.apply(config: config)   // overwrite dimensions only with the freshly-read config
        } else {
            let entity = SavedDisplayEntity(
                id: id, friendlyName: trimmedName,
                deviceLocation: deviceLocation.trimmingCharacters(in: .whitespacesAndNewlines))
            entity.apply(config: config)
            modelContext.insert(entity)
        }
        saved = true
        dismiss()
    }

    private func cachedColorSchemeName(for entity: SavedDisplayEntity) -> String {
        ODProtocolKit.ColorScheme(rawValue: UInt8(clamping: entity.colorScheme))?.displayName
            ?? "Scheme \(entity.colorScheme)"
    }
}

// MARK: - Device Picker (reusable scan list)

/// Reusable discovered-device list + Bluetooth-state handling, with no NavigationStack of its own
/// so it can be embedded (e.g. in `AddDisplaySheet`). Tapping a device connects it.
struct DevicePickerContent: View {
    @EnvironmentObject private var ble: BLEManager
    /// Persisted: a user whose display advertises a non-OD name needs this on every launch.
    @AppStorage("showAllBLEDevices") private var showAllDevices = false

    /// The manager stores every discovered peripheral; filtering happens here so flipping the
    /// toggle never requires a rescan. With Show All on, likely-OD devices sort first (stable).
    private var visibleDevices: [DiscoveredDevice] {
        showAllDevices
            ? ble.discoveredDevices.sorted { $0.isLikelyOpenDisplay && !$1.isLikelyOpenDisplay }
            : ble.discoveredDevices.filter(\.isLikelyOpenDisplay)
    }

    var body: some View {
        switch ble.bluetoothState {
        case .poweredOn:
            deviceList
        case .poweredOff:
            unavailable("Bluetooth Off", "Enable Bluetooth in Settings, then try again.")
        case .unauthorized:
            unavailable("Bluetooth Access Denied", "Allow Bluetooth access in Settings to connect a display.")
        case .unsupported:
            unavailable("Bluetooth Unavailable", "Bluetooth LE requires a physical iPhone or iPad.")
        default:
            ProgressView("Starting Bluetooth…")
        }
    }

    private var deviceList: some View {
        List {
            if visibleDevices.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if ble.isScanning { ProgressView() }
                        Text(ble.isScanning ? "Scanning for OpenDisplay devices…" : "No devices found")
                            .foregroundStyle(.secondary)
                        if !showAllDevices && !ble.discoveredDevices.isEmpty {
                            Text("\(ble.discoveredDevices.count) other device\(ble.discoveredDevices.count == 1 ? "" : "s") hidden")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 32)
                    Spacer()
                }
            } else {
                Section("Discovered Devices") {
                    ForEach(visibleDevices) { discovered in
                        Button { ble.connect(discovered) } label: { DeviceRowView(device: discovered) }
                            .buttonStyle(.plain)
                            .disabled(discovered.connectionState == .connecting)
                    }
                }
            }

            Section {
                Toggle("Show all devices", isOn: $showAllDevices)
            } footer: {
                Text("Lists every nearby Bluetooth device, not just OpenDisplay displays.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func unavailable(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: "antenna.radiowaves.left.and.right.slash", description: Text(message))
    }
}
