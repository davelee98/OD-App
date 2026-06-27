import SwiftUI

struct ConfigView: View {
    @ObservedObject var device: ODDevice
    @State private var editableConfig: ODConfigModel?
    @State private var selectedPreset: DevicePreset = DevicePreset.custom
    @State private var pskInput = ""
    @State private var showPSKField = false
    @State private var isSaving = false

    var body: some View {
        Form {
            deviceInfoSection
            authSection
            if let config = editableConfig ?? device.config {
                displaySection(config)
                advancedSection(config)
                saveSection
            } else {
                readConfigSection
            }
        }
        .navigationTitle("Configure")
        .onAppear {
            if device.config == nil { device.readConfig() }
            if let loaded = device.config { editableConfig = loaded }
        }
        .onChange(of: device.config) { _, newConfig in
            if let c = newConfig, editableConfig == nil { editableConfig = c }
        }
    }

    // MARK: - Sections

    private var deviceInfoSection: some View {
        Section("Device") {
            LabeledContent("Name", value: device.name)
            if let fw = device.firmwareVersion {
                LabeledContent("Firmware", value: fw)
            } else {
                HStack {
                    Text("Firmware")
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                }
            }
            if let msd = device.msdHex {
                LabeledContent("MSD") {
                    Text(msd)
                        .font(.caption)
                        .monospaced()
                }
            }
        }
    }

    private var authSection: some View {
        Section("Authentication") {
            if device.isAuthenticated {
                Label("Authenticated", systemImage: "lock.open.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    showPSKField.toggle()
                } label: {
                    Label(showPSKField ? "Hide PSK" : "Authenticate with PSK",
                          systemImage: showPSKField ? "eye.slash" : "lock")
                }

                if showPSKField {
                    TextField("PSK (hex, 32 chars)", text: $pskInput)
                        .monospaced()
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Authenticate") {
                        guard let psk = Data(hexString: pskInput), psk.count == 16 else { return }
                        device.authenticate(psk: psk)
                        showPSKField = false
                    }
                    .disabled(pskInput.replacingOccurrences(of: " ", with: "").count != 32)
                }
            }
        }
    }

    private func displaySection(_ config: ODConfigModel) -> some View {
        Section {
            Picker("Hardware Preset", selection: $selectedPreset) {
                ForEach(DevicePreset.all) { preset in
                    Text(preset.name).tag(preset)
                }
            }
            .onChange(of: selectedPreset) { _, preset in
                if preset.id != "custom" {
                    editableConfig?.displayWidth = preset.width
                    editableConfig?.displayHeight = preset.height
                }
            }

            HStack {
                Text("Width")
                Spacer()
                TextField("px", value: Binding(
                    get: { editableConfig?.displayWidth ?? config.displayWidth },
                    set: { editableConfig?.displayWidth = $0 }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            }

            HStack {
                Text("Height")
                Spacer()
                TextField("px", value: Binding(
                    get: { editableConfig?.displayHeight ?? config.displayHeight },
                    set: { editableConfig?.displayHeight = $0 }
                ), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            }

            Picker("Color Mode", selection: Binding(
                get: { editableConfig?.colorScheme ?? config.colorScheme },
                set: { editableConfig?.colorScheme = $0 }
            )) {
                Text("Black & White").tag(UInt8(0))
                Text("B/W/Red").tag(UInt8(1))
                Text("Spectra 6").tag(UInt8(2))
                Text("4-Gray").tag(UInt8(3))
            }

            Picker("Refresh Mode", selection: Binding(
                get: { editableConfig?.refreshMode ?? config.refreshMode },
                set: { editableConfig?.refreshMode = $0 }
            )) {
                Text("Full refresh").tag(UInt8(0))
                Text("Partial").tag(UInt8(1))
                Text("Fast").tag(UInt8(2))
            }
        } header: {
            Text("Display")
        }
    }

    private func advancedSection(_ config: ODConfigModel) -> some View {
        Section("Advanced") {
            Toggle("Deep Sleep", isOn: Binding(
                get: { editableConfig?.deepSleepEnabled ?? config.deepSleepEnabled },
                set: { editableConfig?.deepSleepEnabled = $0 }
            ))
        }
    }

    private var saveSection: some View {
        Section {
            Button {
                guard let config = editableConfig else { return }
                isSaving = true
                device.writeConfig(config)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isSaving = false }
            } label: {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Write to Device")
                            .bold()
                    }
                    Spacer()
                }
            }
            .disabled(isSaving)
        }
    }

    private var readConfigSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Reading config…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            Button("Retry") { device.readConfig() }
        }
    }
}
