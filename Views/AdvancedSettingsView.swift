import SwiftUI

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
