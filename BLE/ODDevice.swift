import Foundation
import CoreBluetooth
import Combine
import os
import ODProtocolKit

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
    @Published var configReadState: ConfigReadState = .unread
    @Published var lastError: String?

    /// Lifecycle of the panel's configuration read, so views can distinguish "still fetching",
    /// "read from hardware", and "read failed" instead of treating a nil `config` as all three.
    /// A loaded `config` alongside `.reading` means a cached value is being refreshed on reconnect.
    ///
    /// `.authRequired` is its own case rather than a flavour of `.failed` because it is the one
    /// outcome with a user-actionable remedy (enter the key). Views branch on this; they must never
    /// pattern-match error strings to detect it.
    enum ConfigReadState: Equatable { case unread, reading, loaded, authRequired, failed(String) }

    /// Where the 0x50 handshake stands. Replaces a loose `isAuthenticating` bool plus an error
    /// string, because rate limiting has to be a *state the UI can gate on* rather than a message.
    enum AuthPhase: Equatable {
        case idle
        case authenticating
        case authenticated
        case failed(ODAuthFailureReason)
        /// A conservative client-side backoff. The wire carries only status 0x04 — there is no
        /// retry-after value or reset timestamp — so this deadline is ours, not the device's, and
        /// may wait longer than the rolling window strictly needs.
        case rateLimited(retryNotBefore: Date)
    }

    /// The lifecycle of an image send, driving the Composer's status overlay. This is the single
    /// source of truth — `isUploading` is derived from it, so there is exactly one writer.
    enum UploadPhase: Equatable { case idle, preparing, sending, succeeded, failed(String) }

    @Published var uploadPhase: UploadPhase = .idle {
        didSet {
            // Emit the quiet image-write summary once the stream ends (success, failure, or drop).
            if oldValue == .sending, uploadPhase != .sending { finishImageWriteMeter() }
        }
    }
    @Published var uploadStatus: String?          // human-readable line forwarded from ble-common.js
    @Published var uploadProgress: Double = 0
    @Published var uploadByteCount: Int?          // packed image payload size, for the terminal summary
    @Published var uploadElapsed: TimeInterval?   // wall-clock duration of the send (set at terminal)
    private var uploadStartTime: Date?            // non-published; captured when the send begins
    var isUploading: Bool { uploadPhase == .sending || uploadPhase == .preparing }

    var name: String { peripheral.name ?? peripheral.identifier.uuidString }
    var deviceID: String { peripheral.identifier.uuidString }

    /// In-memory mirror of the Keychain entry, seeded in `init`. The Keychain remains the only
    /// durable store — the key is deliberately never written into the SwiftData file — but reads go
    /// through this so SwiftUI body evaluations don't each pay a synchronous Keychain round-trip.
    private var cachedPSK: Data?

    /// Published so views re-render when a key is stored or forgotten; `psk` itself can't be
    /// `@Published` because it's a computed write-through property.
    @Published private(set) var hasStoredKey = false

    /// True once we know this display refuses unauthenticated traffic — learned from a `..FE` reply
    /// or a completed handshake, or seeded from `SavedDisplayEntity.requiresAuthentication` before
    /// we have ever talked to it.
    @Published var requiresAuthentication = false

    @Published private(set) var authPhase: AuthPhase = .idle

    var psk: Data? {
        get { cachedPSK }
        set {
            cachedPSK = newValue
            if let key = newValue { ODAuth.savePSK(key, forDevice: deviceID) }
            else { ODAuth.deletePSK(forDevice: deviceID) }
            hasStoredKey = newValue != nil
        }
    }

    var batteryPercent: Int? { advertisement?.bq27220?.percent }
    var isCharging: Bool { advertisement?.bq27220?.isCharging ?? false }

    private let transport: CoreBluetoothTransport
    private let logHandler: (LogEntry) -> Void
    private var runtime: OpenDisplayJSRuntime?

    // Native wire-protocol client (ODProtocolKit). Phase 1: drives the direct-write image upload,
    // replacing the JS `uploadPacked` path (unless `-ODUseJSUpload` is set). Lazy so it and its link
    // are only created when first used.
    // The kit is @MainActor; the BLE stack is main-confined (CoreBluetooth `queue: .main`), so
    // `assumeIsolated` at these interop points is safe. Lazy so they exist only when first used.
    private lazy var nativeLink: CoreBluetoothLink =
        MainActor.assumeIsolated { CoreBluetoothLink(transport: self.transport) }
    private lazy var protocolClient: ODProtocolClient = MainActor.assumeIsolated {
        let client = ODProtocolClient(link: self.nativeLink)
        client.onWireTraffic = { [weak self] direction, data in
            // Log native SENT frames for BLE-log parity; RECEIVED are already logged in the
            // transport fan-out below (0x71 chunk floods are suppressed there during a send).
            guard direction == .sent else { return }
            self?.appendLog(direction: .sent, data: data, label: nil)
        }
        client.onEvent = { [weak self] event in
            switch event {
            case .refreshCompleted: self?.trace("panel refresh complete (0x73)")
            case .refreshTimedOut:  self?.trace("panel refresh timed out (0x74)", level: .error)
            case .log(let message): self?.trace(message)
            }
        }
        return client
    }
    private var uploadTask: Task<Void, Never>?

    /// Quiet image-write logging (mirrors the firmware's `imageWriteLogQuiet*`): an upload streams
    /// hundreds of 0x71/0x81 data frames + acks, so instead of one log line each we emit the first
    /// frame in full, a 5%-step progress meter, and a one-line summary at completion.
    private struct ImageWriteLog {
        var startTime: Date?
        var frames = 0
        var lastStep = -1      // last 5% step emitted (pct / 5)
        var firstLogged = false
    }
    private var imageWriteLog = ImageWriteLog()

    /// Native ODProtocolKit paths (upload, config read/write, firmware/MSD, commands) are used unless
    /// `-ODUseJSUpload` forces the legacy ble-common.js route (bring-up safety net).
    private var useNativeProtocol: Bool { !ProcessInfo.processInfo.arguments.contains("-ODUseJSUpload") }
    private var msdData: Data?
    private var configReadWatchdog: DispatchWorkItem?
    private var configWriteWatchdog: DispatchWorkItem?
    private var uploadWatchdog: DispatchWorkItem?
    private var firmwareWatchdog: DispatchWorkItem?
    private var msdWatchdog: DispatchWorkItem?
    private var authWatchdog: DispatchWorkItem?
    private var configWriteAckHandler: ((Data) -> Void)?
    // The ack handler and watchdogs above are single shared slots: two overlapping config
    // operations would clobber each other's, leaving the loser to complete only via timeout.
    // A read-in-flight is tracked by `configReadState == .reading`; the write flag rejects an
    // overlapping writer outright.
    private var isConfigWriteInFlight = false
    // Every completion waiting on the current read (the auto-read on connect plus any view that
    // asks while it's still in flight), fired together with the shared result.
    private var configReadCompletions: [(Result<ODConfigModel, Error>) -> Void] = []
    // The terminal handler for the in-flight read, so the watchdog and a mid-read disconnect can
    // finish it without reaching into `readConfig`'s local scope.
    private var configReadFinish: ((Result<ODConfigModel, Error>) -> Void)?

    /// Identifies a real link incarnation. Bumped in exactly one place — `didDisconnect()`.
    ///
    /// "On connect" would be ambiguous: `BLEManager.didConnect` runs before GATT readiness, and this
    /// object only learns of readiness through `transport.onReady`, which can fire more than once
    /// per link. Bumping on teardown alone is unambiguous and sufficient — operations from link N
    /// hold generation G, the drop moves it to G+1, and everything afterwards (the reconnect
    /// included) is G+1 — with no fictitious generations along the way.
    ///
    /// This matters because `BLEManager` reuses the same `ODDevice` across reconnects, so a late
    /// completion from a previous link must never publish state or persist a key.
    private var connectionGeneration: UInt64 = 0

    /// Identifies one config read. Async producers (native progress, the JS completion, the
    /// `configProgress` event, a superseding write) capture the token live when they start and must
    /// verify it before touching any shared read state — `configReadFinish`, `configReadWatchdog`,
    /// `configReadProgress`, `config`, `configReadState`, `configReadCompletions`, `lastError`.
    private var configReadToken: UInt64 = 0
    private var nextConfigReadToken: UInt64 = 0

    /// The key the in-flight handshake is using, so a second caller with the *same* key can join and
    /// one with a *different* key is rejected rather than told someone else's attempt was its own.
    private var inFlightKey: Data?
    /// Completions waiting on the in-flight handshake. Owned by exactly one attempt at a time —
    /// see `authAttemptToken`.
    private var authCompletions: [(Result<Void, Error>) -> Void] = []
    /// Identifies one handshake attempt, so a late completion can tell "I still own the waiter list"
    /// from "this list now belongs to a newer attempt". Without it, a task from a retired link would
    /// drain the *next* connection's callbacks with its own stale result — telling a caller its key
    /// succeeded (or failed) when that verdict belonged to a different attempt entirely.
    private var authAttemptToken: UInt64 = 0
    private var nextAuthAttemptToken: UInt64 = 0

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

        // Seed the PSK cache once, here, rather than on every `psk` read. A stored key is also the
        // signal that this display is locked, so the connect path can authenticate before its first
        // config read instead of discovering `00 40 FE` the hard way.
        cachedPSK = ODAuth.loadPSK(forDevice: peripheral.identifier.uuidString)
        hasStoredKey = cachedPSK != nil
        requiresAuthentication = cachedPSK != nil

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
        // Retire this link incarnation first, so anything that lands after this point — a late JS
        // completion, a native task unwinding, a queued runtime event — fails its generation check
        // and can neither publish state nor persist a key against the next connection.
        connectionGeneration &+= 1
        // Retire the handshake attempt too, so a task still unwinding from the old link can't match
        // and drain the next connection's waiters below.
        nextAuthAttemptToken &+= 1
        authAttemptToken = nextAuthAttemptToken
        runtime?.setConnected(false)
        connectionState = .disconnected
        isAuthenticated = false
        authPhase = .idle
        inFlightKey = nil
        if uploadPhase == .sending { failUpload("The display disconnected during upload.") }
        uploadTask?.cancel(); uploadTask = nil
        MainActor.assumeIsolated { self.nativeLink.linkDropped(nil) }   // fail any pending native upload
        // A disconnect orphans every in-flight operation: cancel all stall watchdogs so none
        // fires seconds later over stale state, drop the chunk-ack handler, and clear the
        // in-flight flags so the next connection starts fresh. (`setConnected(false)` above
        // lets the JS runtime reject its pending calls through the normal completions.)
        uploadWatchdog?.cancel();      uploadWatchdog = nil
        configReadWatchdog?.cancel();  configReadWatchdog = nil
        configWriteWatchdog?.cancel(); configWriteWatchdog = nil
        firmwareWatchdog?.cancel();    firmwareWatchdog = nil
        msdWatchdog?.cancel();         msdWatchdog = nil
        authWatchdog?.cancel();        authWatchdog = nil
        configWriteAckHandler = nil
        // Drain any read that was still in flight with a definitive failure so its waiters (and the
        // config-read state) don't hang; `setConnected(false)` above may also reject it, but the
        // `didComplete` guard makes whichever loses the race a no-op.
        //
        // Capture and clear the owned slot *before* invoking it. A waiter can synchronously start a
        // new read from its completion, and an unconditional `configReadFinish = nil` afterwards
        // would then clear the *new* read's terminal handler, stranding it.
        let drainedRead = configReadFinish
        configReadFinish = nil
        if configReadState == .reading {
            drainedRead?(.failure(ODDeviceError("The display disconnected before the configuration was read.")))
        }
        // Same reasoning for auth waiters: take the list, clear it, then notify.
        let drainedAuth = authCompletions
        authCompletions.removeAll()
        drainedAuth.forEach { $0(.failure(ODDeviceError("The display disconnected during authentication."))) }
        isConfigWriteInFlight = false
    }

    /// The connect-time sequence: authenticate (when we already hold a key) before reading config.
    ///
    /// A locked display answers an unauthenticated `0x0040` with `00 40 FE`, so a stored key means
    /// we must handshake *first* rather than spend a round-trip learning that. Every step is chained
    /// through completions: `withExclusiveOp` rejects overlap rather than queuing it, so firing
    /// these together would make the later ones throw `.busy`.
    private func beginPostConnectHandshake() {
        let readThenFirmware: () -> Void = { [weak self] in
            self?.readConfig { [weak self] _ in self?.readFirmware() }
        }
        guard let key = cachedPSK else { readThenFirmware(); return }
        if let remaining = authCooldownRemaining {
            trace("skipping auto-authenticate: rate-limit backoff has \(Int(remaining))s left", level: .warning)
            readThenFirmware()
            return
        }
        trace("stored key present; authenticating before the config read", level: .info)
        authenticate(psk: key) { [weak self] result in
            if case .failure(let error) = result {
                // Never strand the connection on a failed handshake. An unlocked display answers the
                // read normally, and a locked one answers `00 40 FE`, which is what drives the
                // key-entry UI — so proceeding is strictly more informative than stopping here.
                self?.trace("auto-authenticate failed, continuing to the config read: \(error.localizedDescription)",
                            level: .warning)
            }
            readThenFirmware()
        }
    }

    private func configureTransport() {
        transport.onReady = { [weak self] in
            guard let self else { return }
            self.trace("GATT ready; changing appState \(self.connectionState) → connected", level: .info)
            self.runtime?.setConnected(true)
            self.connectionState = .connected
            // Auto-read config from the point the GATT link is actually usable — not from a view's
            // onChange, which fires while `didConnect` still has the link in `.connecting` and the JS
            // engine rejects the read with "Not connected". Every surface (Add sheet, Composer,
            // Toolbox) gets the result for free; a cached value is refreshed on each reconnect.
            //
            // Sequence config → firmware: both route through the native client's single-operation
            // gate, so firing them back-to-back made the second throw `.busy` (the firmware read held
            // the gate while it awaited its round-trip, so the config read was rejected and `config`
            // stayed nil until a surface re-triggered it). Config is the critical path (it gates the
            // Composer/Add/Toolbox), so read it first, then read the cosmetic firmware version once
            // the gate frees. The firmware read runs on both success and failure of the config read.
            self.beginPostConnectHandshake()
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
            MainActor.assumeIsolated { self.nativeLink.deliver(data) }
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
                // A successful send proves the link is working now, so clear any stale `lastError`.
                // Both the Tester and BLE Log banners read this same property, so heal them here
                // rather than letting one past failure pin a red banner for the rest of the session.
                self?.lastError = nil
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

    /// Shared scaffolding for the per-operation stall watchdogs. `ble-common.js` has no timeout
    /// on any notification-driven exchange, so every native operation that waits on the device
    /// arms one of these; without it, a device that goes quiet leaves the operation hanging
    /// forever with no error. Runs on the main queue like all other BLE work.
    private func makeWatchdog(operation: String, timeout: TimeInterval = 10,
                              onTimeout: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trace("\(operation) STALL WATCHDOG: no response \(Int(timeout))s after request; " +
                       "appState=\(self.connectionState), peripheralState=\(self.peripheral.state.rawValue)",
                       level: .error)
            onTimeout()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        return work
    }

    func readFirmware() {
        if useNativeProtocol {
            firmwareWatchdog?.cancel(); firmwareWatchdog = nil   // native client owns the timeout
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let (major, minor, _) = try await self.protocolClient.firmwareVersion()
                    self.firmwareVersion = "\(major).\(minor)"
                } catch { self.lastError = error.localizedDescription }
            }
            return
        }
        trace("readFirmware dispatching to runtime.call")
        var didComplete = false
        firmwareWatchdog?.cancel()
        firmwareWatchdog = makeWatchdog(operation: "readFirmware") { [weak self] in
            guard !didComplete else { return }
            didComplete = true
            self?.lastError = "Reading the firmware version timed out. The device did not respond."
        }
        call("readFirmware") { [weak self] result in
            guard let self else { return }
            self.trace("readFirmware runtime.call completion invoked")
            self.firmwareWatchdog?.cancel()
            self.firmwareWatchdog = nil
            guard !didComplete else { return }
            didComplete = true
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
        if useNativeProtocol {
            msdWatchdog?.cancel(); msdWatchdog = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let msd = try await self.protocolClient.readMSD()
                    self.publishAdvertisement(msd)
                } catch {
                    self.advertisementError = error.localizedDescription
                    self.isReadingAdvertisement = false
                }
            }
            return
        }
        var didComplete = false
        msdWatchdog?.cancel()
        msdWatchdog = makeWatchdog(operation: "readMSD") { [weak self] in
            guard !didComplete else { return }
            didComplete = true
            // Un-sticks the advertisement spinner, which otherwise waits on this forever.
            self?.advertisementError = "Reading advertising data timed out. The device did not respond."
            self?.isReadingAdvertisement = false
        }
        call("readMsd") { [weak self] result in
            guard let self else { return }
            self.msdWatchdog?.cancel()
            self.msdWatchdog = nil
            guard !didComplete else { return }
            didComplete = true
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
        if configReadState == .reading {
            // A read is already in flight (typically the auto-read kicked off on connect). Ride
            // along with it instead of rejecting, so this caller's completion still fires with the
            // shared result rather than a spurious "already in progress" error.
            trace("readConfig joining the in-flight read", level: .info)
            if let completion { configReadCompletions.append(completion) }
            return
        }
        configReadState = .reading
        configReadProgress = 0
        if let completion { configReadCompletions.append(completion) }
        // Identity for this read. Async producers below capture it and must prove ownership before
        // touching shared state — `didComplete` alone is too late, because it only guards the
        // *result*, not the watchdog/progress mutations that run ahead of it.
        nextConfigReadToken &+= 1
        let token = nextConfigReadToken
        configReadToken = token
        let generation = connectionGeneration
        var didComplete = false
        let finish: (Result<ODConfigModel, Error>) -> Void = { [weak self] result in
            guard let self, !didComplete else { return }
            didComplete = true
            self.configReadWatchdog?.cancel()
            self.configReadWatchdog = nil
            self.configReadFinish = nil
            switch result {
            case .success:
                self.configReadState = .loaded
            case .failure(let error):
                // A locked display answers `00 40 FE`. That is the one failure with a remedy the
                // user can act on, so it gets its own state rather than an opaque `.failed` string.
                if Self.isAuthRequired(error) {
                    self.configReadState = .authRequired
                    self.requiresAuthentication = true
                    self.isAuthenticated = false
                } else {
                    self.configReadState = .failed(error.localizedDescription)
                }
            }
            let waiters = self.configReadCompletions
            self.configReadCompletions.removeAll()
            waiters.forEach { $0(result) }
        }
        configReadFinish = finish
        /// True while this read still owns the shared slots. Everything below checks it before any
        /// mutation, at callback entry — a field-by-field check would miss `lastError` and
        /// `reparseAdvertisement()`'s side effects.
        let ownsRead: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.configReadToken == token && self.connectionGeneration == generation
        }
        if useNativeProtocol {
            // Native transport only: the raw blob still goes to ODConfig.parse (toolbox engine).
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let bytes = try await self.protocolClient.readConfigBlob { progress in
                        guard ownsRead() else { return }
                        self.configReadProgress = progress
                    }
                    guard ownsRead(), !didComplete else { return }
                    let model = try ODConfig.parse(bytes)
                    self.config = model
                    self.configReadProgress = 1
                    self.trace("readConfig (native) decoded \(model.toolbox.packets.count) packets; " +
                               "display=\(model.displayWidth)x\(model.displayHeight) colorScheme=\(model.colorScheme)")
                    self.reparseAdvertisement()
                    finish(.success(model))
                } catch {
                    guard ownsRead(), !didComplete else { return }
                    // The dedicated key-entry UI covers `.authRequired`, so don't also pin a red
                    // banner for it — that reads as a fault rather than a prompt.
                    if !Self.isAuthRequired(error) {
                        self.lastError = "Configuration read failed: \(error.localizedDescription)"
                    }
                    self.configReadProgress = 0
                    finish(.failure(error))
                }
            }
            return
        }
        armConfigReadWatchdog()
        // `readToken` comes back on every `configProgress` event so a superseded read's queued
        // events can be told apart from the live one's (see `handleRuntimeEvent`).
        call("readConfig", arguments: ["readToken": NSNumber(value: token)]) { [weak self] result in
            guard let self else { return }
            // Ownership first. This handler used to cancel and clear `configReadWatchdog` *before*
            // checking whether its read was still current, so a stale resolution stripped the
            // successor read's stall timeout and left it running unguarded.
            guard ownsRead() else {
                self.trace("readConfig JS resolved for a superseded read; ignoring", level: .info)
                return
            }
            self.configReadWatchdog?.cancel()
            self.configReadWatchdog = nil
            // The read may already have been settled out from under this JS resolution — by the
            // stall watchdog, a mid-read disconnect, or a config write that superseded it (see
            // `writeConfig`). If so, don't let a late (and now stale, pre-write) result overwrite
            // `config`/state; `finish` has already flipped the state and drained the waiters.
            guard !didComplete else {
                self.trace("readConfig JS resolved after the read was already settled; ignoring", level: .info)
                return
            }
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
                if !Self.isAuthRequired(error) { self.lastError = error.localizedDescription }
                self.configReadProgress = 0
                finish(.failure(error))
            }
        }
    }

    /// Does this error mean "the display refused unauthenticated traffic"?
    ///
    /// The native path throws `ODProtocolError.authRequired` outright. The JS fallback can't: the
    /// SHA-pinned `ble-common.js` rejects with a plain `Error('Authentication required (0xFE)')`,
    /// which arrives as an opaque `RuntimeError.operationFailed`. This is the **single** place that
    /// string is matched — everything downstream branches on `ConfigReadState.authRequired`, never
    /// on message text.
    static func isAuthRequired(_ error: Error) -> Bool {
        if case ODProtocolError.authRequired = error { return true }
        guard case OpenDisplayJSRuntime.RuntimeError.operationFailed(let message) = error else { return false }
        return message.contains("0xFE") || message.localizedCaseInsensitiveContains("authentication required")
    }

    /// `ble-common.js` has no timeout on the chunked config-read exchange: if the device stops
    /// responding mid-read (or never answers 0x0040 at all), the JS promise never resolves and
    /// the UI is left silently spinning on `configReadProgress` forever. This surfaces that as a
    /// visible, logged failure instead of an indefinite stall.
    /// Re-armed on every `configProgress` event (see `handleRuntimeEvent`) so a chunked read that is
    /// making steady progress but running long isn't declared stalled — the window only ever needs to
    /// cover a gap between chunks, mirroring the upload watchdog. Fires the shared `configReadFinish`
    /// so the timeout also flips `configReadState` to `.failed` and notifies every waiter.
    private func armConfigReadWatchdog() {
        configReadWatchdog?.cancel()
        configReadWatchdog = makeWatchdog(operation: "readConfig") { [weak self] in
            guard let self else { return }
            let message = "Reading configuration timed out. The device stopped responding."
            self.lastError = message
            self.configReadProgress = 0
            self.configReadFinish?(.failure(ODDeviceError(message)))
        }
    }

    /// Same rationale as `readConfig`'s watchdog+completion: `ble-common.js`'s chunked write ACK
    /// handling has no timeout, so a device that stops responding mid-write would otherwise leave
    /// this `completion` never called and no status ever reported — success or failure.
    func writeConfig(_ model: ODConfigModel, completion: ((Bool) -> Void)? = nil) {
        guard !isConfigWriteInFlight else {
            trace("writeConfig rejected: a configuration write is already in progress", level: .warning)
            lastError = "A configuration write is already in progress"
            completion?(false)
            return
        }
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
        isConfigWriteInFlight = true
        // Capture, at start, the exact read this write is entitled to supersede — and the link it
        // belongs to. Checking only `configReadState == .reading` at completion time would let a
        // write that outlived a disconnect settle a *different*, later read with a stale model.
        // A token of 0 means no read was in flight when the write began, so it may never supersede.
        let supersedableRead = (configReadState == .reading) ? configReadToken : 0
        let writeGeneration = connectionGeneration
        var didComplete = false
        let finish: (Bool) -> Void = { [weak self] succeeded in
            guard !didComplete else { return }
            didComplete = true
            self?.configWriteWatchdog?.cancel()
            self?.configWriteWatchdog = nil
            self?.configWriteAckHandler = nil
            self?.isConfigWriteInFlight = false
            // A successful write is the new on-device truth. PR #19 fires an auto-read on every
            // connect, so in the Toolbox connect-then-write flow that read is often still in flight
            // here — settle it against the model we just wrote (state → .loaded, waiters get the
            // written config) instead of letting its stale pre-write result land afterwards and flip
            // `config` back. `config` is already set to `model` on the ack/JS paths below; the late
            // read resolution is then ignored via readConfig's `didComplete` guard.
            if succeeded, let self,
               supersedableRead != 0,
               self.connectionGeneration == writeGeneration,
               self.configReadToken == supersedableRead,
               self.configReadState == .reading {
                self.trace("writeConfig superseding the in-flight config read with the written model", level: .info)
                self.configReadFinish?(.success(model))
            }
            completion?(succeeded)
        }

        if useNativeProtocol {
            // Native chunked write (0x41/0x42 with per-chunk ACK); the client owns the timeout, so
            // the ACK-counter workaround + watchdog below are skipped.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.protocolClient.writeConfigBlob(data)
                    self.config = model
                    finish(true)
                } catch {
                    self.lastError = error.localizedDescription
                    self.trace("writeConfig (native) failed: \(error.localizedDescription)", level: .error)
                    finish(false)
                }
            }
            return
        }

        // `ble-common.js` only completes a config write when it sees a distinct 0x00/0xCE
        // (success) or 0x00/0xCF (failure) message — this device's firmware never sends one.
        // It only echoes each chunk's own command byte (0x00 0x41 for the first/only chunk,
        // 0x00 0x42 for subsequent ones), so that JS promise never resolves on its own. Detect
        // that ack pattern natively instead, using the same 200-byte chunking ble-common.js uses.
        let chunkSize = OD.configWriteChunkSize
        let expectedChunks = max(1, Int((Double(data.count) / Double(chunkSize)).rounded(.up)))
        var chunksAcked = 0
        configWriteAckHandler = { [weak self] notification in
            guard notification.count >= 2 else { return }
            let responseType = notification[notification.startIndex]
            let command = notification[notification.startIndex + 1]
            guard command == RESP_CONFIG_WRITE || command == RESP_CONFIG_CHUNK else { return }
            if responseType == RESP_NACK {
                self?.trace("writeConfig chunk NACK received (command=0x\(String(format: "%02X", command)))", level: .error)
                finish(false)
                return
            }
            guard responseType == RESP_ACK else { return }
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
        configWriteWatchdog = makeWatchdog(operation: "writeConfig") { [weak self] in
            guard let self else { return }
            self.lastError = "Writing configuration timed out. The device stopped responding."
            onTimeout()
        }
    }

    func reboot() {
        if useNativeProtocol { Task { @MainActor [weak self] in try? await self?.protocolClient.send(.reboot) }; return }
        callIgnoringResult("reboot")
    }
    func enterDFU() {
        if useNativeProtocol { Task { @MainActor [weak self] in try? await self?.protocolClient.send(.enterDFU) }; return }
        callIgnoringResult("bootloader")
    }
    func sendDeepSleep() {
        if useNativeProtocol { Task { @MainActor [weak self] in try? await self?.protocolClient.send(.deepSleep(seconds: nil)) }; return }
        sendRaw(ODCommands.deepSleep(), label: "Deep Sleep")
    }

    // MARK: - Authentication

    /// True while the 0x50 handshake owns the protocol client. `ODProtocolClient.withExclusiveOp`
    /// *rejects* overlap rather than queuing it, so anything started now would draw `.busy`.
    var isBusyWithHandshake: Bool { authPhase == .authenticating }

    /// Still inside the device's rate-limit backoff, if any.
    var authCooldownRemaining: TimeInterval? {
        guard case .rateLimited(let retryNotBefore) = authPhase else { return nil }
        let remaining = retryNotBefore.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    /// Our own backoff after the device reports rate limiting. The wire carries no retry-after
    /// value, and the documented window is ">=10 attempts per 60s", so a full minute is the
    /// conservative choice — it may wait longer than strictly necessary.
    private static let rateLimitBackoff: TimeInterval = 60

    /// Run the 0x50 handshake.
    ///
    /// - Parameter completion: called exactly once with this attempt's outcome. A caller offering
    ///   the *same* key as the attempt in flight joins it; a caller offering a *different* key is
    ///   rejected rather than joined, because reporting someone else's result as its own would let
    ///   it persist an unvalidated key.
    ///
    /// Does **not** persist the key on success — that is `unlock(psk:)`'s job, and only after the
    /// handshake proves it.
    func authenticate(psk: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard psk.count == 16 else {
            let error = ODDeviceError("Authentication key must contain exactly 16 bytes")
            lastError = error.localizedDescription
            completion?(.failure(error))
            return
        }
        if let remaining = authCooldownRemaining {
            let error = ODDeviceError("Too many attempts. Try again in \(Int(remaining.rounded(.up))) seconds.")
            lastError = error.localizedDescription
            completion?(.failure(error))
            return
        }
        if let inFlight = inFlightKey {
            guard Self.constantTimeEqual(inFlight, psk) else {
                // Never join across different credentials: if the in-flight attempt succeeded, this
                // caller would be told *its* key worked and would go on to store it.
                let error = ODDeviceError("A different key is already being tried. Wait for it to finish.")
                completion?(.failure(error))
                return
            }
            trace("authenticate joining the in-flight handshake for the same key", level: .info)
            if let completion { authCompletions.append(completion) }
            return
        }

        inFlightKey = psk
        authPhase = .authenticating
        if let completion { authCompletions.append(completion) }
        let generation = connectionGeneration
        nextAuthAttemptToken &+= 1
        let attempt = nextAuthAttemptToken
        authAttemptToken = attempt
        var didComplete = false

        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, !didComplete else { return }
            didComplete = true
            // Only touch the waiter list while this attempt still owns it. A completion from a
            // retired link must publish nothing, persist nothing, and — critically — must NOT drain
            // callbacks that now belong to a newer attempt with a verdict from the old one. Its own
            // waiters were already drained by `didDisconnect`, so there is nothing left to notify.
            guard self.authAttemptToken == attempt, self.connectionGeneration == generation else {
                self.trace("ignoring an authenticate completion from a superseded attempt", level: .info)
                return
            }
            self.authWatchdog?.cancel()
            self.authWatchdog = nil
            self.inFlightKey = nil
            switch result {
            case .success:
                self.isAuthenticated = true
                self.requiresAuthentication = true
                self.authPhase = .authenticated
                self.lastError = nil
            case .failure(let error):
                self.isAuthenticated = false
                if case ODProtocolError.authFailed(let reason) = error {
                    switch reason {
                    case .notConfigured:
                        // The display has no encryption at all, so a stored key is stale. Drop it,
                        // or `beginPostConnectHandshake` burns a pointless handshake every connect.
                        // NOT `.authenticated` — the unauthenticated read that follows proves access.
                        self.psk = nil
                        self.requiresAuthentication = false
                        self.authPhase = .idle
                    case .rateLimited:
                        // Keep the key: retrying is what caused this.
                        self.requiresAuthentication = true
                        self.authPhase = .rateLimited(retryNotBefore: Date().addingTimeInterval(Self.rateLimitBackoff))
                        self.lastError = error.localizedDescription
                    default:
                        self.requiresAuthentication = true
                        self.authPhase = .failed(reason)
                        self.lastError = error.localizedDescription
                    }
                } else {
                    self.authPhase = .idle
                    self.lastError = error.localizedDescription
                }
                self.trace("authenticate failed: \(error.localizedDescription)", level: .error)
            }
            // Clear owned state before notifying: a completion may synchronously call `unlock` again.
            let waiters = self.authCompletions
            self.authCompletions.removeAll()
            waiters.forEach { $0(result) }
        }

        if useNativeProtocol {
            // Native 0x50 handshake; on success the client transparently CCM-wraps all subsequent
            // traffic (config/upload/commands already route through it).
            //
            // Deliberately no outer watchdog here. The package owns two 10s stage timeouts, and a
            // `DispatchWorkItem` could not cancel this task or release `withExclusiveOp`'s gate — it
            // would report failure to the UI while the handshake ran on and later established a
            // session the UI believes failed. A real disconnect unwinds it via `failPending`.
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.protocolClient.authenticate(masterKey: psk)
                    // The secure channel is the authority; `isAuthenticated` is only its mirror.
                    guard self.protocolClient.isSessionEstablished else {
                        finish(.failure(ODProtocolError.authFailed(.proofMismatch)))
                        return
                    }
                    finish(.success(()))
                } catch {
                    finish(.failure(error))
                }
            }
            return
        }

        // The JS path has no internal timeout, so it keeps its watchdog.
        authWatchdog?.cancel()
        authWatchdog = makeWatchdog(operation: "authenticate") {
            finish(.failure(ODDeviceError("Authentication timed out. The display did not respond.")))
        }
        call("authenticate", arguments: ["keyHex": psk.hexString.replacingOccurrences(of: " ", with: "")]) { result in
            finish(result.map { _ in () })
        }
    }

    /// Authenticate and, only once the handshake proves the key, persist it and re-run the config
    /// read the locked display refused. **The only place a PSK is written to the Keychain.**
    func unlock(psk key: Data, completion: ((Result<Void, Error>) -> Void)? = nil) {
        authenticate(psk: key) { [weak self] result in
            guard let self else { completion?(result); return }
            switch result {
            case .success:
                let saved = ODAuth.savePSK(key, forDevice: self.deviceID)
                if saved {
                    self.cachedPSK = key
                    self.hasStoredKey = true
                } else {
                    self.trace("unlock: Keychain save failed", level: .error)
                }
                // The session is authenticated either way, so load the config that `00 40 FE`
                // rejected — the read is what unblocks Save, and it doesn't depend on persistence.
                self.readConfig { _ in }
                guard saved else {
                    // Report failure so the key-entry UI stays open with the key still in the field.
                    // Returning success here cleared the field and dismissed the sheet, and then the
                    // next connect prompted again — looking to the user like the unlock never took.
                    let error = ODDeviceError("Unlocked, but the key could not be saved. "
                                              + "You'll be asked for it again next time.")
                    self.lastError = error.localizedDescription
                    completion?(.failure(error))
                    return
                }
                completion?(.success(()))
            case .failure(let error):
                // Only an explicit AUTH_STATUS_FAILED condemns the key. `.proofMismatch` fires after
                // the device accepted our proof, so it implicates the response or the peer, not the
                // credential. And only forget the key this attempt actually used, so a slow failure
                // can't wipe a newer key another caller just stored.
                if case ODProtocolError.authFailed(.wrongKey) = error,
                   let stored = self.cachedPSK, Self.constantTimeEqual(stored, key) {
                    self.psk = nil
                    self.trace("unlock: forgetting the stored key the device rejected", level: .info)
                }
                completion?(.failure(error))
            }
        }
    }

    /// Length-independent, early-exit-free comparison, so key handling never leaks timing.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: - Image upload

    /// Show the send overlay the instant Send is tapped, before the (possibly slow) full-resolution
    /// render + dithering pass. The composer does that work off the main thread and then calls
    /// `uploadImage`, which advances `.preparing → .sending`.
    func beginUpload() {
        guard !isUploading else { return }
        uploadByteCount = nil
        uploadStartTime = nil
        uploadElapsed = nil
        uploadStatus = nil
        uploadProgress = 0
        uploadPhase = .preparing
    }

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
        // One-line notice so the log doesn't look dead while the per-chunk image traffic is quieted.
        if !BLELogging.detailedPayloads {
            trace("Image-data (0x0071/0x0081) frames are quieted during upload — showing the first frame, 5% steps, and a summary; launch with the detailed-payloads flag to show every frame.")
        }
        let modes = config?.transmissionModes ?? 0
        armUploadWatchdog()

        // Debug kill-switch: `-ODUseJSUpload` routes back through ble-common.js during native
        // bring-up. Default is the native ODProtocolKit direct-write path.
        guard ProcessInfo.processInfo.arguments.contains("-ODUseJSUpload") else {
            let transmissionModes = TransmissionModes(rawValue: modes)
            uploadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.protocolClient.uploadImage(pixelData, modes: transmissionModes,
                                                              refresh: .full, etag: nil) { [weak self] progress in
                        guard let self, self.uploadPhase == .sending else { return }
                        self.uploadProgress = Double(progress.bytesSent) / Double(max(1, progress.bytesTotal))
                        if self.uploadProgress >= 1 { self.completeUploadEarly() }
                    }
                    self.uploadWatchdog?.cancel(); self.uploadWatchdog = nil
                    // completeUploadEarly usually already flipped to .succeeded at the last data ACK.
                    if self.uploadPhase == .sending {
                        self.uploadProgress = 1; self.finishUploadTiming(); self.uploadPhase = .succeeded
                    }
                } catch {
                    self.uploadWatchdog?.cancel(); self.uploadWatchdog = nil
                    if self.uploadPhase == .sending { self.failUpload(error.localizedDescription) }
                }
            }
            return
        }

        let arguments: [String: Any] = [
            "rawHex": pixelData.hexString.replacingOccurrences(of: " ", with: ""),
            "compress": compressed,
            "transmissionModes": Int(modes),
            "useFastRefresh": false
        ]
        call("uploadPacked", arguments: arguments) { [weak self] result in
            guard let self else { return }
            self.uploadWatchdog?.cancel()
            self.uploadWatchdog = nil
            // The Composer already returned to the canvas once every chunk was acked (see
            // completeUploadEarly below) — this closure only still matters if that hasn't
            // happened yet. Once we've moved on, the device's eventual refresh-complete/timeout
            // notification is irrelevant to the UI, so ignore it rather than reopening the
            // status overlay after the user has left it.
            guard self.uploadPhase == .sending else { return }
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

    /// Ends the send as soon as every chunk has been transmitted and acked, rather than waiting
    /// for the device's silent e-paper refresh to finish (`0x73`, seconds to tens of seconds later
    /// with no BLE traffic in between). The Composer only needs confirmation that the image data
    /// made it to the display; the refresh itself is the display's problem from here.
    private func completeUploadEarly() {
        uploadWatchdog?.cancel()
        uploadWatchdog = nil
        finishUploadTiming()
        uploadPhase = .succeeded
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
        case .idle, .preparing, .sending:
            break
        }
    }

    /// `ble-common.js` streams an image over many chunks with no overall timeout, so a device that
    /// stops responding mid-upload would leave the send stuck and the progress bar frozen. The
    /// watchdog is re-armed on every `uploadProgress`/`uploadStatus` event (see
    /// `handleRuntimeEvent`) so a slow-but-advancing upload isn't killed; it only fires after a
    /// window with no forward progress. Once every chunk is sent and acked (`uploadProgress >= 1`)
    /// the send completes immediately (see `completeUploadEarly`) without arming this again, so the
    /// window only ever needs to cover chunk transfer, not the device's later (and silent) e-paper
    /// refresh.
    private func armUploadWatchdog() {
        uploadWatchdog?.cancel()
        let window: TimeInterval = 30
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.trace("uploadImage STALL WATCHDOG: no progress \(Int(window))s; " +
                       "progress=\(self.uploadProgress), appState=\(self.connectionState), " +
                       "peripheralState=\(self.peripheral.state.rawValue)", level: .error)
            self.uploadProgress = 0
            self.failUpload("Image upload timed out. The display stopped responding.")
        }
        uploadWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
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
            // Status messages are forward progress too — notably "Upload complete…, refreshing
            // display…", which arrives right as the silent e-paper refresh phase begins.
            if uploadPhase == .sending { armUploadWatchdog() }
        case "uploadProgress":
            let progress = (payload["progress"] as? NSNumber)?.doubleValue ?? 0
            let total = max(1, (payload["total"] as? NSNumber)?.doubleValue ?? 1)
            uploadProgress = min(1, progress / total)
            guard uploadPhase == .sending else { break }
            if uploadProgress >= 1 {
                // All chunks are sent and acked — don't wait for the device's refresh cycle.
                completeUploadEarly()
            } else {
                // Forward progress resets the stall window so a slow-but-advancing upload isn't killed.
                armUploadWatchdog()
            }
        case "configProgress":
            // Only the read that emitted this event may move its progress or re-arm its watchdog.
            // Runtime events are queued, so one from a superseded read can arrive after a newer read
            // has started; without the token it would perturb the live read's progress and timing.
            let eventToken = (payload["readToken"] as? NSNumber)?.uint64Value
            guard eventToken == configReadToken else {
                trace("ignoring configProgress from a superseded read (token \(eventToken.map(String.init) ?? "nil"))",
                      level: .info)
                break
            }
            let received = (payload["received"] as? NSNumber)?.doubleValue ?? 0
            let total = max(1, (payload["total"] as? NSNumber)?.doubleValue ?? 1)
            configReadProgress = min(1, received / total)
            // Forward progress resets the stall window so a slow-but-advancing read isn't killed.
            if configReadState == .reading { armConfigReadWatchdog() }
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
        // Collapse the image-data chunk flood *during an active upload* into the quiet meter (first
        // frame + 5% steps + summary). A real photo send streams hundreds of 0x71 (direct-write) /
        // 0x81 (pipe) data frames and their acks/SACKs, which would otherwise cause hundreds of
        // main-thread log updates. Outside an upload — a Tester send of the "Image Data" preset, its
        // ACK, or any raw 0x__71/0x__81 packet — the packet is intentional and stays visible, so the
        // guard keys on `uploadPhase == .sending`, not just the opcode. A Debug launch flag restores
        // every frame during uploads.
        let opcode = data.count >= 2 ? data[1] : 0
        let isStreamFrame = opcode == UInt8(CMD_DIRECT_WRITE_DATA & 0xFF) || opcode == UInt8(CMD_PIPE_WRITE_DATA & 0xFF)
        if !BLELogging.detailedPayloads, uploadPhase == .sending, isStreamFrame {
            meterImageWriteFrame(direction: direction, data: data)
            return
        }
        let entry = LogEntry(direction: direction, data: data, label: label)
        let arrow = direction == .sent ? "→" : "←"
        ODLog.ble.debug("\(arrow, privacy: .public) \(label ?? "", privacy: .public) \(data.hexString, privacy: .public)")
        logHandler(entry)
    }

    /// Meter one image-write stream frame. Only the host's SENT data frames advance the meter; device
    /// acks/SACKs are silent. Logs the first frame in full, then a line at each new 5% step.
    private func meterImageWriteFrame(direction: LogEntry.Direction, data: Data) {
        guard direction == .sent else { return }
        if imageWriteLog.startTime == nil { imageWriteLog = ImageWriteLog(startTime: Date()) }
        imageWriteLog.frames += 1
        if !imageWriteLog.firstLogged {
            imageWriteLog.firstLogged = true
            trace("image write: frame 1 (\(data.count)B) hex=\(data.hexString); per-frame log quieted (first + 5% steps + summary)")
            return
        }
        let pct = Int(min(1, uploadProgress) * 100)
        let step = pct / 5
        if pct < 100, step > imageWriteLog.lastStep {
            imageWriteLog.lastStep = step
            trace("image write: \(pct)% (\(imageWriteLog.frames) frames)")
        }
    }

    /// Emit the one-line completion summary and reset the meter (fired when the upload leaves `.sending`).
    private func finishImageWriteMeter() {
        defer { imageWriteLog = ImageWriteLog() }
        guard let start = imageWriteLog.startTime, imageWriteLog.frames > 0 else { return }
        let elapsed = Date().timeIntervalSince(start)
        let bytes = uploadByteCount ?? 0
        let rate = elapsed > 0 ? Double(bytes) / 1024 / elapsed : 0
        trace(String(format: "image write complete: %d frames, %d bytes, %.2fs, %.1f KB/s",
                     imageWriteLog.frames, bytes, elapsed, rate))
    }

    private func trace(_ message: String, level: OSLogType = .debug) {
        let message = "[\(deviceID.prefix(8))] \(message)"
        ODLog.ble.log(level: level, "\(message, privacy: .public)")
        logHandler(LogEntry(direction: .system, data: Data(), label: message))
    }

    private func responseLabel(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        let status = data[0] == RESP_ACK ? "OK" : (data[0] == RESP_NACK ? "ERR" : nil)
        return status
    }
}

struct ODDeviceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
