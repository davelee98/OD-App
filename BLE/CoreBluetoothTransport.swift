import Foundation
import CoreBluetooth

/// The only type allowed to touch the OpenDisplay GATT characteristic.
/// Protocol framing and response handling live in `ble-common.js`.
final class CoreBluetoothTransport {
    typealias WriteCompletion = (Error?) -> Void

    let peripheral: CBPeripheral

    var onReady: (() -> Void)?
    var onNotification: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var onTrace: ((String) -> Void)?

    private var characteristic: CBCharacteristic?
    private var writes: [(data: Data, completion: WriteCompletion)] = []
    private var stallWatchdog: DispatchWorkItem?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    func start() {
        trace("GATT start; peripheralState=\(peripheral.state.rawValue), service=\(OD.serviceUUID.uuidString), delegate=\(String(describing: peripheral.delegate.map { type(of: $0) }))")
        armStallWatchdog(stage: "discoverServices")
        peripheral.discoverServices([OD.serviceUUID])
    }

    func write(_ data: Data, completion: @escaping WriteCompletion) {
        dispatchPrecondition(condition: .onQueue(.main))
        traceVerbose("write() queued \(data.count) bytes; queueDepthBefore=\(writes.count), characteristic=\(characteristic?.uuid.uuidString ?? "nil"), canSendWriteWithoutResponse=\(peripheral.canSendWriteWithoutResponse)")
        writes.append((data, completion))
        drainWrites()
    }

    private func drainWrites() {
        guard let characteristic else {
            trace("drainWrites: no characteristic yet; \(writes.count) write(s) queued and blocked")
            return
        }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        if !writes.isEmpty, !peripheral.canSendWriteWithoutResponse {
            trace("drainWrites: \(writes.count) write(s) queued but canSendWriteWithoutResponse=false; waiting for peripheralIsReady callback")
        }

        while !writes.isEmpty, peripheral.canSendWriteWithoutResponse {
            let next = writes.removeFirst()
            guard next.data.count <= maximum else {
                trace("drainWrites: packet too large (\(next.data.count) > \(maximum)); failing")
                next.completion(TransportError.packetTooLarge(actual: next.data.count, maximum: maximum))
                continue
            }
            peripheral.writeValue(next.data, for: characteristic, type: .withoutResponse)
            traceVerbose("drainWrites: wrote \(next.data.count) bytes; remainingQueue=\(writes.count)")
            next.completion(nil)
        }
    }

    func didDiscoverServices(_ error: Error?) {
        stallWatchdog?.cancel()
        trace("didDiscoverServices; state=\(peripheral.state.rawValue), error=\(error?.localizedDescription ?? "nil"), services=\(peripheral.services?.map(\.uuid.uuidString).joined(separator: ",") ?? "nil")")
        if let error {
            fail("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == OD.serviceUUID }) else {
            fail("OpenDisplay service 0x2446 was not found")
            return
        }
        armStallWatchdog(stage: "discoverCharacteristics")
        peripheral.discoverCharacteristics([OD.characteristicUUID], for: service)
    }

    func didDiscoverCharacteristics(for service: CBService, error: Error?) {
        stallWatchdog?.cancel()
        trace("didDiscoverCharacteristics; service=\(service.uuid.uuidString), error=\(error?.localizedDescription ?? "nil"), characteristics=\(service.characteristics?.map(\.uuid.uuidString).joined(separator: ",") ?? "nil")")
        if let error {
            fail("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == OD.characteristicUUID }) else {
            fail("OpenDisplay characteristic 0x2446 was not found")
            return
        }
        self.characteristic = characteristic
        trace("enabling notifications; properties=\(characteristic.properties.rawValue)")
        armStallWatchdog(stage: "setNotifyValue (likely awaiting a pairing/bonding prompt)")
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func didUpdateNotificationState(for characteristic: CBCharacteristic, error: Error?) {
        stallWatchdog?.cancel()
        trace("didUpdateNotificationState; notifying=\(characteristic.isNotifying), state=\(peripheral.state.rawValue), error=\(error?.localizedDescription ?? "nil")")
        if let error {
            fail("Enabling notifications failed: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            fail("OpenDisplay notifications are not enabled")
            return
        }
        onReady?()
        drainWrites()
    }

    func didModifyServices(_ invalidatedServices: [CBService]) {
        trace("didModifyServices; invalidated=\(invalidatedServices.map(\.uuid.uuidString).joined(separator: ","))")
        if invalidatedServices.contains(where: { $0.uuid == OD.serviceUUID }) {
            characteristic = nil
            fail("OpenDisplay service was invalidated by the peripheral mid-session")
        }
    }

    /// Detects a GATT handshake that never calls back. CoreBluetooth gives no delegate
    /// callback for this (e.g. a bonding/pairing prompt that never surfaced, or a stale
    /// peripheral reference), so a timer is the only way to observe and log it.
    private func armStallWatchdog(stage: String) {
        stallWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trace("STALL WATCHDOG: no callback 8s after \(stage); peripheralState=\(self.peripheral.state.rawValue), " +
                       "services=\(self.peripheral.services?.map(\.uuid.uuidString).joined(separator: ",") ?? "nil"), " +
                       "characteristic=\(self.characteristic?.uuid.uuidString ?? "nil"), " +
                       "isNotifying=\(self.characteristic?.isNotifying.description ?? "n/a"), " +
                       "canSendWriteWithoutResponse=\(self.peripheral.canSendWriteWithoutResponse), " +
                       "ancsAuthorized=\(self.peripheral.ancsAuthorized)")
        }
        stallWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func didUpdateValue(for characteristic: CBCharacteristic, error: Error?) {
        if let error {
            fail("Notification failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        trace("didUpdateValue: received \(data.count) bytes")
        onNotification?(data)
    }

    func isReadyToSendWriteWithoutResponse() {
        trace("peripheralIsReady(toSendWriteWithoutResponse:) fired; draining \(writes.count) queued write(s)")
        drainWrites()
    }

    private func fail(_ message: String) {
        trace("GATT failure: \(message)")
        onError?(message)
    }

    private func trace(_ message: String) {
        onTrace?(message)
    }

    /// High-frequency, per-write traces. Silent in normal use so image uploads (hundreds of
    /// writes) don't flood the log; enable with the `BLELogging.detailedPayloads` debug launch flag.
    private func traceVerbose(_ message: String) {
        guard BLELogging.detailedPayloads else { return }
        onTrace?(message)
    }

    enum TransportError: LocalizedError {
        case packetTooLarge(actual: Int, maximum: Int)

        var errorDescription: String? {
            switch self {
            case .packetTooLarge(let actual, let maximum):
                return "BLE packet is \(actual) bytes; Core Bluetooth allows \(maximum)"
            }
        }
    }
}
