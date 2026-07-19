import Foundation

/// High-level native client for the OpenDisplay wire protocol. Owns the notification router and a
/// single-operation-in-flight gate; each public method is one wire exchange. `@MainActor` for
/// lock-free interop with CoreBluetooth and the app's `@Published` state.
///
/// Phase 1 surface: `uploadImage` (legacy direct-write) + `sendRaw`. Config transport, commands,
/// auth/crypto, and pipe/partial land in later phases against the same router/link.
@MainActor
public final class ODProtocolClient {
    private let link: ODLink
    private let router = ODNotificationRouter()
    private let secureChannel = ODSecureChannel()
    private var busy = false

    /// Test-only injection of the auth client nonce (deterministic KAT fixtures); nil → secure random.
    var testClientNonceOverride: [UInt8]?

    /// Out-of-band events (refresh completion, logs).
    public var onEvent: ((ODClientEvent) -> Void)?
    /// Every wire packet, for the app's BLE traffic log.
    public var onWireTraffic: ((ODWireDirection, Data) -> Void)?

    /// True once a 0x50 session is live; traffic is then CCM-wrapped and chunk budgets shrink.
    public var isSessionEstablished: Bool { secureChannel.isEstablished }

    public init(link: ODLink) {
        self.link = link
        link.onNotification = { [weak self] data in
            guard let self else { return }
            self.onWireTraffic?(.received, data)
            do {
                let plain = try self.secureChannel.unwrapInbound(data)
                self.router.receive(plain)
            } catch {
                // Envelope failed to decrypt/authenticate: the exchange is corrupt — fail the op fast.
                self.onEvent?(.log("inbound decrypt failed: \(error)"))
                self.router.failPending(error)
            }
        }
        link.onDisconnect = { [weak self] _ in
            self?.secureChannel.reset()
            self?.router.failPending(ODProtocolError.disconnected)
        }
        router.onUnmatched = { [weak self] note in
            guard let self else { return }
            // Refresh completion arrives after the caller has already completed at the last data ACK.
            if note.status == 0x00, note.opcode == RESP_DIRECT_WRITE_REFRESH_SUCCESS {
                self.onEvent?(.refreshCompleted)
            } else if note.status == 0x00, note.opcode == RESP_DIRECT_WRITE_REFRESH_TIMEOUT {
                self.onEvent?(.refreshTimedOut)
            }
        }
    }

    /// Encryption seam: wraps every outbound frame in the CCM envelope once a session exists
    /// (`ODSecureChannel` passes bootstrap opcodes 0x50/0x43 through in the clear).
    private func transmit(_ data: Data) async throws {
        let outbound = try secureChannel.wrapOutbound(data)
        onWireTraffic?(.sent, outbound)
        try await link.send(outbound)
    }

    /// Send literal bytes with no envelope wrap (engineering / BLE-Tester raw writes).
    private func transmitRaw(_ data: Data) async throws {
        onWireTraffic?(.sent, data)
        try await link.send(data)
    }

    private func withExclusiveOp<T>(_ body: () async throws -> T) async throws -> T {
        if busy { throw ODProtocolError.busy }
        busy = true
        defer { busy = false; router.expectedOpcode = nil }
        return try await body()
    }

    /// Upload a packed image. Phase 1 always uses the legacy direct-write path; pipe selection
    /// (modes bit4) is added in Phase 4.
    public func uploadImage(_ packed: Data,
                            modes: TransmissionModes,
                            refresh: ODRefreshMode = .full,
                            etag: UInt32? = nil,
                            progress: ((ODUploadProgress) -> Void)? = nil) async throws {
        try await withExclusiveOp {
            let policy = ODChunkPolicy(encrypted: secureChannel.isEstablished)
            let uploader = DirectWriteUploader(
                policy: policy,
                router: router,
                transmit: { [weak self] in try await self?.transmit($0) },
                setExpectedOpcode: { [weak self] in self?.router.expectedOpcode = $0 }
            )
            try await uploader.run(packed: packed, modes: modes, refresh: refresh, etag: etag, progress: progress)
        }
    }

    // MARK: - Config transport (0x40 / 0x41 / 0x42)

    /// Read the raw config blob (transport only; hand to the toolbox engine for content decode).
    public func readConfigBlob(progress: ((Double) -> Void)? = nil) async throws -> Data {
        try await withExclusiveOp { try await configTransfer().read(progress: progress) }
    }

    /// Write a raw config blob (chunked with per-chunk ACK).
    public func writeConfigBlob(_ blob: Data, progress: ((Double) -> Void)? = nil) async throws {
        try await withExclusiveOp { try await configTransfer().write(blob, progress: progress) }
    }

    // MARK: - Firmware / MSD / simple commands

    public func firmwareVersion() async throws -> (major: Int, minor: Int, sha: String?) {
        try await withExclusiveOp { try await simpleCommands().firmwareVersion() }
    }

    public func readMSD() async throws -> Data {
        try await withExclusiveOp { try await simpleCommands().readMSD() }
    }

    /// Reboot / enter-DFU / deep-sleep / power-off / raw — fire-and-forget.
    public func send(_ command: ODSimpleCommand) async throws {
        try await withExclusiveOp { try await simpleCommands().send(command) }
    }

    private func makeTransmit() -> (Data) async throws -> Void { { [weak self] in try await self?.transmit($0) } }
    private func makeSetExpected() -> (UInt8?) -> Void { { [weak self] in self?.router.expectedOpcode = $0 } }
    private func simpleCommands() -> SimpleCommands {
        SimpleCommands(router: router, transmit: makeTransmit(), setExpectedOpcode: makeSetExpected())
    }
    private func configTransfer() -> ConfigTransfer {
        ConfigTransfer(router: router, policy: ODChunkPolicy(encrypted: secureChannel.isEstablished),
                       transmit: makeTransmit(), setExpectedOpcode: makeSetExpected())
    }

    // MARK: - Authentication

    /// Perform the 0x50 challenge/response handshake with `masterKey` (16 bytes). On success a live
    /// session is established: subsequent traffic is CCM-wrapped and chunk budgets shrink.
    public func authenticate(masterKey: Data) async throws {
        try await withExclusiveOp {
            var auth = Authenticator(router: router, transmit: makeTransmit(), setExpectedOpcode: makeSetExpected())
            if let nonce = testClientNonceOverride { auth.makeClientNonce = { nonce } }
            let session = try await auth.authenticate(masterKey: [UInt8](masterKey))
            secureChannel.establish(sessionKey: session.key, sessionID: session.id)
        }
    }

    /// Send a raw pre-built packet (BLE Tester / engineering tools). Fire-and-forget, never wrapped.
    public func sendRaw(_ data: Data) async throws {
        try await withExclusiveOp { try await transmitRaw(data) }
    }

    /// Link dropped — clear the session and fail any pending continuation.
    public func linkDidDisconnect() {
        secureChannel.reset()
        router.failPending(ODProtocolError.disconnected)
    }
}
