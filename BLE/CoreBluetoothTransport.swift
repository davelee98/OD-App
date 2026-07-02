import Foundation
import CoreBluetooth

/// The only type allowed to touch the OpenDisplay GATT characteristic.
/// Protocol framing and response handling live in `ble-common.js`.
final class CoreBluetoothTransport: NSObject, CBPeripheralDelegate {
    typealias WriteCompletion = (Error?) -> Void

    let peripheral: CBPeripheral

    var onReady: (() -> Void)?
    var onNotification: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var onTrace: ((String) -> Void)?

    private var characteristic: CBCharacteristic?
    private var writes: [(data: Data, completion: WriteCompletion)] = []

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    func start() {
        peripheral.delegate = self
        trace("GATT start; peripheralState=\(peripheral.state.rawValue), service=\(OD.serviceUUID.uuidString)")
        peripheral.discoverServices([OD.serviceUUID])
    }

    func write(_ data: Data, completion: @escaping WriteCompletion) {
        dispatchPrecondition(condition: .onQueue(.main))
        writes.append((data, completion))
        drainWrites()
    }

    private func drainWrites() {
        guard let characteristic else { return }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)

        while !writes.isEmpty, peripheral.canSendWriteWithoutResponse {
            let next = writes.removeFirst()
            guard next.data.count <= maximum else {
                next.completion(TransportError.packetTooLarge(actual: next.data.count, maximum: maximum))
                continue
            }
            peripheral.writeValue(next.data, for: characteristic, type: .withoutResponse)
            next.completion(nil)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        trace("didDiscoverServices; state=\(peripheral.state.rawValue), error=\(error?.localizedDescription ?? "nil"), services=\(peripheral.services?.map(\.uuid.uuidString).joined(separator: ",") ?? "nil")")
        if let error {
            fail("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == OD.serviceUUID }) else {
            fail("OpenDisplay service 0x2446 was not found")
            return
        }
        peripheral.discoverCharacteristics([OD.characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
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
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            fail("Notification failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }
        onNotification?(data)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainWrites()
    }

    private func fail(_ message: String) {
        trace("GATT failure: \(message)")
        onError?(message)
    }

    private func trace(_ message: String) {
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
