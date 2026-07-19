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
    private var busy = false

    /// Out-of-band events (refresh completion, logs).
    public var onEvent: ((ODClientEvent) -> Void)?
    /// Every wire packet, for the app's BLE traffic log.
    public var onWireTraffic: ((ODWireDirection, Data) -> Void)?

    public init(link: ODLink) {
        self.link = link
        link.onNotification = { [weak self] data in
            guard let self else { return }
            self.onWireTraffic?(.received, data)
            self.router.receive(data)
        }
        link.onDisconnect = { [weak self] _ in
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

    /// Encryption seam: plaintext in Phase 1; wraps in the CCM envelope once a session exists.
    private func transmit(_ data: Data) async throws {
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
            let policy = ODChunkPolicy(encrypted: false)   // Phase 3 flips this on session
            let uploader = DirectWriteUploader(
                policy: policy,
                router: router,
                transmit: { [weak self] in try await self?.transmit($0) },
                setExpectedOpcode: { [weak self] in self?.router.expectedOpcode = $0 }
            )
            try await uploader.run(packed: packed, modes: modes, refresh: refresh, etag: etag, progress: progress)
        }
    }

    /// Send a raw pre-built packet (BLE Tester / engineering tools). Fire-and-forget.
    public func sendRaw(_ data: Data) async throws {
        try await withExclusiveOp { try await transmit(data) }
    }

    /// Link dropped — fail any pending continuation.
    public func linkDidDisconnect() {
        router.failPending(ODProtocolError.disconnected)
    }
}
