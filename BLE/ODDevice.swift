import Foundation
import CoreBluetooth
import Combine

/// Observable app-facing device. Core Bluetooth owns the radio; `ble-common.js` owns the protocol.
final class ODDevice: NSObject, ObservableObject {
    let peripheral: CBPeripheral

    @Published var connectionState: ConnectionState = .connecting
    @Published var firmwareVersion: String?
    @Published var msdHex: String?
    @Published var advertisement: ODAdvertisementData?
    @Published var advertisementError: String?
    @Published var isReadingAdvertisement = false
    @Published var isAuthenticated = false
    @Published var config: ODConfigModel?
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

    var batteryPercent: Int? { advertisement?.bq27220?.percent }
    var isCharging: Bool { advertisement?.bq27220?.isCharging ?? false }

    private let transport: CoreBluetoothTransport
    private let logHandler: (LogEntry) -> Void
    private var runtime: OpenDisplayJSRuntime?
    private var msdData: Data?

    init(peripheral: CBPeripheral, initialMSD: Data? = nil,
         logHandler: @escaping (LogEntry) -> Void) {
        self.peripheral = peripheral
        self.transport = CoreBluetoothTransport(peripheral: peripheral)
        self.logHandler = logHandler
        super.init()

        if let initialMSD {
            msdData = Data(initialMSD.prefix(16))
            msdHex = msdData?.hexString
            advertisement = try? ODAdvertisementData.parse(initialMSD)
        }

        configureTransport()
        do {
            runtime = try OpenDisplayJSRuntime()
            configureRuntime()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - GATT lifecycle

    func discoverServices() {
        trace("ODDevice discoverServices; appState=\(connectionState), peripheralState=\(peripheral.state.rawValue), runtimeReady=\(runtime != nil)")
        guard runtime != nil else {
            lastError = "ble-common.js runtime is unavailable"
            connectionState = .failed
            return
        }
        transport.start()
    }

    func didDisconnect() {
        runtime?.setConnected(false)
        connectionState = .disconnected
        isAuthenticated = false
        isUploading = false
    }

    private func configureTransport() {
        transport.onReady = { [weak self] in
            guard let self else { return }
            self.trace("GATT ready; changing appState \(self.connectionState) → connected")
            self.runtime?.setConnected(true)
            self.connectionState = .connected
            self.readFirmware()
        }
        transport.onNotification = { [weak self] data in
            guard let self else { return }
            self.appendLog(direction: .received, data: data, label: self.responseLabel(data))
            self.runtime?.receiveNotification(data)
        }
        transport.onError = { [weak self] message in
            self?.trace("transport error; changing appState to failed: \(message)")
            self?.lastError = message
            self?.connectionState = .failed
        }
        transport.onTrace = { [weak self] message in self?.trace(message) }
    }

    private func configureRuntime() {
        runtime?.onWrite = { [weak self] data, completion in
            guard let self else {
                completion(OpenDisplayJSRuntime.RuntimeError.transportUnavailable)
                return
            }
            self.appendLog(direction: .sent, data: data, label: nil)
            self.transport.write(data, completion: completion)
        }
        runtime?.onEvent = { [weak self] type, payload in
            self?.handleRuntimeEvent(type: type, payload: payload)
        }
    }

    // MARK: - Core commands

    func sendRaw(_ data: Data, label: String? = nil, completion: ((Data) -> Void)? = nil) {
        call("sendHex", arguments: ["hex": data.hexString.replacingOccurrences(of: " ", with: "")]) { result in
            if case .success = result { completion?(Data()) }
        }
    }

    func readFirmware() {
        call("readFirmware") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                let major = (value["major"] as? NSNumber)?.intValue ?? 0
                let minor = (value["minor"] as? NSNumber)?.intValue ?? 0
                let sha = value["sha"] as? String ?? ""
                self.firmwareVersion = sha.isEmpty ? "\(major).\(minor)" : "\(major).\(minor) \(sha)"
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func readMSD() {
        isReadingAdvertisement = true
        advertisementError = nil
        call("readMsd") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                guard let hex = value["hex"] as? String, let data = Data(hexString: hex) else {
                    self.advertisementError = "ble-common.js returned invalid advertising data"
                    self.isReadingAdvertisement = false
                    return
                }
                self.publishAdvertisement(data)
            case .failure(let error):
                self.advertisementError = error.localizedDescription
                self.isReadingAdvertisement = false
            }
        }
    }

    func ingestAdvertisement(_ data: Data) {
        publishAdvertisement(data)
    }

    func readConfig() {
        call("readConfig") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                guard let hex = value["hex"] as? String, let bytes = Data(hexString: hex) else {
                    self.lastError = "ble-common.js returned an invalid configuration"
                    return
                }
                do {
                    self.config = try ODConfig.parse(bytes)
                    if let config = self.config {
                        print("[BLE] config display=\(config.displayWidth)x\(config.displayHeight) " +
                              "colorScheme=\(config.colorScheme) transmissionModes=0x\(String(format: "%02X", config.transmissionModes))")
                    }
                    self.reparseAdvertisement()
                } catch {
                    print("[BLE] configuration parsing failed: \(error.localizedDescription)")
                    self.lastError = "Configuration parsing failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func writeConfig(_ model: ODConfigModel, completion: ((Bool) -> Void)? = nil) {
        let data = ODConfig.serialize(model)
        guard !data.isEmpty else {
            lastError = "Could not build Toolbox configuration"
            completion?(false)
            return
        }
        call("writeConfig", arguments: ["hex": data.hexString.replacingOccurrences(of: " ", with: "")]) {
            [weak self] result in
            switch result {
            case .success:
                self?.config = model
                completion?(true)
            case .failure(let error):
                self?.lastError = error.localizedDescription
                completion?(false)
            }
        }
    }

    func reboot() { callIgnoringResult("reboot") }
    func enterDFU() { callIgnoringResult("bootloader") }
    func sendDeepSleep() { sendRaw(ODCommands.deepSleep(), label: "Deep Sleep") }

    // MARK: - Authentication

    func authenticate(psk: Data) {
        guard psk.count == 16 else {
            lastError = "Authentication key must contain exactly 16 bytes"
            return
        }
        call("authenticate", arguments: ["keyHex": psk.hexString.replacingOccurrences(of: " ", with: "")]) {
            [weak self] result in
            switch result {
            case .success: self?.isAuthenticated = true
            case .failure(let error):
                self?.isAuthenticated = false
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Device controls

    func sendLEDPattern(brightness: Int, colors: [LEDColor], repeats: Int) {
        sendRaw(ODCommands.ledPattern(brightness: brightness, colors: colors, repeats: repeats),
                label: "LED Pattern")
    }

    func stopLED() { sendRaw(ODCommands.ledStop(), label: "LED Stop") }

    func sendBuzzerPattern(instance: UInt8 = 0, repeats: Int, steps: [BuzzerStep]) {
        sendRaw(ODCommands.buzzerPattern(instance: instance, repeats: repeats, steps: steps),
                label: "Buzzer Pattern")
    }

    func writeNFC(type: UInt8, payload: Data) {
        let chunkSize = 120
        if payload.count <= chunkSize {
            sendRaw(ODCommands.nfcWriteSingle(type: type, payload: payload), label: "NFC Write")
            return
        }
        sendRaw(ODCommands.nfcWriteStart(type: type, totalLength: UInt16(clamping: payload.count)),
                label: "NFC Write Start")
        for chunk in payload.chunked(size: chunkSize) {
            sendRaw(ODCommands.nfcWriteChunk(chunk), label: "NFC Chunk")
        }
        sendRaw(ODCommands.nfcWriteEnd(), label: "NFC Write End")
    }

    // MARK: - Image upload

    func uploadImage(pixelData: Data, compressed: Bool = true) {
        guard !isUploading else { return }
        if let config {
            let expected = ImageProcessor.expectedPackedByteCount(
                width: config.displayWidth,
                height: config.displayHeight,
                colorScheme: config.colorScheme
            )
            print("[BLE] packed image colorScheme=\(config.colorScheme) bytes=\(pixelData.count) expected=\(expected)")
            guard pixelData.count == expected else {
                lastError = "Packed image has \(pixelData.count) bytes; color scheme \(config.colorScheme) requires \(expected)"
                return
            }
        }
        isUploading = true
        uploadProgress = 0
        let modes = config?.transmissionModes ?? 0

        let arguments: [String: Any] = [
            "rawHex": pixelData.hexString.replacingOccurrences(of: " ", with: ""),
            "compress": compressed,
            "transmissionModes": Int(modes),
            "useFastRefresh": false
        ]
        call("uploadPacked", arguments: arguments) { [weak self] result in
            self?.isUploading = false
            switch result {
            case .success: self?.uploadProgress = 1
            case .failure(let error): self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Runtime results

    private func call(_ operation: String, arguments: [String: Any] = [:],
                      completion: OpenDisplayJSRuntime.Completion? = nil) {
        guard let runtime else {
            let error = OpenDisplayJSRuntime.RuntimeError.transportUnavailable
            lastError = error.localizedDescription
            completion?(.failure(error))
            return
        }
        runtime.call(operation, arguments: arguments, completion: completion)
    }

    private func callIgnoringResult(_ operation: String) {
        call(operation) { [weak self] result in
            if case .failure(let error) = result { self?.lastError = error.localizedDescription }
        }
    }

    private func handleRuntimeEvent(type: String, payload: [String: Any]) {
        switch type {
        case "error":
            lastError = payload["message"] as? String ?? "Unknown ble-common.js error"
        case "log":
            if let message = payload["message"] as? String { print("[ble-common] \(message)") }
        case "uploadProgress":
            let progress = (payload["progress"] as? NSNumber)?.doubleValue ?? 0
            let total = max(1, (payload["total"] as? NSNumber)?.doubleValue ?? 1)
            uploadProgress = min(1, progress / total)
        default:
            break
        }
    }

    private func publishAdvertisement(_ data: Data) {
        do {
            let payload = Data(data.prefix(16))
            let decoded = try ODAdvertisementData.parse(payload, layout: ODAdvertisementLayout(config: config))
            msdData = payload
            msdHex = payload.hexString
            advertisement = decoded
            advertisementError = nil
            isReadingAdvertisement = false
        } catch {
            advertisementError = error.localizedDescription
            isReadingAdvertisement = false
        }
    }

    private func reparseAdvertisement() {
        guard let msdData else { return }
        publishAdvertisement(msdData)
    }

    private func appendLog(direction: LogEntry.Direction, data: Data, label: String?) {
        // Do not publish or print every image-data chunk. At 4-gray resolution this otherwise
        // causes hundreds of main-thread log updates. A Debug launch flag can restore them.
        let isImageChunk = data.count >= 2 && data[1] == 0x71
        guard BLELogging.detailedPayloads || !isImageChunk else { return }
        let entry = LogEntry(direction: direction, data: data, label: label)
        let arrow = direction == .sent ? "→" : "←"
        print("[BLE] \(arrow) \(label ?? "") \(data.hexString)")
        logHandler(entry)
    }

    private func trace(_ message: String) {
        let message = "[\(deviceID.prefix(8))] \(message)"
        print("[BLETrace] \(message)")
        logHandler(LogEntry(direction: .system, data: Data(), label: message))
    }

    private func responseLabel(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let status = data[0] == 0x00 ? "OK" : (data[0] == 0xFF ? "ERR" : nil)
        return status
    }
}
