import SwiftUI
import CoreBluetooth

struct ScanView: View {
    let tool: AppTool
    @EnvironmentObject private var ble: BLEManager
    @State private var navigateToDevice = false

    var body: some View {
        Group {
            switch ble.bluetoothState {
            case .poweredOn:
                deviceList
            case .poweredOff:
                bluetoothOffView
            case .unauthorized:
                unauthorizedView
            case .unsupported:
                unsupportedView
            case .resetting, .unknown:
                waitingView
            @unknown default:
                waitingView
            }
        }
        .navigationTitle(tool.rawValue)
        .navigationDestination(isPresented: $navigateToDevice) {
            if let device = ble.connectedDevice {
                selectedToolView(device: device)
            }
        }
        .onChange(of: ble.connectedDevice) { _, device in
            navigateToDevice = device != nil
        }
        .onAppear {
            navigateToDevice = ble.connectedDevice != nil
        }
        .onDisappear {
            ble.stopScan()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ODLogoView()
            }
            ToolbarItem(placement: .primaryAction) {
                scanButton
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func selectedToolView(device: ODDevice) -> some View {
        switch tool {
        case .toolbox:
            ToolboxView()
        case .bleTester:
            DisplayToolView()
        }
    }

    private var deviceList: some View {
        List {
            if ble.discoveredDevices.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            if ble.isScanning {
                                ProgressView()
                            }
                            Text(ble.isScanning ? "Scanning for OpenDisplay devices…" : "No devices found")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 32)
                }
            } else {
                Section("Discovered Devices") {
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

    private var scanButton: some View {
        Button {
            ble.isScanning ? ble.stopScan() : ble.startScan()
        } label: {
            Label(ble.isScanning ? "Stop" : "Scan",
                  systemImage: ble.isScanning ? "stop.circle" : "arrow.clockwise")
        }
    }

    private var bluetoothOffView: some View {
        ContentUnavailableView(
            "Bluetooth Off",
            systemImage: "antenna.radiowaves.left.and.right.slash",
            description: Text("Enable Bluetooth in Settings to discover OpenDisplay devices.")
        )
    }

    private var unauthorizedView: some View {
        ContentUnavailableView(
            "Bluetooth Access Denied",
            systemImage: "antenna.radiowaves.left.and.right.slash",
            description: Text("Allow Bluetooth access for OpenDisplay in Settings to discover devices.")
        )
    }

    private var unsupportedView: some View {
        ContentUnavailableView(
            "Bluetooth Unavailable",
            systemImage: "antenna.radiowaves.left.and.right.slash",
            description: Text("This device does not support Bluetooth LE. The iOS Simulator cannot use Bluetooth — run on a physical device.")
        )
    }

    private var waitingView: some View {
        ContentUnavailableView {
            Label("Initializing…", systemImage: "antenna.radiowaves.left.and.right")
        }
    }
}
