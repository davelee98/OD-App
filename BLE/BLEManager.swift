import Foundation
import CoreBluetooth
import Combine
import os

final class BLEManager: NSObject, ObservableObject {
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDevice: ODDevice?
    @Published private(set) var connectionError: String?
    /// Shared traffic history for the BLE session; it is not owned by any one device.
    @Published private(set) var log: [LogEntry] = []
    var namePrefixes = OD.namePrefixes

    private var centralManager: CBCentralManager?
    /// Peripherals already logged as unmatched this scan — keeps the reject log to one line per
    /// device per scan instead of spamming on every advertisement.
    private var loggedUnmatched: Set<UUID> = []
    private var deviceMap: [UUID: ODDevice] = [:]
    private var deviceObservation: AnyCancellable?
    private var deviceStateObservation: AnyCancellable?
    /// Identifier we want to reconnect to (from the Saved Displays registry).
    private var pendingReconnectID: UUID?
    /// Strong reference to a peripheral we're connecting to before an ODDevice retains it.
    private var reconnectingPeripheral: CBPeripheral?
    /// A scan requested before Core Bluetooth reached `.poweredOn`; started once it powers on.
    private var pendingScan = false

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
            trace("activate reused central; state=\(centralManager?.state.rawValue ?? -1)", level: .info)
            return
        }
        trace("activate creating central", level: .info)
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
        loggedUnmatched.removeAll()
        isScanning = false
        bluetoothState = .unknown
        pendingReconnectID = nil
        reconnectingPeripheral = nil
        pendingScan = false
    }

    // MARK: - Scanning

    func startScan() {
        activate()
        guard centralManager?.state == .poweredOn else {
            // Cold start: the central is still powering on. Remember the request and start once
            // `centralManagerDidUpdateState` reports `.poweredOn` instead of silently no-oping.
            pendingScan = true
            trace("startScan deferred; central not powered on (state=\(centralManager?.state.rawValue ?? -1))", level: .warning)
            return
        }
        pendingScan = false
        discoveredDevices.removeAll()
        loggedUnmatched.removeAll()
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
        pendingScan = false
        centralManager?.stopScan()
        isScanning = false
    }

    func clearLog() {
        log.removeAll()
        trimmedCount = 0
    }

    /// Count of log entries dropped by the cap over this session. Surfaces a "showing the most
    /// recent N of M" notice so a trimmed on-screen log (and export) doesn't look complete.
    @Published private(set) var trimmedCount = 0

    /// Cap on retained log entries. The UI only shows the tail, so an unbounded array just leaks
    /// memory during long sessions (image uploads alone add hundreds of entries). Mirrors the
    /// trimming ToolboxView.statusLog uses.
    private static let maxLogEntries = 500

    /// Centralized, bounded append for the shared traffic log — trims the oldest entries when the
    /// cap is exceeded so appends never grow without limit.
    func appendLog(_ entry: LogEntry) {
        log.append(entry)
        if log.count > Self.maxLogEntries {
            let overflow = log.count - Self.maxLogEntries
            log.removeFirst(overflow)
            trimmedCount += overflow
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
        trace("reconnect requested id=\(identifier.uuidString); current=\(connectedDevice?.deviceID ?? "nil") appState=\(String(describing: connectedDevice?.connectionState)) peripheralState=\(connectedDevice?.peripheral.state.rawValue ?? -1)", level: .info)
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
            trace("reconnect deferred; pending=\(pendingReconnectID?.uuidString ?? "nil") centralState=\(centralManager?.state.rawValue ?? -1)", level: .warning)
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
        trace("central state changed: \(central.state.rawValue)", level: .info)
        bluetoothState = central.state
        if central.state == .poweredOn {
            attemptPendingReconnect()
            if pendingScan { startScan() }
        } else if isScanning {
            // Bluetooth turned off / reset mid-scan: remember and auto-resume on power-on,
            // independent of which view happens to be visible. Never starts a scan the app
            // hadn't already asked for.
            pendingScan = true
            isScanning = false
        }
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
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let msd = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        var serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        serviceUUIDs += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []

        let matched = ODDeviceAdmission.isLikelyOpenDisplay(
            gapName: peripheral.name, localName: localName,
            serviceUUIDs: serviceUUIDs, msd: msd, prefixes: namePrefixes)

        if !matched, loggedUnmatched.insert(peripheral.identifier).inserted {
            ODLog.ble.debug("unmatched \(peripheral.identifier.uuidString, privacy: .public) name=\(peripheral.name ?? "nil", privacy: .public) local=\(localName ?? "nil", privacy: .public) services=\(serviceUUIDs.map(\.uuidString).joined(separator: ","), privacy: .public) msd=\(msd?.count ?? 0)B rssi=\(RSSI.intValue)")
        }

        // Store every peripheral; views filter on `isLikelyOpenDisplay`, so the "Show all
        // devices" toggle works without a rescan.
        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[idx].rssi = RSSI.intValue
            // A scan-response without MSD/local name must not wipe values a previous packet carried.
            if msd != nil { discoveredDevices[idx].msd = msd }
            if localName != nil { discoveredDevices[idx].localName = localName }
            // OR, never demote: a later packet lacking service UUIDs must not un-match the device.
            discoveredDevices[idx].isLikelyOpenDisplay = discoveredDevices[idx].isLikelyOpenDisplay || matched
        } else {
            if matched {
                ODLog.ble.debug("discovered \(peripheral.name ?? localName ?? "unnamed", privacy: .public) rssi=\(RSSI.intValue) msd=\(msd?.hexString ?? "nil", privacy: .public)")
            }
            discoveredDevices.append(DiscoveredDevice(
                peripheral: peripheral, rssi: RSSI.intValue, msd: msd,
                localName: localName, isLikelyOpenDisplay: matched))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        trace("didConnect id=\(peripheral.identifier.uuidString) name=\(peripheral.name ?? "nil") peripheralState=\(peripheral.state.rawValue)", level: .info)
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
        trace("didFailToConnect id=\(peripheral.identifier.uuidString); state=\(peripheral.state.rawValue); error=\(error?.localizedDescription ?? "unknown error")", level: .error)
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
        trace("didDisconnect id=\(peripheral.identifier.uuidString); state=\(peripheral.state.rawValue); error=\(error?.localizedDescription ?? "nil")", level: .info)
        deviceMap[peripheral.identifier]?.didDisconnect()
        if let idx = discoveredDevices.firstIndex(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredDevices[idx].connectionState = .disconnected
        }
        if connectedDevice?.peripheral.identifier == peripheral.identifier {
            deviceObservation = nil
            deviceStateObservation = nil
            connectedDevice = nil
            // Don't tear down Core Bluetooth if a reconnect (e.g. to a different saved display) is
            // already pending — deactivate() would cancel it. Re-check inside the async hop because
            // the reconnect request can land between this check and the block running.
            if pendingReconnectID == nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pendingReconnectID == nil else { return }
                    self.deactivate()
                }
            }
        }
    }
}

extension BLEManager {
    func trace(_ message: String, level: OSLogType = .debug) {
        let entry = LogEntry(direction: .system, data: Data(), label: message)
        ODLog.ble.log(level: level, "\(message, privacy: .public)")
        if Thread.isMainThread {
            appendLog(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.appendLog(entry) }
        }
    }
}

// MARK: - DiscoveredDevice

/// Decides whether a discovered peripheral looks like an OpenDisplay device. Pure — no
/// CBPeripheral involved — so it's unit-testable. A device is admitted if ANY signal matches:
/// name prefix (GAP or advertised local name, case-insensitive), the OpenDisplay service UUID in
/// the advertisement, or a manufacturer-data payload shaped like the OD advertisement. The
/// "Show all devices" toggle is the recall safety net, so this favors precision.
enum ODDeviceAdmission {
    /// Company ID 0x004C (Apple) floods every scan with 16-byte-ish Continuity traffic and is
    /// never an OD device.
    private static let excludedCompanyIDs: Set<UInt16> = [0x004C]

    static func isLikelyOpenDisplay(
        gapName: String?,
        localName: String?,
        serviceUUIDs: [CBUUID],
        msd: Data?,
        prefixes: [String] = OD.namePrefixes
    ) -> Bool {
        // (a) name prefix — cached GAP name OR the advertisement's local name.
        for candidate in [gapName, localName].compactMap({ $0 }) {
            if prefixes.contains(where: { !$0.isEmpty &&
                candidate.range(of: $0, options: [.anchored, .caseInsensitive]) != nil }) {
                return true
            }
        }
        // (b) advertises the OpenDisplay service (0x2446).
        if serviceUUIDs.contains(OD.serviceUUID) { return true }
        // (c) manufacturer data shaped like the OD payload: exactly 16 bytes (the firmware's
        //     fixed layout — `>=` would admit most Apple/vendor traffic), excluding known-noisy
        //     company IDs. The company ID is otherwise unvalidated, matching
        //     ODAdvertisementData.parse which accepts any.
        if let msd, msd.count == 16 {
            let companyID = UInt16(msd[msd.startIndex]) | (UInt16(msd[msd.startIndex + 1]) << 8)
            if !excludedCompanyIDs.contains(companyID) { return true }
        }
        return false
    }
}

struct DiscoveredDevice: Identifiable {
    var id: UUID { peripheral.identifier }
    let peripheral: CBPeripheral
    var rssi: Int
    var msd: Data?
    var localName: String?                 // CBAdvertisementDataLocalNameKey, fresh per advertisement
    var isLikelyOpenDisplay: Bool = true   // admission verdict; views filter on it
    var connectionState: ConnectionState = .disconnected

    // localName wins: it's refreshed from the live advertisement every scan, while
    // peripheral.name is CoreBluetooth-cached and can get stuck on a stale broadcast
    // name (e.g. "OTA" from a bootloader reboot) after the device resumes advertising
    // its real name.
    var name: String { localName ?? peripheral.name ?? "Unknown OD Device" }

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
