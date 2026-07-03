import SwiftUI

/// Hidden "Advanced" area reached from the home gear. Keeps the low-level engineering tools
/// (hardware Toolbox + raw BLE Tester) out of the main consumer flow but still available.
struct AdvancedView: View {
    @EnvironmentObject private var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    private var device: ODDevice? { ble.connectedDevice }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ToolboxView().environmentObject(ble)
                    } label: {
                        Label("Device Configuration", systemImage: "wrench.and.screwdriver")
                    }

                    if let device {
                        NavigationLink {
                            BLETesterView(device: device)
                                .navigationTitle("BLE Tester")
                                .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            Label("BLE Tester", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    } else {
                        Label("BLE Tester", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        BLELogView()
                    } label: {
                        Label("BLE Log", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Engineering Tools")
                } footer: {
                    Text(device == nil
                         ? "Connect a display (via the Toolbox or a saved display) to use the BLE Tester."
                         : "Low-level tools for configuring and debugging OpenDisplay hardware.")
                }

                Section("Connection") {
                    if let device {
                        LabeledContent("Connected", value: device.name)
                        Button(role: .destructive) {
                            ble.disconnect()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    } else {
                        Text("No device connected.").foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Open Display Utility")
                        Text("Version \(AppInfo.version)")
                        Link("https://www.opendisplay.org", destination: URL(string: "https://www.opendisplay.org")!)
                        Link("Legal Notice", destination: URL(string: "https://www.opendisplay.org/impressum.html")!)
                        Link("Privacy Policy", destination: URL(string: "https://www.opendisplay.org/datenschutz.html")!)
                        Text("Copyright (c) 2026 by OpenDisplay.org")
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Shared session log for diagnosing BLE activity across the app.
struct BLELogView: View {
    @EnvironmentObject private var ble: BLEManager

    private var device: ODDevice? { ble.connectedDevice }

    var body: some View {
        List {
            Section("BLE Log") {
                if let error = device?.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                let entries = ble.log.suffix(50)
                if entries.isEmpty {
                    Text("No activity yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(entries)) { entry in
                        LogEntryRow(entry: entry)
                    }
                }

                if !ble.log.isEmpty {
                    Button(role: .destructive) {
                        ble.clearLog()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("BLE Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
