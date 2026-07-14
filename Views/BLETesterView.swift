import SwiftUI

struct BLETesterView: View {
    @ObservedObject var device: ODDevice
    @EnvironmentObject private var ble: BLEManager

    @State private var selectedCommand: OD.Cmd = .readFirmware
    @State private var payloadHex = ""
    @State private var usePresetCommand = true
    @State private var customOpcodeHex = ""
    @State private var isSending = false
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            commandPanel
            Divider()
            logPanel
        }
        .navigationTitle("BLE Tester")
        .clearSharedLogConfirmation(isPresented: $showClearConfirm) { ble.clearLog() }
    }

    // MARK: - Command Panel

    private var commandPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Failed sends only set `device.lastError`; without this banner they look like
            // silent no-ops (only BLELogView surfaced the error before).
            if let error = device.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if device.connectionState != .connected {
                Label("Disconnected — sending is disabled", systemImage: "bolt.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $usePresetCommand) {
                Text("Preset Command").tag(true)
                Text("Raw Opcode").tag(false)
            }
            .pickerStyle(.segmented)

            if usePresetCommand {
                Picker("Command", selection: $selectedCommand) {
                    ForEach(OD.allCommands, id: \.self) { cmd in
                        Text(cmd.displayName).tag(cmd)
                    }
                }
                .pickerStyle(.menu)
            } else {
                HStack {
                    Text("Opcode")
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("0x0043", text: $customOpcodeHex)
                        .monospaced()
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }

            HStack {
                Text("Payload")
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)
                TextField("hex bytes (optional)", text: $payloadHex)
                    .monospaced()
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if !isPayloadValid {
                Text("Payload must be hex bytes (e.g. 01 A0 FF).")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(action: sendCommand) {
                    HStack {
                        if isSending {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text("Send")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || !isInputValid || device.connectionState != .connected)

                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding()
        .background(.background)
    }

    // MARK: - Log Panel

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if ble.trimmedCount > 0 {
                        Text("Older entries were trimmed — showing the most recent \(ble.log.count) of \(ble.log.count + ble.trimmedCount).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(ble.log) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            // Observe the last entry's id, not `log.count`: once the 500-entry cap trims on every
            // append the count is pinned and `onChange(of: count)` would never fire again, freezing
            // auto-scroll during exactly the busy sessions the Tester exists for.
            .onChange(of: ble.log.last?.id) { _, _ in
                if let last = ble.log.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Actions

    /// Strips the `0x` prefix, spaces, and surrounding whitespace so pasted values like
    /// "0x0043 " or "01 A0 FF" parse. Shared by the opcode and payload fields.
    private func cleanHex(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// An unparseable payload used to be silently dropped, sending the bare header — the
    /// device got a different packet than the user typed. Empty is fine; malformed is not.
    private var isPayloadValid: Bool {
        let clean = cleanHex(payloadHex)
        return clean.isEmpty || Data(hexString: clean) != nil
    }

    private var isOpcodeValid: Bool {
        let clean = cleanHex(customOpcodeHex)
        return !clean.isEmpty && Data(hexString: clean) != nil
    }

    private var isInputValid: Bool {
        (usePresetCommand || isOpcodeValid) && isPayloadValid
    }

    private func parsedPayload() -> Data? {
        let clean = cleanHex(payloadHex)
        guard !clean.isEmpty else { return nil }
        return Data(hexString: clean)
    }

    private func sendCommand() {
        guard isInputValid else { return }
        let payload = parsedPayload()
        let packet: Data
        if usePresetCommand {
            var data = selectedCommand.header
            if let payload { data.append(payload) }
            packet = data
        } else {
            guard var data = Data(hexString: cleanHex(customOpcodeHex)) else { return }
            if let payload { data.append(payload) }
            packet = data
        }

        isSending = true
        // Track the real send outcome (the JS runtime completes on the main thread) instead of a
        // fixed 0.3s timer, so the spinner clears on the actual ACK — and on failure too.
        device.sendRaw(packet, label: usePresetCommand ? selectedCommand.displayName : "Raw") { _ in
            isSending = false
        }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

    /// Hoisted so a fresh `DateFormatter` isn't allocated per row on every render.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            directionIndicator
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if let label = entry.label ?? entry.commandName {
                        Text(label)
                            .font(.caption)
                            .bold()
                            .foregroundStyle(directionColor)
                    }
                    Spacer()
                    // Seconds + milliseconds, matching the export — for BLE debugging (ACK latency,
                    // watchdog windows, retry gaps) minute precision loses the entire signal.
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !entry.data.isEmpty {
                    Text(entry.hexString)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var directionIndicator: some View {
        Rectangle()
            .fill(directionColor)
            .frame(width: 3)
            .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private var directionColor: Color {
        switch entry.direction {
        case .sent: .blue
        case .received: .green
        case .system: .orange
        }
    }

    private var backgroundColor: Color {
        switch entry.direction {
        case .sent: Color.blue.opacity(0.05)
        case .received: Color.green.opacity(0.05)
        case .system: Color.orange.opacity(0.07)
        }
    }
}

// MARK: - Shared Clear Confirmation

extension View {
    /// Confirm-before-clear for the app-wide BLE log, shared by the BLE Tester and the BLE Log
    /// screen so the two can't drift on whether clearing this shared resource warns first.
    func clearSharedLogConfirmation(isPresented: Binding<Bool>, clear: @escaping () -> Void) -> some View {
        confirmationDialog("Clear the shared BLE log?", isPresented: isPresented) {
            Button("Clear Log", role: .destructive, action: clear)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears the app-wide log shown here and on the BLE Log screen.")
        }
    }
}
