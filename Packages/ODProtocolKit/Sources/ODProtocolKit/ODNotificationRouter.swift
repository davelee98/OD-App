import Foundation

/// Routes incoming notifications to whichever operation is awaiting one, with a per-await timeout.
///
/// The client enforces a single operation in flight, so at most one waiter exists at a time; a
/// notification that matches the waiter's predicate resumes it, anything else is offered to
/// `onUnmatched` (for the 0x73/0x74 refresh events and generic 0x63/0xFFFF frames). Timeouts are
/// first-class here — replacing the watchdog thicket the JS host needed because `ble-common.js` had
/// none. A `DispatchWorkItem` on `.main` resumes the continuation with `.timeout` if it fires first;
/// the continuation slot is nilled on the first resume so it can never fire twice.
@MainActor
final class ODNotificationRouter {

    private struct Waiter {
        let predicate: (ODFrame.Notification) -> Bool
        let continuation: CheckedContinuation<ODFrame.Notification, Error>
        let timeout: DispatchWorkItem
        let operation: String
    }

    private var waiter: Waiter?
    /// Frames not consumed by the active waiter (refresh completion, generic acks).
    var onUnmatched: ((ODFrame.Notification) -> Void)?

    /// The opcode currently in flight, used by `ODFrame.classify` to disambiguate byte order and the
    /// 0x73 collision. Set by the client around each operation.
    var expectedOpcode: UInt8?

    /// Feed a raw notification in (called from `ODLink.onNotification`).
    func receive(_ data: Data) {
        guard let note = ODFrame.classify([UInt8](data), expectedOpcode: expectedOpcode) else { return }
        if let w = waiter, w.predicate(note) {
            w.timeout.cancel()
            waiter = nil
            w.continuation.resume(returning: note)
            return
        }
        onUnmatched?(note)
    }

    /// Suspend until a notification matching `predicate` arrives, or `timeout` seconds elapse.
    func awaitNotification(operation: String,
                           timeout: TimeInterval = 8,
                           matching predicate: @escaping (ODFrame.Notification) -> Bool) async throws -> ODFrame.Notification {
        if waiter != nil { throw ODProtocolError.busy }
        return try await withCheckedThrowingContinuation { cont in
            let work = DispatchWorkItem { [weak self] in
                guard let self, let w = self.waiter else { return }
                self.waiter = nil
                w.continuation.resume(throwing: ODProtocolError.timeout(operation: operation))
            }
            waiter = Waiter(predicate: predicate, continuation: cont, timeout: work, operation: operation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Fail any pending waiter (link dropped). Called from `ODProtocolClient.linkDidDisconnect`.
    func failPending(_ error: Error) {
        guard let w = waiter else { return }
        w.timeout.cancel()
        waiter = nil
        w.continuation.resume(throwing: error)
    }
}
