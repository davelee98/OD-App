import Foundation
import CoreBluetooth
import Combine

final class BLEManager: NSObject, ObservableObject {
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDevice: ODDevice?
    @Published private(set) var connectionError: String?
    /// Shared traffic history for the BLE session; it is not owned by any one device.
    @Published private(set) var log: [LogEntry] = []
    var namePrefixes = [OD.namePrefix]

    private var centralManager: CBCentralManager?
    private var deviceMap: [UUID: ODDevice] = [:]
    private var deviceObservation: AnyCancellable?
    private var deviceStateObservation: AnyCancellable?
    /// Identifier we want to reconnect to (from the Saved Displays registry).
    private var pendingReconnectID: UUID?
    /// Strong reference to a peripheral we're connecting to before an ODDevice retains it.
    private var reconnectingPeripheral: CBPeripheral?

    override init() {
        super.init()
#if DEBUG
        do {
            _ = try OpenDisplayJSRuntime()
        } catch {
            assertionFailure("ble-common.js preflight failed: \(error.localizedDescription)")
        }
#endif
    }

    /// Creates Core Bluetooth only after the user explicitly asks to connect.
    func activate() {
        guard centralManager == nil else {
            trace("activate reused central; state=\(centralManager?.state.rawValue ?? -1)")
            return
        }
        trace("activate creating central")
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
        deviceStateObservation = nil
        connectedDevice = nil
        // CBPeripheral instances belong to the CBCentralManager that produced them. Reusing an
        // ODDevice after recreating the central leaves its transport attached to a stale peripheral.
        deviceMap.removeAll()
        discoveredDevices.removeAll()
        isScanning = false
        bluetoothState = .unknown
        pendingReconnectID = nil
        reconnectingPeripheral = nil
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

    func clearLog() {
        log.removeAll()
    }

    /// Cap on retained log entries. The UI only shows the tail, so an unbounded array just leaks
    /// memory during long sessions (image uploads alone add hundreds of entries). Mirrors the
    /// trimming ToolboxView.statusLog uses.
    private static let maxLogEntries = 500

    /// Centralized, bounded append for the shared traffic log — trims the oldest entries when the
    /// cap is exceeded so appends never grow without limit.
    func appendLog(_ entry: LogEntry) {
        log.append(entry)
        if log.count > Self.maxLogEntries {
            log.removeFirst(log.count - Self.maxLogEntries)
        }
    }

    // MARK: - Connection

    func connect(_ discovered: DiscoveredDevice) {
        connectionError = nil
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

    func isPeripheralConnected(_ identifier: UUID) -> Bool {
        guard let device = connectedDevice else { return false }
        return device.peripheral.identifier == identifier && device.peripheral.state == .connected
    }

    // MARK: - Reconnect to a saved display

    /// Reconnect to a previously-saved display by its peripheral identifier — no user scan needed
    /// when iOS still knows the peripheral. Falls back to a scan if it doesn't.
    func reconnect(to identifier: UUID) {
        trace("reconnect requested id=\(identifier.uuidString); current=\(connectedDevice?.deviceID ?? "nil") appState=\(String(describing: connectedDevice?.connectionState)) peripheralState=\(connectedDevice?.peripheral.state.rawValue ?? -1)")
        activate()
        connectionError = nil
        pendingReconnectID = identifier
        attemptPendingReconnect()
    }

    /// Stops an in-flight reconnect without disturbing a different, healthy connection.
    func cancelReconnect(to identifier: UUID) {
        if pendingReconnectID == identifier {
            pendingReconnectID = nil
            stopScan()
        }
        if reconnectingPeripheral?.identifier == identifier {
            if let reconnectingPeripheral {
                centralManager?.cancelPeripheralConnection(reconnectingPeripheral)
            }
            reconnectingPeripheral = nil
        }
        if let device = connectedDevice,
           device.peripheral.identifier == identifier,
           device.connectionState != .connected {
            centralManager?.cancelPeripheralConnection(device.peripheral)
        }
    }

    /// Connect directly to a peripheral obtained via `retrievePeripherals` or a scan match.
    func connect(peripheral: CBPeripheral) {
        connectionError = nil
        stopScan()
        reconnectingPeripheral = peripheral
        centralManager?.connect(peripheral, options: nil)
    }

    private func attemptPendingReconnect() {
        guard let id = pendingReconnectID,
              let central = centralManager, central.state == .poweredOn else {
            trace("reconnect deferred; pending=\(pendingReconnectID?.uuidString ?? "nil") centralState=\(centralManager?.state.rawValue ?? -1)")
            return
        }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first {
            trace("retrievePeripherals found id=\(id.uuidString); state=\(peripheral.state.rawValue)")
            pendingReconnectID = nil
            connect(peripheral: peripheral)
        } else {
            trace("retrievePeripherals missed id=\(id.uuidString); scanning")
            // iOS no longer knows this peripheral — scan and auto-connect when it advertises.
            startScan()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        trace("central state changed: \(central.state.rawValue)")
        bluetoothState = central.state
        if central.state == .poweredOn { attemptPendingReconnect() }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Auto-connect a saved display the moment it advertises (scan fallback path).
        if peripheral.identifier == pendingReconnectID {
            pendingReconnectID = nil
            connect(peripheral: peripheral)
            return
        }
        guard let name = peripheral.name,
              namePrefixes.contains(where: { !$0.isEmpty && name.hasPrefix($0) }) else { return }
        let msd = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        print("[BLE] discovered \(name) rssi=\(RSSI.intValue) msd=\(msd?.hexString ?? "nil")")
        let device = DiscoveredDevice(peripheral: peripheral, rssi: RSSI.intValue, msd: msd)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[idx].rssi = RSSI.intValue
            discoveredDevices[idx].msd = msd
        } else {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        trace("didConnect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") peripheralState=\(peripheral.state.rawValue)")
        let advertisedMSD = discoveredDevices.first(where: {
            $0.peripheral.identifier == peripheral.identifier
        })?.msd
        let device: ODDevice
        if let existing = deviceMap[peripheral.identifier], existing.peripheral === peripheral {
            trace("reusing ODDevice for the same CBPeripheral instance")
            device = existing
            if let advertisedMSD { device.ingestAdvertisement(advertisedMSD) }
        } else {
            if deviceMap[peripheral.identifier] != nil {
                trace("replacing stale ODDevice because CBCentralManager returned a new CBPeripheral instance")
            } else {
                trace("creating ODDevice for new peripheral")
            }
            device = ODDevice(
                peripheral: peripheral,
                initialMSD: advertisedMSD,
                logHandler: { [weak self] entry in self?.appendLog(entry) }
            )
            deviceMap[peripheral.identifier] = device
        }
        device.connectionState = .connecting
        connectedDevice = device
        reconnectingPeripheral = nil
        deviceObservation = device.objectWillChange.sink { [weak self] _ in
            // ODDevice publishes in willSet. Forward on the next main-loop turn so views read
            // the new value rather than reevaluating against the previous connection state.
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        deviceStateObservation = device.$connectionState.sink { [weak self] state in
            self?.trace("device appState published id=\(peripheral.identifier.uuidString): \(state); peripheralState=\(peripheral.state.rawValue)")
            DispatchQueue.main.async {
                guard let self,
                      let idx = self.discoveredDevices.firstIndex(where: {
                          $0.peripheral.identifier == peripheral.identifier
                      }) else { return }
                self.discoveredDevices[idx].connectionState = state
            }
        }
        device.discoverServices()
        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].connectionState = .connecting
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        trace("didFailToConnect id=\(peripheral.identifier.uuidString); state=\(peripheral.state.rawValue); error=\(error?.localizedDescription ?? "unknown error")")
        connectionError = error?.localizedDescription ?? "The display could not be reached."
        reconnectingPeripheral = nil
        deviceMap[peripheral.identifier]?.connectionState = .failed
        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].connectionState = .failed
        }
        if connectedDevice?.peripheral.identifier == peripheral.identifier {
            deviceObservation = nil
            deviceStateObservation = nil
            connectedDevice = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        trace("didDisconnect id=\(peripheral.identifier.uuidString); state=\(peripheral.state.rawValue); error=\(error?.localizedDescription ?? "nil")")
        deviceMap[peripheral.identifier]?.didDisconnect()
        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].connectionState = .disconnected
        }
        if connectedDevice?.peripheral.identifier == peripheral.identifier {
            deviceObservation = nil
            deviceStateObservation = nil
            connectedDevice = nil
            DispatchQueue.main.async { [weak self] in self?.deactivate() }
        }
    }
}

extension BLEManager {
    func trace(_ message: String) {
        let entry = LogEntry(direction: .system, data: Data(), label: message)
        print("[BLETrace] \(message)")
        if Thread.isMainThread {
            appendLog(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.appendLog(entry) }
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
