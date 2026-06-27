import Foundation
import CoreBluetooth
import Combine

final class ODDevice: NSObject, ObservableObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral

    @Published var connectionState: ConnectionState = .connecting
    @Published var firmwareVersion: String?
    @Published var msdHex: String?
    @Published var advertisement: ODAdvertisementData?
    @Published var advertisementError: String?
    @Published var isReadingAdvertisement = false
    @Published var isAuthenticated = false
    @Published var config: ODConfigModel?
    @Published var log: [LogEntry] = []
    @Published var lastError: String?
    @Published var uploadProgress: Double = 0
    @Published var isUploading = false

    var name: String { peripheral.name ?? peripheral.identifier.uuidString }
    var deviceID: String { peripheral.identifier.uuidString }

    var psk: Data? {
        get { ODAuth.loadPSK(forDevice: deviceID) }
        set {
            if let key = newValue { ODAuth.savePSK(key, forDevice: deviceID) }
            else { ODAuth.deletePSK(forDevice: deviceID) }
        }
    }

    var batteryPercent: Int? {
        advertisement?.bq27220?.percent
    }

    var isCharging: Bool {
        advertisement?.bq27220?.isCharging ?? false
    }

    private var characteristic: CBCharacteristic?
    private var msdData: Data?

    private struct PendingCommand {
        let data: Data
        let awaitNotification: Bool  // false = complete on write-ack, true = wait for notify
        let completion: ((Data) -> Void)?
    }
    private var queue: [PendingCommand] = []
    private var inFlight: PendingCommand?

    private var configBuffer = Data()
    private var configExpectedLength = 0

    init(peripheral: CBPeripheral, initialMSD: Data? = nil) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
        if let initialMSD {
            msdData = Data(initialMSD.prefix(16))
            msdHex = msdData?.hexString
            advertisement = try? ODAdvertisementData.parse(initialMSD)
        }
    }

    // MARK: - GATT Setup

    func discoverServices() { peripheral.discoverServices([OD.serviceUUID]) }

    // MARK: - Core Commands

    func sendRaw(_ data: Data, label: String? = nil, completion: ((Data) -> Void)? = nil) {
        enqueue(PendingCommand(data: data, awaitNotification: true, completion: completion))
        appendLog(direction: .sent, data: data, label: label)
    }

    func readFirmware() { sendRaw(ODCommands.readFirmwareVersion(), label: "Read Firmware") }
    func readMSD() {
        isReadingAdvertisement = true
        advertisementError = nil
        sendRaw(ODCommands.readMSD(), label: "Read Advertising Data")
    }

    /// Accepts manufacturer data obtained directly from a scan advertisement.
    func ingestAdvertisement(_ data: Data) {
        publishAdvertisement(data)
    }

    func readConfig() {
        configBuffer = Data(); configExpectedLength = 0
        sendRaw(ODCommands.readConfig(), label: "Read Config")
    }

    func writeConfig(_ model: ODConfigModel, completion: ((Bool) -> Void)? = nil) {
        let blob = ODConfig.serialize(model)
        guard !blob.isEmpty else {
            lastError = "Could not build Toolbox configuration"
            completion?(false)
            return
        }
        let packets = ODCommands.writeConfig(blob)
        for (i, pkt) in packets.enumerated() {
            let label = i == 0 ? "Write Config (first)" : "Write Config (chunk)"
            appendLog(direction: .sent, data: pkt, label: label)
            if i == packets.count - 1 {
                enqueue(PendingCommand(data: pkt, awaitNotification: true) { response in
                    let succeeded = response.count >= 2 && response[0] == 0x00 && response[1] == 0xCE
                    DispatchQueue.main.async { completion?(succeeded) }
                })
            } else {
                enqueueNoResponse(pkt)
            }
        }
    }

    func reboot() { sendRaw(ODCommands.reboot(), label: "Reboot") }

    func enterDFU() { sendRaw(ODCommands.enterDFU(), label: "Enter DFU") }

    func sendDeepSleep() { sendRaw(ODCommands.deepSleep(), label: "Deep Sleep") }

    // MARK: - Authentication

    func authenticate(psk: Data) {
        sendRaw(ODCommands.authChallenge(), label: "Auth Challenge") { [weak self] response in
            guard let self else { return }
            guard response.count >= 23,
                  response[0] == 0x00, response[1] == 0x50 else {
                self.lastError = "Auth challenge response malformed"; return
            }
            let serverNonce  = Data(response[3..<19])
            let deviceIDBytes = Data(response[19..<23])
            let clientNonce  = ODAuth.randomNonce()
            let proof = ODAuth.challengeResponse(psk: psk, serverNonce: serverNonce,
                                                  clientNonce: clientNonce, deviceID: deviceIDBytes)
            self.sendRaw(ODCommands.authProof(clientNonce: clientNonce, challengeResponse: proof),
                         label: "Auth Proof") { proofResponse in
                DispatchQueue.main.async {
                    if proofResponse.count >= 3, proofResponse[0] == 0x00, proofResponse[1] == 0x50 {
                        self.isAuthenticated = true
                    } else {
                        self.lastError = "Authentication failed"
                    }
                }
            }
        }
    }

    // MARK: - LED

    func sendLEDPattern(brightness: Int, colors: [LEDColor], repeats: Int) {
        let data = ODCommands.ledPattern(brightness: brightness, colors: colors, repeats: repeats)
        sendRaw(data, label: "LED Pattern")
    }

    func stopLED() { sendRaw(ODCommands.ledStop(), label: "LED Stop") }

    // MARK: - Buzzer

    func sendBuzzerPattern(instance: UInt8 = 0, repeats: Int, steps: [BuzzerStep]) {
        let data = ODCommands.buzzerPattern(instance: instance, repeats: repeats, steps: steps)
        sendRaw(data, label: "Buzzer Pattern")
    }

    // MARK: - NFC

    func writeNFC(type: UInt8, payload: Data) {
        let nfcChunkSize = 120
        if payload.count <= nfcChunkSize {
            sendRaw(ODCommands.nfcWriteSingle(type: type, payload: payload), label: "NFC Write")
        } else {
            sendRaw(ODCommands.nfcWriteStart(type: type, totalLength: UInt16(payload.count)),
                    label: "NFC Write Start")
            for chunk in payload.chunked(size: nfcChunkSize) {
                sendRaw(ODCommands.nfcWriteChunk(chunk), label: "NFC Chunk")
            }
            sendRaw(ODCommands.nfcWriteEnd(), label: "NFC Write End")
        }
    }

    // MARK: - Image Upload

    func uploadImage(pixelData: Data, compressed: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let payload: Data
            if compressed, let c = ImageProcessor.deflate(pixelData) {
                payload = c
            } else {
                payload = pixelData
            }

            DispatchQueue.main.async { self.isUploading = true; self.uploadProgress = 0 }

            // imageStart: uncompressed size only — wait for device 0x70 ACK before sending chunks
            let startPkt = ODCommands.imageStart(uncompressedSize: UInt32(pixelData.count))
            self.appendLog(direction: .sent, data: startPkt, label: "Image Start")
            self.enqueue(PendingCommand(data: startPkt, awaitNotification: true) { [weak self] _ in
                guard let self else { return }

                // Device ready — send chunks one at a time, waiting for 0x71 ACK each
                let chunks = payload.chunked(size: OD.bleChunkSize - 2)
                for (i, chunk) in chunks.enumerated() {
                    let pkt = ODCommands.imageChunk(chunk)
                    self.appendLog(direction: .sent, data: pkt, label: nil)
                    let progress = Double(i + 1) / Double(max(chunks.count, 1))
                    self.enqueue(PendingCommand(data: pkt, awaitNotification: true) { [weak self] _ in
                        DispatchQueue.main.async { self?.uploadProgress = progress }
                    })
                }

                let endPkt = ODCommands.imageEnd()
                self.appendLog(direction: .sent, data: endPkt, label: "Image End")
                self.enqueue(PendingCommand(data: endPkt, awaitNotification: true) { [weak self] _ in
                    DispatchQueue.main.async { self?.isUploading = false; self?.uploadProgress = 1.0 }
                })
            })
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { logError("Service discovery: \(e.localizedDescription)"); return }
        guard let svc = peripheral.services?.first(where: { $0.uuid == OD.serviceUUID }) else {
            logError("OD service not found"); return
        }
        peripheral.discoverCharacteristics([OD.characteristicUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let e = error { logError("Characteristic: \(e.localizedDescription)"); return }
        guard let ch = service.characteristics?.first(where: { $0.uuid == OD.characteristicUUID }) else {
            logError("OD characteristic not found"); return
        }
        characteristic = ch
        peripheral.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor
                    characteristic: CBCharacteristic, error: Error?) {
        if let e = error { logError("Notify: \(e.localizedDescription)"); return }
        DispatchQueue.main.async { self.connectionState = .connected }
        readFirmware()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor
                    characteristic: CBCharacteristic, error: Error?) {
        if let e = error { logError("Write: \(e.localizedDescription)") }
        if let cmd = inFlight, !cmd.awaitNotification {
            completeInFlight(Data())
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor
                    characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        appendLog(direction: .received, data: data, label: decodeResponseLabel(data))
        handleResponse(data)
    }

    // MARK: - Command Queue

    private func enqueue(_ cmd: PendingCommand) {
        queue.append(cmd)
        drainQueue()
    }

    private func enqueueNoResponse(_ data: Data) {
        queue.append(PendingCommand(data: data, awaitNotification: false, completion: nil))
        drainQueue()
    }

    private func drainQueue() {
        guard inFlight == nil, !queue.isEmpty, let ch = characteristic else { return }
        let next = queue.removeFirst()
        inFlight = next
        if next.awaitNotification {
            peripheral.writeValue(next.data, for: ch, type: .withResponse)
        } else {
            guard peripheral.canSendWriteWithoutResponse else {
                queue.insert(next, at: 0)
                inFlight = nil
                return
            }
            peripheral.writeValue(next.data, for: ch, type: .withoutResponse)
            inFlight = nil
            DispatchQueue.main.async { self.drainQueue() }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainQueue()
    }

    // MARK: - Response Handling

    private func handleResponse(_ data: Data) {
        guard data.count >= 2 else { completeInFlight(data); return }
        if data.count >= 3, data[0] == 0x00, data[2] == 0xFE {
            DispatchQueue.main.async {
                self.lastError = "Authentication required"
                if data[1] == 0x44 {
                    self.advertisementError = "Authentication required"
                    self.isReadingAdvertisement = false
                }
            }
            completeInFlight(data)
            return
        }
        switch data[1] {
        case 0x43:
            if data.count > 3, let str = String(data: data[3...], encoding: .utf8) {
                DispatchQueue.main.async { self.firmwareVersion = str.trimmingCharacters(in: .controlCharacters) }
            }
            completeInFlight(data)
        case 0x44:
            guard data[0] == 0x00 else {
                DispatchQueue.main.async {
                    self.advertisementError = "Device rejected advertising data read"
                    self.isReadingAdvertisement = false
                }
                completeInFlight(data)
                return
            }
            guard data.count >= 18 else {
                DispatchQueue.main.async {
                    self.advertisementError = "Expected 16 advertisement bytes, got \(max(0, data.count - 2))"
                    self.isReadingAdvertisement = false
                }
                completeInFlight(data)
                return
            }
            publishAdvertisement(Data(data[2..<18]))
            completeInFlight(data)
        case 0x40:
            assembleConfigChunk(data)
        case 0x50:
            completeInFlight(data)
        case 0x70:  // imageStart ACK — triggers chunk sending
            completeInFlight(data)
        case 0x71:  // imageData chunk ACK — advance queue to next chunk
            completeInFlight(data)
        case 0x72:
            DispatchQueue.main.async { self.isUploading = false }
            completeInFlight(data)
        case 0xCE:
            completeInFlight(data)
        case 0xCF:
            DispatchQueue.main.async { self.lastError = "Device rejected Toolbox configuration" }
            completeInFlight(data)
        default:
            completeInFlight(data)
        }
    }

    private func assembleConfigChunk(_ data: Data) {
        guard data.count >= 4 else { completeInFlight(data); return }
        let chunkNum = Int(data[2]) | (Int(data[3]) << 8)
        if chunkNum == 0 && data.count >= 6 {
            configExpectedLength = Int(data[4]) | (Int(data[5]) << 8)
            configBuffer = Data(data[6...])
        } else {
            configBuffer.append(data[4...])
        }
        if configBuffer.count >= configExpectedLength && configExpectedLength > 0 {
            let blob = configBuffer
            DispatchQueue.main.async {
                self.config = try? ODConfig.parse(blob)
                self.reparseAdvertisement()
            }
            completeInFlight(data)
        }
    }

    private func completeInFlight(_ data: Data) {
        let cmd = inFlight; inFlight = nil
        cmd?.completion?(data)
        drainQueue()
    }

    private func publishAdvertisement(_ data: Data) {
        do {
            let payload = Data(data.prefix(16))
            let decoded = try ODAdvertisementData.parse(
                payload,
                layout: ODAdvertisementLayout(config: config)
            )
            DispatchQueue.main.async {
                self.msdData = payload
                self.msdHex = payload.hexString
                self.advertisement = decoded
                self.advertisementError = nil
                self.isReadingAdvertisement = false
            }
        } catch {
            DispatchQueue.main.async {
                self.advertisementError = error.localizedDescription
                self.isReadingAdvertisement = false
            }
        }
    }

    private func reparseAdvertisement() {
        guard let msdData else { return }
        publishAdvertisement(msdData)
    }

    // MARK: - Logging

    private func appendLog(direction: LogEntry.Direction, data: Data, label: String?) {
        let entry = LogEntry(direction: direction, data: data, label: label)
        DispatchQueue.main.async { self.log.append(entry) }
    }

    private func logError(_ msg: String) {
        DispatchQueue.main.async { self.lastError = msg }
    }

    private func decodeResponseLabel(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let status = data[0] == 0x00 ? "OK" : (data[0] == 0xFF ? "ERR" : "?")
        if let cmd = OD.Cmd(rawValue: UInt16(data[0]) << 8 | UInt16(data[1])) {
            return "\(status) \(cmd.displayName)"
        }
        return status
    }
}
