import SwiftUI
import SwiftData

/// Detail screen for one saved e-paper display: shows live connection/power state, keeps the
/// cached config in sync, and launches the Composer via a prominent "Send New Photo" button.
/// Low-level device controls live in a hidden "Advanced Settings" sheet.
struct DisplayDetailView: View {
    @Bindable var entity: SavedDisplayEntity
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showRename = false
    @State private var showAdvancedSettings = false
    @State private var renameName = ""
    @State private var renameLocation = ""

    private var device: ODDevice? {
        ble.connectedDevice?.deviceID == entity.id ? ble.connectedDevice : nil
    }
    private var isConnected: Bool { device?.connectionState == .connected }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusCard

                NavigationLink {
                    ComposerView(entity: entity).environmentObject(ble)
                } label: {
                    Label("Send New Photo", systemImage: "photo.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected)

                if !isConnected { connectRow }
            }
            .padding()
        }
        .navigationTitle(entity.friendlyName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { menu }
        .onAppear { connectIfNeeded() }
        .onChange(of: device?.config) { _, cfg in if let cfg { entity.apply(config: cfg) } }
        .sheet(isPresented: $showRename) { renameSheet }
        .sheet(isPresented: $showAdvancedSettings) {
            AdvancedSettingsView(entity: entity).environmentObject(ble)
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: isConnected ? "dot.radiowaves.left.and.right" : "wifi.slash")
                    .font(.title2)
                    .foregroundStyle(isConnected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionText).font(.headline)
                    if !entity.deviceLocation.isEmpty {
                        Text(entity.deviceLocation).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 20) {
                infoItem(icon: batterySymbol, value: batteryText, tint: batteryTint)
                infoItem(icon: "squareshape.split.2x2", value: "\(entity.width)×\(entity.height)")
                infoItem(icon: "paintpalette", value: colorSchemeName)
                if let fw = device?.firmwareVersion { infoItem(icon: "tag", value: fw) }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoItem(icon: String, value: String, tint: Color = .secondary) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.body).foregroundStyle(tint)
            Text(value).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectRow: some View {
        VStack(spacing: 8) {
            if device?.connectionState == .connecting {
                HStack { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
            } else {
                Button {
                    connectIfNeeded(force: true)
                } label: {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var connectionText: String {
        switch device?.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .failed: return "Connection failed"
        default: return "Not connected"
        }
    }

    private var colorSchemeName: String {
        device?.config?.colorSchemeName ?? (ColorScheme(rawValue: UInt8(clamping: entity.colorScheme))?.displayName ?? "—")
    }

    private var batteryText: String { device?.batteryPercent.map { "\($0)%" } ?? "—" }
    private var batterySymbol: String {
        guard let pct = device?.batteryPercent else { return "battery.0" }
        if device?.isCharging == true { return "battery.100.bolt" }
        switch pct {
        case 76...: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        case 11...25: return "battery.25"
        default: return "battery.0"
        }
    }
    private var batteryTint: Color {
        guard let pct = device?.batteryPercent, device?.isCharging != true else { return .green }
        switch pct { case 21...: return .secondary; case 11...20: return .orange; default: return .red }
    }

    // MARK: - Toolbar menu

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { renameName = entity.friendlyName; renameLocation = entity.deviceLocation; showRename = true } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button { showAdvancedSettings = true } label: {
                    Label("Advanced Settings", systemImage: "wrench.and.screwdriver")
                }
                Divider()
                Button(role: .destructive) { deleteDisplay() } label: {
                    Label("Remove Display", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var renameSheet: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Display name", text: $renameName) }
                Section("Location") { TextField("e.g. Kitchen", text: $renameLocation) }
            }
            .navigationTitle("Rename Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        entity.friendlyName = renameName.isEmpty ? entity.friendlyName : renameName
                        entity.deviceLocation = renameLocation
                        showRename = false
                    }
                    .disabled(renameName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showRename = false } }
            }
        }
    }

    // MARK: - Actions

    private func connectIfNeeded(force: Bool = false) {
        guard force || ble.connectedDevice?.deviceID != entity.id else { return }
        guard let uuid = UUID(uuidString: entity.id) else { return }
        ble.reconnect(to: uuid)
    }

    private func deleteDisplay() {
        if ble.connectedDevice?.deviceID == entity.id { ble.disconnect() }
        ODAuth.deletePSK(forDevice: entity.id)
        modelContext.delete(entity)
        dismiss()
    }
}

// MARK: - Advanced Settings

/// Hidden power-user panel for device-specific controls.
struct AdvancedSettingsView: View {
    let entity: SavedDisplayEntity
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    private var device: ODDevice? {
        ble.connectedDevice?.deviceID == entity.id ? ble.connectedDevice : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    if let fw = device?.firmwareVersion { LabeledContent("Firmware", value: fw) }
                    LabeledContent("Identifier", value: entity.id).font(.caption.monospaced())
                }

                Section("Controls") {
                    Button { device?.reboot() } label: { Label("Reboot", systemImage: "arrow.clockwise") }
                    Button { device?.sendDeepSleep() } label: { Label("Deep Sleep", systemImage: "moon.zzz") }
                    Button(role: .destructive) { device?.enterDFU() } label: { Label("Enter DFU", systemImage: "square.and.arrow.down") }
                }
                .disabled(device?.connectionState != .connected)
            }
            .navigationTitle("Advanced Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
