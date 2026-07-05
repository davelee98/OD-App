import Foundation
import CoreBluetooth
import Combine
import os

/// Observable app-facing device. Core Bluetooth owns the radio; `ble-common.js` owns the protocol.
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
    @Published var configReadProgress: Double = 0
    @Published var lastError: String?

    /// The lifecycle of an image send, driving the Composer's status overlay. This is the single
    /// source of truth — `isUploading` is derived from it, so there is exactly one writer.
    enum UploadPhase: Equatable { case idle, sending, succeeded, failed(String) }

    @Published var uploadPhase: UploadPhase = .idle
    @Published var uploadStatus: String?          // human-readable line forwarded from ble-common.js
    @Published var uploadProgress: Double = 0
    @Published var uploadByteCount: Int?          // packed image payload size, for the terminal summary
    @Published var uploadElapsed: TimeInterval?   // wall-clock duration of the send (set at terminal)
    private var uploadStartTime: Date?            // non-published; captured when the send begins
    var isUploading: Bool { uploadPhase == .sending }

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
    private var configReadWatchdog: DispatchWorkItem?
    private var configWriteWatchdog: DispatchWorkItem?
    private var uploadWatchdog: DispatchWorkItem?
    private var configWriteAckHandler: ((Data) -> Void)?

    init(peripheral: CBPeripheral, initialMSD: Data? = nil,
         logHandler: @escaping (LogEntry) -> Void) {
        self.peripheral = peripheral
        self.transport = CoreBluetoothTransport(peripheral: peripheral)
        self.logHandler = logHandler
        super.init()
        // Keep delegate ownership on the long-lived device object. This is the same lifecycle
        // used by the original native connection path; protocol I/O is still forwarded to the
        // shared transport below.
        peripheral.delegate = self

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
        trace("ODDevice discoverServices; appState=\(connectionState), peripheralState=\(peripheral.state.rawValue), runtimeReady=\(runtime != nil)", level: .info)
        guard runtime != nil else {
            lastError = "ble-common.js runtime is unavailable"
            connectionState = .failed
            return
        }
        transport.start()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        transport.didDiscoverServices(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        transport.didDiscoverCharacteristics(for: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        transport.didUpdateNotificationState(for: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        transport.didUpdateValue(for: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        transport.isReadyToSendWriteWithoutResponse()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        transport.didModifyServices(invalidatedServices)
    }

    func didDisconnect() {
        runtime?.setConnected(false)
        connectionState = .disconnected
        isAuthenticated = false
        if uploadPhase == .sending { failUpload("The display disconnected during upload.") }
        uploadWatchdog?.cancel()
        uploadWatchdog = nil
    }

    private func configureTransport() {
        transport.onReady = { [weak self] in
            guard let self else { return }
            self.trace("GATT ready; changing appState \(self.connectionState) → connected", level: .info)
            self.runtime?.setConnected(true)
            self.connectionState = .connected
            self.readFirmware()
        }
        transport.onNotification = { [weak self] data in
            guard let self else { return }
            self.appendLog(direction: .received, data: data, label: self.responseLabel(data))
            // Every image-chunk ACK triggers a notification; keep this out of the normal trace
            // flood and only surface it under the detailed-payloads debug flag.
            if BLELogging.detailedPayloads {
                self.trace("notification received: \(data.count)B hex=\(data.hexString)")
            }
            self.configWriteAckHandler?(data)
            self.runtime?.receiveNotification(data)
        }
        transport.onError = { [weak self] message in
            self?.trace("transport error; changing appState to failed: \(message)", level: .error)
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

    func sendRaw(_ data: Data, label: String? = nil, completion: ((Result<Void, Error>) -> Void)? = nil) {
        // Trace the labeled send so BLE Tester entries keep their names — the runtime's `onWrite`
        // logs the raw GATT bytes with `label: nil`, so this is the only place the caller's intent
        // is preserved. (A trace, not an appendLog, to avoid double-logging the same packet.)
        trace("sendRaw \(label ?? "raw"): \(data.count)B")
        call("sendHex", arguments: ["hex": data.hexString.replacingOccurrences(of: " ", with: "")]) { [weak self] result in
            switch result {
            case .success:
                completion?(.success(()))
            case .failure(let error):
                // Never silently drop a send failure — surface it like the other command paths do,
                // and always report it back to the caller's completion.
                self?.trace("sendRaw \(label ?? "raw") failed: \(error.localizedDescription)", level: .error)
                self?.lastError = error.localizedDescription
                completion?(.failure(error))
            }
        }
    }

    func readFirmware() {
        trace("readFirmware dispatching to runtime.call")
        call("readFirmware") { [weak self] result in
            guard let self else { return }
            self.trace("readFirmware runtime.call completion invoked")
            switch result {
            case .success(let value):
                let major = (value["major"] as? NSNumber)?.intValue ?? 0
                let minor = (value["minor"] as? NSNumber)?.intValue ?? 0
                self.firmwareVersion = "\(major).\(minor)"
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

    /// - Parameter completion: Called exactly once with the outcome of this specific read —
    ///   success or failure — regardless of whether `lastError`/`config` actually change value
    ///   (an identical error string repeating on a retry, for instance, wouldn't otherwise notify
    ///   an observer watching those `@Published` properties for a *change*).
    func readConfig(completion: ((Result<ODConfigModel, Error>) -> Void)? = nil) {
        trace("readConfig requested; appState=\(connectionState), peripheralState=\(peripheral.state.rawValue)")
        configReadProgress = 0
        var didComplete = false
        let finish: (Result<ODConfigModel, Error>) -> Void = { result in
            guard !didComplete else { return }
            didComplete = true
            completion?(result)
        }
        armConfigReadWatchdog {
            finish(.failure(ODDeviceError("Reading configuration timed out. The device stopped responding.")))
        }
        call("readConfig") { [weak self] result in
            guard let self else { return }
            self.configReadWatchdog?.cancel()
            self.configReadWatchdog = nil
            switch result {
            case .success(let value):
                guard let hex = value["hex"] as? String, let bytes = Data(hexString: hex) else {
                    self.trace("readConfig completed but ble-common.js returned no hex payload; value=\(value)", level: .warning)
                    let message = "ble-common.js returned an invalid configuration"
                    self.lastError = message
                    finish(.failure(ODDeviceError(message)))
                    return
                }
                self.trace("readConfig received \(bytes.count) bytes; decoding")
                do {
                    let model = try ODConfig.parse(bytes)
                    self.config = model
                    self.configReadProgress = 1
                    self.trace("readConfig decoded \(model.toolbox.packets.count) packets; " +
                               "display=\(model.displayWidth)x\(model.displayHeight) " +
                               "colorScheme=\(model.colorScheme) transmissionModes=0x\(String(format: "%02X", model.transmissionModes))")
                    self.reparseAdvertisement()
                    finish(.success(model))
                } catch {
                    self.trace("readConfig decode failed: \(error.localizedDescription); rawHex=\(hex)", level: .error)
                    self.lastError = "Configuration parsing failed: \(error.localizedDescription)"
                    self.configReadProgress = 0
                    finish(.failure(error))
                }
            case .failure(let error):
                self.trace("readConfig failed: \(error.localizedDescription)", level: .error)
                self.lastError = error.localizedDescription
                self.configReadProgress = 0
                finish(.failure(error))
            }
        }
    }

    /// `ble-common.js` has no timeout on the chunked config-read exchange: if the device stops
    /// responding mid-read (or never answers 0x0040 at all), the JS promise never resolves and
    /// the UI is left silently spinning on `configReadProgress` forever. This surfaces that as a
    /// visible, logged failure instead of an indefinite stall.
    private func armConfigReadWatchdog(onTimeout: @escaping () -> Void) {
        configReadWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trace("readConfig STALL WATCHDOG: no response 10s after request; " +
                       "progress=\(self.configReadProgress), appState=\(self.connectionState), " +
                       "peripheralState=\(self.peripheral.state.rawValue)", level: .error)
            self.lastError = "Reading configuration timed out. The device stopped responding."
            self.configReadProgress = 0
            onTimeout()
        }
        configReadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// Same rationale as `readConfig`'s watchdog+completion: `ble-common.js`'s chunked write ACK
    /// handling has no timeout, so a device that stops responding mid-write would otherwise leave
    /// this `completion` never called and no status ever reported — success or failure.
    func writeConfig(_ model: ODConfigModel, completion: ((Bool) -> Void)? = nil) {
        let data: Data
        do {
            data = try ODConfig.serialize(model)
        } catch {
            // Surface the real encode/validation message instead of silently writing 0 bytes.
            lastError = error.localizedDescription
            trace("writeConfig serialize failed: \(error.localizedDescription)", level: .error)
            completion?(false)
            return
        }
        guard !data.isEmpty else {
            lastError = "Could not build Toolbox configuration"
            completion?(false)
            return
        }
        trace("writeConfig requested; \(data.count) bytes; appState=\(connectionState), peripheralState=\(peripheral.state.rawValue)")
        var didComplete = false
        let finish: (Bool) -> Void = { [weak self] succeeded in
            guard !didComplete else { return }
            didComplete = true
            self?.configWriteWatchdog?.cancel()
            self?.configWriteWatchdog = nil
            self?.configWriteAckHandler = nil
            completion?(succeeded)
        }

        // `ble-common.js` only completes a config write when it sees a distinct 0x00/0xCE
        // (success) or 0x00/0xCF (failure) message — this device's firmware never sends one.
        // It only echoes each chunk's own command byte (0x00 0x41 for the first/only chunk,
        // 0x00 0x42 for subsequent ones), so that JS promise never resolves on its own. Detect
        // that ack pattern natively instead, using the same 200-byte chunking ble-common.js uses.
        let chunkSize = 200
        let expectedChunks = max(1, Int((Double(data.count) / Double(chunkSize)).rounded(.up)))
        var chunksAcked = 0
        configWriteAckHandler = { [weak self] notification in
            guard notification.count >= 2 else { return }
            let responseType = notification[notification.startIndex]
            let command = notification[notification.startIndex + 1]
            guard command == 0x41 || command == 0x42 else { return }
            if responseType == 0xFF {
                self?.trace("writeConfig chunk NACK received (command=0x\(String(format: "%02X", command)))", level: .error)
                finish(false)
                return
            }
            guard responseType == 0x00 else { return }
            chunksAcked += 1
            self?.trace("writeConfig chunk ack \(chunksAcked)/\(expectedChunks) (command=0x\(String(format: "%02X", command)))")
            if chunksAcked >= expectedChunks {
                self?.trace("writeConfig complete via final chunk ack")
                self?.config = model
                finish(true)
            }
        }

        armConfigWriteWatchdog {
            finish(false)
        }
        trace("writeConfig dispatching to runtime.call; runtimeReady=\(runtime != nil)")
        call("writeConfig", arguments: ["hex": data.hexString.replacingOccurrences(of: " ", with: "")]) {
            [weak self] result in
            self?.trace("writeConfig runtime.call completion invoked")
            switch result {
            case .success:
                self?.trace("writeConfig succeeded")
                self?.config = model
                finish(true)
            case .failure(let error):
                self?.trace("writeConfig failed: \(error.localizedDescription)", level: .error)
                self?.lastError = error.localizedDescription
                finish(false)
            }
        }
    }

    private func armConfigWriteWatchdog(onTimeout: @escaping () -> Void) {
        configWriteWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trace("writeConfig STALL WATCHDOG: no response 10s after request; " +
                       "appState=\(self.connectionState), peripheralState=\(self.peripheral.state.rawValue)", level: .error)
            self.lastError = "Writing configuration timed out. The device stopped responding."
            onTimeout()
        }
        configWriteWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
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
        guard uploadPhase != .sending else { return }
        if let config {
            let expected = ImageProcessor.expectedPackedByteCount(
                width: config.displayWidth,
                height: config.displayHeight,
                colorScheme: config.colorScheme
            )
            ODLog.imaging.debug("packed image colorScheme=\(config.colorScheme) bytes=\(pixelData.count) expected=\(expected)")
            guard pixelData.count == expected else {
                failUpload("Packed image has \(pixelData.count) bytes; color scheme \(config.colorScheme) requires \(expected)")
                return
            }
        }
        uploadByteCount = pixelData.count
        uploadStartTime = Date()
        uploadElapsed = nil
        uploadStatus = nil
        uploadProgress = 0
        uploadPhase = .sending
        let modes = config?.transmissionModes ?? 0

        let arguments: [String: Any] = [
            "rawHex": pixelData.hexString.replacingOccurrences(of: " ", with: ""),
            "compress": compressed,
            "transmissionModes": Int(modes),
            "useFastRefresh": false
        ]
        armUploadWatchdog()
        call("uploadPacked", arguments: arguments) { [weak self] result in
            guard let self else { return }
            self.uploadWatchdog?.cancel()
            self.uploadWatchdog = nil
            switch result {
            case .success:
                self.uploadProgress = 1
                self.finishUploadTiming()
                self.uploadPhase = .succeeded
            case .failure(let error):
                self.failUpload(error.localizedDescription)
            }
        }
    }

    /// Records the send duration from `uploadStartTime`. Called at every terminal transition so the
    /// elapsed time is available on failures too (the JS success-timing message never fires then).
    private func finishUploadTiming() {
        uploadElapsed = uploadStartTime.map { Date().timeIntervalSince($0) }
        uploadStartTime = nil
    }

    /// Moves the send into the `.failed` state, capturing timing and mirroring the reason to
    /// `lastError` (which other surfaces still read). Also used by the Composer to surface
    /// pre-upload failures (missing config, render error) in the same status overlay.
    func failUpload(_ reason: String) {
        lastError = reason
        finishUploadTiming()
        uploadPhase = .failed(reason)
    }

    /// Dismisses a terminal (`.succeeded`/`.failed`) status back to idle. No-op while sending.
    func acknowledgeUploadOutcome() {
        switch uploadPhase {
        case .succeeded, .failed:
            uploadPhase = .idle
            uploadStatus = nil
            uploadProgress = 0
            uploadElapsed = nil
            uploadByteCount = nil
        case .idle, .sending:
            break
        }
    }

    /// `ble-common.js` streams an image over many chunks with no overall timeout, so a device that
    /// stops responding mid-upload would leave `isUploading` stuck and the progress bar frozen.
    /// Uploads are long-running (hundreds of chunks), so this uses a generous 30s window instead of
    /// the 10s used for config exchanges. The watchdog is re-armed on every `uploadProgress` event
    /// (see `handleRuntimeEvent`) so a slow-but-advancing upload isn't killed; it only fires after
    /// 30s of no forward progress.
    private func armUploadWatchdog() {
        uploadWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trace("uploadImage STALL WATCHDOG: no progress 30s; " +
                       "progress=\(self.uploadProgress), appState=\(self.connectionState), " +
                       "peripheralState=\(self.peripheral.state.rawValue)", level: .error)
            self.uploadProgress = 0
            self.failUpload("Image upload timed out. The display stopped responding.")
        }
        uploadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
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
            let message = payload["message"] as? String ?? "Unknown ble-common.js error"
            // A runtime error mid-send is an upload failure — surface it in the status overlay.
            if uploadPhase == .sending { failUpload(message) } else { lastError = message }
        case "log":
            if let message = payload["message"] as? String { ODLog.proto.debug("\(message, privacy: .public)") }
        case "uploadStatus":
            uploadStatus = payload["message"] as? String
        case "uploadProgress":
            let progress = (payload["progress"] as? NSNumber)?.doubleValue ?? 0
            let total = max(1, (payload["total"] as? NSNumber)?.doubleValue ?? 1)
            uploadProgress = min(1, progress / total)
            // Forward progress resets the stall window so a slow-but-advancing upload isn't killed.
            if uploadPhase == .sending { armUploadWatchdog() }
        case "configProgress":
            let received = (payload["received"] as? NSNumber)?.doubleValue ?? 0
            let total = max(1, (payload["total"] as? NSNumber)?.doubleValue ?? 1)
            configReadProgress = min(1, received / total)
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
        ODLog.ble.debug("\(arrow, privacy: .public) \(label ?? "", privacy: .public) \(data.hexString, privacy: .public)")
        logHandler(entry)
    }

    private func trace(_ message: String, level: OSLogType = .debug) {
        let message = "[\(deviceID.prefix(8))] \(message)"
        ODLog.ble.log(level: level, "\(message, privacy: .public)")
        logHandler(LogEntry(direction: .system, data: Data(), label: message))
    }

    private func responseLabel(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let status = data[0] == 0x00 ? "OK" : (data[0] == 0xFF ? "ERR" : nil)
        return status
    }
}

struct ODDeviceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
