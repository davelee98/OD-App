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
///
/// ## Operation identity
///
/// Every terminal path goes through `finishWaiter` / `clearCollector` / `timeoutCollector`, which
/// verify that the caller still *owns* the slot before touching it. This matters because
/// `DispatchWorkItem.cancel()` does not guarantee an already-dequeued item won't run: without an
/// ownership check, operation A's stale timeout could fire after A ended and resume or fail
/// whichever operation happens to occupy the slot next.
///
/// The collector needs two levels, because it re-arms:
/// - `id` distinguishes collector C from a later collector D.
/// - `timeoutEpoch` distinguishes C's *current* stall window from C's own earlier, already-superseded
///   timeout — an `id` check alone would let a stale re-arm time C out mid-stream.
@MainActor
final class ODNotificationRouter {

    /// Monotonic source for waiter/collector identities. Never reused within a router's lifetime.
    private var nextOperationID: UInt64 = 0
    private func makeOperationID() -> UInt64 {
        nextOperationID &+= 1
        return nextOperationID
    }

    // MARK: One-shot waiter
    private struct Waiter {
        let id: UInt64
        let predicate: (ODFrame.Notification) -> Bool
        let continuation: CheckedContinuation<ODFrame.Notification, Error>
        let timeout: DispatchWorkItem
        let operation: String
    }
    private var waiter: Waiter?

    // MARK: Streaming collector
    private struct Collector {
        let id: UInt64
        let operation: String
        let duration: TimeInterval
        let step: (ODFrame.Notification) -> Void   // completes the continuation when reduce yields/throws
        let fail: (Error) -> Void
        var timeout: DispatchWorkItem
        /// Bumped on every re-arm. Only a timeout carrying the current epoch may fire.
        var timeoutEpoch: UInt64
    }
    private var collector: Collector?

    /// Frames not consumed by the active consumer (refresh completion, generic acks).
    var onUnmatched: ((ODFrame.Notification) -> Void)?

    /// When set (only during a PIPE transfer), every classified frame is offered here FIRST, ahead of
    /// the waiter/collector. PIPE is a concurrent send/receive loop — SACKs arrive mid-burst with no
    /// waiter armed — so the uploader owns the inbound stream for its duration and buffers frames
    /// itself. The sink forwards frames it doesn't want (e.g. refresh 0x73/0x74) back to `onUnmatched`.
    var frameSink: ((ODFrame.Notification) -> Void)?

    /// Opcode currently in flight, for `ODFrame.classify` byte-order + 0x73-collision disambiguation.
    var expectedOpcode: UInt8?

    /// True while a waiter or collector occupies the slot. Tests use this to synchronize on an
    /// operation actually being armed, since `async let` + `Task.yield()` is not a reliable barrier
    /// for child-task startup.
    var hasPendingOperation: Bool { waiter != nil || collector != nil }

    // MARK: - Terminal paths (ownership-checked)
    //
    // These are package-internal rather than private so `ODNotificationRouterTests` can invoke them
    // with a deliberately stale id/epoch. That is the only way to deterministically simulate an
    // already-dequeued `DispatchWorkItem` firing after its operation ended — the exact hazard the
    // ownership checks exist to defeat. Production code must only reach them via the timeout work
    // items, `receive`, and `failPending`.

    /// Settle the one-shot waiter. No-ops unless `id` still owns the slot, so a stale timeout can
    /// never resume a successor's continuation. Clears the slot *before* resuming, so a continuation
    /// that synchronously arms a new wait isn't immediately torn down by this call.
    func finishWaiter(id: UInt64, with result: Result<ODFrame.Notification, Error>) {
        guard let w = waiter, w.id == id else { return }
        w.timeout.cancel()
        waiter = nil
        switch result {
        case .success(let note): w.continuation.resume(returning: note)
        case .failure(let error): w.continuation.resume(throwing: error)
        }
    }

    /// Release the collector slot if `id` still owns it. Called by the collector's own `step`/`fail`
    /// closures immediately before they resume, so ownership is dropped before reentrancy is possible.
    func clearCollector(id: UInt64) {
        guard let c = collector, c.id == id else { return }
        c.timeout.cancel()
        collector = nil
    }

    /// A collector stall timeout fired. Requires *both* identity and epoch: identity keeps C's timeout
    /// from killing collector D, and the epoch keeps C's own superseded timeout from killing C.
    func timeoutCollector(id: UInt64, epoch: UInt64) {
        guard let c = collector, c.id == id, c.timeoutEpoch == epoch else { return }
        c.fail(ODProtocolError.timeout(operation: c.operation))
    }

    // MARK: - Inbound

    /// Feed a raw notification (from `ODLink.onNotification`).
    func receive(_ data: Data) {
        guard let note = ODFrame.classify([UInt8](data), expectedOpcode: expectedOpcode) else { return }
        if let sink = frameSink {
            sink(note)
            return
        }
        if var c = collector {
            // Re-arm the stall timeout on every chunk, then step. The new work item captures the
            // freshly-allocated epoch, so the one it replaces becomes inert even if already dequeued.
            c.timeout.cancel()
            let id = c.id
            let epoch = c.timeoutEpoch &+ 1
            let work = DispatchWorkItem { [weak self] in
                self?.timeoutCollector(id: id, epoch: epoch)
            }
            c.timeout = work
            c.timeoutEpoch = epoch
            collector = c
            DispatchQueue.main.asyncAfter(deadline: .now() + c.duration, execute: work)
            c.step(note)
            return
        }
        if let w = waiter, w.predicate(note) {
            finishWaiter(id: w.id, with: .success(note))
            return
        }
        onUnmatched?(note)
    }

    /// Suspend until a notification matches `predicate`, or `timeout` seconds elapse.
    func awaitNotification(operation: String,
                           timeout: TimeInterval = 8,
                           matching predicate: @escaping (ODFrame.Notification) -> Bool) async throws -> ODFrame.Notification {
        if waiter != nil || collector != nil { throw ODProtocolError.busy }
        let id = makeOperationID()
        return try await withCheckedThrowingContinuation { cont in
            let work = DispatchWorkItem { [weak self] in
                self?.finishWaiter(id: id,
                                   with: .failure(ODProtocolError.timeout(operation: operation)))
            }
            waiter = Waiter(id: id, predicate: predicate, continuation: cont,
                            timeout: work, operation: operation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Consume a stream of notifications until `reduce` returns a value (config read). Timeout
    /// re-arms on every notification.
    func awaitCollected<T>(operation: String,
                           timeout: TimeInterval = 8,
                           reduce: @escaping (ODFrame.Notification) throws -> T?) async throws -> T {
        if waiter != nil || collector != nil { throw ODProtocolError.busy }
        let id = makeOperationID()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            var finished = false
            let step: (ODFrame.Notification) -> Void = { [weak self] note in
                guard let self, !finished else { return }
                do {
                    if let value = try reduce(note) {
                        finished = true
                        self.clearCollector(id: id)
                        cont.resume(returning: value)
                    }
                } catch {
                    finished = true
                    self.clearCollector(id: id)
                    cont.resume(throwing: error)
                }
            }
            let fail: (Error) -> Void = { [weak self] error in
                guard let self, !finished else { return }
                finished = true
                self.clearCollector(id: id)
                cont.resume(throwing: error)
            }
            let epoch: UInt64 = 0
            let work = DispatchWorkItem { [weak self] in
                self?.timeoutCollector(id: id, epoch: epoch)
            }
            collector = Collector(id: id, operation: operation, duration: timeout,
                                  step: step, fail: fail, timeout: work, timeoutEpoch: epoch)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Fail any pending waiter/collector (link dropped).
    func failPending(_ error: Error) {
        if let w = waiter { finishWaiter(id: w.id, with: .failure(error)) }
        collector?.fail(error)
    }
}
