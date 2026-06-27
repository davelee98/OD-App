import Foundation
import CoreBluetooth
import Combine

final class BLEManager: NSObject, ObservableObject {
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDevice: ODDevice?
    var namePrefixes = [OD.namePrefix]

    private var centralManager: CBCentralManager?
    private var deviceMap: [UUID: ODDevice] = [:]
    private var deviceObservation: AnyCancellable?

    override init() {
        super.init()
    }

    /// Creates Core Bluetooth only after the user explicitly asks to connect.
    func activate() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    /// Releases Core Bluetooth whenever there is no active BLE connection.
    func deactivate() {
        if let device = connectedDevice {
            centralManager?.cancelPeripheralConnection(device.peripheral)
        }
        centralManager?.stopScan()
        centralManager?.delegate = nil
        centralManager = nil
        deviceObservation = nil
        connectedDevice = nil
        discoveredDevices.removeAll()
        isScanning = false
        bluetoothState = .unknown
    }

    // MARK: - Scanning

    func startScan() {
        activate()
        guard centralManager?.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        isScanning = true
        // Scan without service UUID filter — some OD firmware versions don't advertise the
        // service UUID in the advertisement packet, so hardware filtering would miss them.
        // The name prefix filter in didDiscover handles narrowing to OD devices.
        centralManager?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        centralManager?.stopScan()
        isScanning = false
    }

    // MARK: - Connection

    func connect(_ discovered: DiscoveredDevice) {
        stopScan()
        if let idx = discoveredDevices.firstIndex(where: { $0.id == discovered.id }) {
            discoveredDevices[idx].connectionState = .connecting
        }
        centralManager?.connect(discovered.peripheral, options: nil)
    }

    func disconnect() {
        guard let device = connectedDevice else { return }
        centralManager?.cancelPeripheralConnection(device.peripheral)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let name = peripheral.name,
              namePrefixes.contains(where: { !$0.isEmpty && name.hasPrefix($0) }) else { return }
        let msd = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let device = DiscoveredDevice(peripheral: peripheral, rssi: RSSI.intValue, msd: msd)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[idx].rssi = RSSI.intValue
            discoveredDevices[idx].msd = msd
        } else {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let advertisedMSD = discoveredDevices.first(where: {
            $0.peripheral.identifier == peripheral.identifier
        })?.msd
        let device: ODDevice
        if let existing = deviceMap[peripheral.identifier] {
            device = existing
            if let advertisedMSD { device.ingestAdvertisement(advertisedMSD) }
        } else {
            device = ODDevice(peripheral: peripheral, initialMSD: advertisedMSD)
            deviceMap[peripheral.identifier] = device
        }
        device.connectionState = .connecting
        connectedDevice = device
        deviceObservation = device.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        device.discoverServices()
        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].connectionState = .connected
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        deviceMap[peripheral.identifier]?.connectionState = .failed
        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].connectionState = .failed
        }
        if connectedDevice?.peripheral.identifier == peripheral.identifier {
            deviceObservation = nil
            connectedDevice = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        deviceMap[peripheral.identifier]?.connectionState = .disconnected
        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].connectionState = .disconnected
        }
        if connectedDevice?.peripheral.identifier == peripheral.identifier {
            deviceObservation = nil
            connectedDevice = nil
            DispatchQueue.main.async { [weak self] in self?.deactivate() }
        }
    }
}

// MARK: - DiscoveredDevice

struct DiscoveredDevice: Identifiable {
    var id: UUID { peripheral.identifier }
    let peripheral: CBPeripheral
    var rssi: Int
    var msd: Data?
    var connectionState: ConnectionState = .disconnected

    var name: String { peripheral.name ?? "Unknown OD Device" }

    var msdHex: String? { msd?.hexString }

    var advertisement: ODAdvertisementData? {
        guard let msd else { return nil }
        return try? ODAdvertisementData.parse(msd)
    }

    var rssiDescription: String { "\(rssi) dBm" }

    var signalStrength: SignalStrength {
        switch rssi {
        case ..<(-80): return .weak
        case -80 ..< -60: return .fair
        default: return .good
        }
    }

    enum SignalStrength {
        case weak, fair, good
        var icon: String {
            switch self {
            case .weak: return "wifi.exclamationmark"
            case .fair: return "wifi"
            case .good: return "wifi"
            }
        }
    }
}
