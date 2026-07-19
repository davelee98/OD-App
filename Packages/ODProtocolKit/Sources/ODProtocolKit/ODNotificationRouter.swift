import Foundation

/// Routes incoming notifications to whichever operation is awaiting, with first-class timeouts —
/// the native replacement for the watchdog thicket `ble-common.js` needed (it had none).
///
/// Two consumption modes, at most one active at a time (the client serializes operations):
/// - **waiter** — one-shot: resume when a notification matches a predicate (image/config-write ACKs,
///   firmware/MSD responses).
/// - **collector** — a *stream*: `reduce` runs for every notification until it yields a value, for
///   the unsolicited multi-chunk config-read response. Its timeout re-arms on each notification.
///
/// `@MainActor` so notification delivery and continuation resumption never hop executors.
@MainActor
final class ODNotificationRouter {

    // MARK: One-shot waiter
    private struct Waiter {
        let predicate: (ODFrame.Notification) -> Bool
        let continuation: CheckedContinuation<ODFrame.Notification, Error>
        let timeout: DispatchWorkItem
        let operation: String
    }
    private var waiter: Waiter?

    // MARK: Streaming collector
    private struct Collector {
        let operation: String
        let duration: TimeInterval
        let step: (ODFrame.Notification) -> Void   // completes the continuation when reduce yields/throws
        let fail: (Error) -> Void
        var timeout: DispatchWorkItem
    }
    private var collector: Collector?

    /// Frames not consumed by the active consumer (refresh completion, generic acks).
    var onUnmatched: ((ODFrame.Notification) -> Void)?

    /// Opcode currently in flight, for `ODFrame.classify` byte-order + 0x73-collision disambiguation.
    var expectedOpcode: UInt8?

    /// Feed a raw notification (from `ODLink.onNotification`).
    func receive(_ data: Data) {
        guard let note = ODFrame.classify([UInt8](data), expectedOpcode: expectedOpcode) else { return }
        if var c = collector {
            // Re-arm the stall timeout on every chunk, then step.
            c.timeout.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.collector?.fail(ODProtocolError.timeout(operation: c.operation))
            }
            c.timeout = work
            collector = c
            DispatchQueue.main.asyncAfter(deadline: .now() + c.duration, execute: work)
            c.step(note)
            return
        }
        if let w = waiter, w.predicate(note) {
            w.timeout.cancel(); waiter = nil
            w.continuation.resume(returning: note)
            return
        }
        onUnmatched?(note)
    }

    /// Suspend until a notification matches `predicate`, or `timeout` seconds elapse.
    func awaitNotification(operation: String,
                           timeout: TimeInterval = 8,
                           matching predicate: @escaping (ODFrame.Notification) -> Bool) async throws -> ODFrame.Notification {
        if waiter != nil || collector != nil { throw ODProtocolError.busy }
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

    /// Consume a stream of notifications until `reduce` returns a value (config read). Timeout
    /// re-arms on every notification.
    func awaitCollected<T>(operation: String,
                           timeout: TimeInterval = 8,
                           reduce: @escaping (ODFrame.Notification) throws -> T?) async throws -> T {
        if waiter != nil || collector != nil { throw ODProtocolError.busy }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            var finished = false
            let step: (ODFrame.Notification) -> Void = { [weak self] note in
                guard let self, !finished else { return }
                do {
                    if let value = try reduce(note) {
                        finished = true
                        self.collector?.timeout.cancel(); self.collector = nil
                        cont.resume(returning: value)
                    }
                } catch {
                    finished = true
                    self.collector?.timeout.cancel(); self.collector = nil
                    cont.resume(throwing: error)
                }
            }
            let fail: (Error) -> Void = { [weak self] error in
                guard let self, !finished else { return }
                finished = true
                self.collector?.timeout.cancel(); self.collector = nil
                cont.resume(throwing: error)
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !finished else { return }
                finished = true
                self.collector = nil
                cont.resume(throwing: ODProtocolError.timeout(operation: operation))
            }
            collector = Collector(operation: operation, duration: timeout, step: step, fail: fail, timeout: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Fail any pending waiter/collector (link dropped).
    func failPending(_ error: Error) {
        if let w = waiter {
            w.timeout.cancel(); waiter = nil
            w.continuation.resume(throwing: error)
        }
        collector?.fail(error)
    }
}
