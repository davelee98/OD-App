import Foundation
@testable import ODProtocolKit

/// Scripted `ODLink` for hardware-free state-machine tests. Records every sent packet and, for each
/// send, delivers zero or more notifications back — deferred to the next main-queue turn so the
/// client's awaiting continuation is installed first. Default `responder` echoes an `[00][opcode]`
/// ACK for every command (the happy path).
@MainActor
final class MockLink: ODLink {
    var maximumWriteLength = 512
    var onNotification: ((Data) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private(set) var sent: [Data] = []

    /// Map a sent frame → notifications to deliver back.
    var responder: (Data) -> [Data] = { frame in
        guard frame.count >= 2 else { return [] }
        return [Data([0x00, frame[1]])]   // [00][opcode] ACK
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        sent.append(data)
        completion(nil)
        for response in responder(data) {
            DispatchQueue.main.async { [weak self] in self?.onNotification?(response) }
        }
    }

    func drop(_ error: Error?) { onDisconnect?(error) }
}
