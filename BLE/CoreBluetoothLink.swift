import Foundation
import ODProtocolKit

/// Adapts `CoreBluetoothTransport` (the sole owner of the 0x2446 characteristic) to `ODLink`, so the
/// native `ODProtocolClient` can drive the radio without importing CoreBluetooth. `ODDevice` fans
/// incoming notifications into `deliver(_:)` and reports link loss via `linkDropped(_:)`.
@MainActor
final class CoreBluetoothLink: ODLink {
    private let transport: CoreBluetoothTransport

    var onNotification: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    /// Not used by the direct-write uploader (fixed 230/154 chunking); a safe upper bound suffices
    /// until pipe negotiation (Phase 4) consults it.
    var maximumWriteLength: Int { 512 }

    init(transport: CoreBluetoothTransport) { self.transport = transport }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        transport.write(data, completion: completion)
    }

    /// Pump a BLE notification from `ODDevice`'s notification fan-out.
    func deliver(_ data: Data) { onNotification?(data) }

    /// Report link loss so the client can fail any pending continuation.
    func linkDropped(_ error: Error?) { onDisconnect?(error) }
}
