import Foundation

/// The radio abstraction the protocol layer writes to. In the app this is backed by
/// `CoreBluetoothTransport` (write-without-response on characteristic 0x2446); in tests it's a
/// scripted `MockLink`. Keeping it a protocol is what lets every state machine run hardware-free.
///
/// `@MainActor` because CoreBluetooth delivery is main-queue-confined and all protocol state lives
/// on the main actor — this guarantees zero executor hops between a notification arriving and the
/// awaiting continuation resuming.
@MainActor
public protocol ODLink: AnyObject {
    /// Largest write-without-response payload (from `CBPeripheral.maximumWriteValueLength`).
    var maximumWriteLength: Int { get }

    /// Send one packet (write-without-response). `completion` fires when the radio accepts it.
    func send(_ data: Data, completion: @escaping (Error?) -> Void)

    /// Incoming notification bytes.
    var onNotification: ((Data) -> Void)? { get set }

    /// Link dropped (with an optional underlying error).
    var onDisconnect: ((Error?) -> Void)? { get set }
}

public extension ODLink {
    /// async wrapper over the completion-based `send`.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(data) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}
