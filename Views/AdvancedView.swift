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
    @State private var filter: LogFilter = .all

    private var device: ODDevice? { ble.connectedDevice }

    private enum LogFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case sent = "Sent"
        case received = "Received"
        case system = "System"
        var id: String { rawValue }

        var direction: LogEntry.Direction? {
            switch self {
            case .all: nil
            case .sent: .sent
            case .received: .received
            case .system: .system
            }
        }
    }

    private var filteredEntries: [LogEntry] {
        guard let direction = filter.direction else { return ble.log }
        return ble.log.filter { $0.direction == direction }
    }

    var body: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("BLE Log") {
                if let error = device?.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // The full retained log (BLEManager caps it at 500), not a `.suffix(50)` —
                // the Tester already showed everything, and hiding 450 entries here made the
                // two surfaces disagree.
                if filteredEntries.isEmpty {
                    Text(ble.log.isEmpty ? "No activity yet." : "No entries match this filter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredEntries) { entry in
                        LogEntryRow(entry: entry)
                    }
                }

                if !ble.log.isEmpty {
                    ShareLink(item: formattedLog, preview: SharePreview("BLE Log")) {
                        Label("Share Log", systemImage: "square.and.arrow.up")
                    }
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

    /// Plain-text export of the whole retained session log (unfiltered).
    private var formattedLog: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return ble.log.map { entry in
            let direction = switch entry.direction {
            case .sent: "→"
            case .received: "←"
            case .system: "•"
            }
            let label = entry.label ?? entry.commandName ?? ""
            return [formatter.string(from: entry.timestamp), direction, label, entry.hexString]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }
}
