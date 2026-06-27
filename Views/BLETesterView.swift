import SwiftUI

struct BLETesterView: View {
    @ObservedObject var device: ODDevice

    @State private var selectedCommand: OD.Cmd = .readFirmware
    @State private var payloadHex = ""
    @State private var usePresetCommand = true
    @State private var customOpcodeHex = ""
    @State private var isSending = false
    @State private var scrollToBottom = false

    var body: some View {
        VStack(spacing: 0) {
            commandPanel
            Divider()
            logPanel
        }
        .navigationTitle("BLE Tester")
    }

    // MARK: - Command Panel

    private var commandPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .disabled(isSending || !isInputValid)

                Button {
                    device.log.removeAll()
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
                    ForEach(device.log) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: device.log.count) { _, _ in
                if let last = device.log.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Actions

    private var isInputValid: Bool {
        if usePresetCommand { return true }
        guard !customOpcodeHex.isEmpty else { return false }
        let clean = customOpcodeHex.replacingOccurrences(of: "0x", with: "")
        return Data(hexString: clean) != nil
    }

    private func sendCommand() {
        let packet: Data
        if usePresetCommand {
            var data = selectedCommand.header
            if let payload = Data(hexString: payloadHex) { data.append(payload) }
            packet = data
        } else {
            let clean = customOpcodeHex.replacingOccurrences(of: "0x", with: "")
            guard var data = Data(hexString: clean) else { return }
            if let payload = Data(hexString: payloadHex) { data.append(payload) }
            packet = data
        }

        isSending = true
        device.sendRaw(packet, label: usePresetCommand ? selectedCommand.displayName : "Raw")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isSending = false }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry

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
                    Text(entry.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.hexString)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
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
        entry.direction == .sent ? .blue : .green
    }

    private var backgroundColor: Color {
        entry.direction == .sent
            ? Color.blue.opacity(0.05)
            : Color.green.opacity(0.05)
    }
}
