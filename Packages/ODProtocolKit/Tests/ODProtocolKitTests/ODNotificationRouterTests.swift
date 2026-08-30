import XCTest
@testable import ODProtocolKit

/// Ownership/identity tests for `ODNotificationRouter`'s terminal paths.
///
/// The hazard under test: `DispatchWorkItem.cancel()` does not guarantee an already-dequeued item
/// won't run. Before operation identities existed, a stale timeout dereferenced whichever slot was
/// *currently* installed, so operation A's dead timer could resume or fail operation B.
///
/// Waiting on real wall-clock timers to reproduce that would be inherently racy, so these tests
/// invoke the terminal paths directly with a deliberately stale id/epoch — exactly what a
/// late-firing work item does. Ids come from a monotonic counter starting at 1, so the Nth
/// operation on a fresh router has id N.
@MainActor
final class ODNotificationRouterTests: XCTestCase {

    private func note(_ bytes: [UInt8]) -> Data { Data(bytes) }

    /// Yield until the child task has actually installed its waiter/collector. `async let` plus a
    /// single `Task.yield()` does not reliably order child-task startup, which makes any test that
    /// drives the router immediately afterwards flaky.
    private func awaitArmed(_ router: ODNotificationRouter,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if router.hasPendingOperation { return }
            await Task.yield()
        }
        XCTFail("operation was never armed", file: file, line: line)
    }

    // MARK: - One-shot waiter

    /// A's stale timeout must not resume B's continuation.
    func testStaleWaiterTimeoutDoesNotKillSuccessor() async throws {
        let router = ODNotificationRouter()

        // Waiter A (id 1) — settle it normally so the slot is free.
        async let firstResult: ODFrame.Notification = router.awaitNotification(operation: "A") { $0.opcode == 0x43 }
        await awaitArmed(router)
        router.receive(note([0x00, 0x43]))
        _ = try await firstResult

        // Waiter B (id 2) takes the slot.
        async let secondResult: ODFrame.Notification = router.awaitNotification(operation: "B") { $0.opcode == 0x44 }
        await awaitArmed(router)

        // A's already-dequeued timeout fires late. It must be inert.
        router.finishWaiter(id: 1, with: .failure(ODProtocolError.timeout(operation: "A")))

        // B is still live and settles on its own frame.
        router.receive(note([0x00, 0x44]))
        let got = try await secondResult
        XCTAssertEqual(got.opcode, 0x44, "B must be resumed by its own frame, not A's stale timeout")
    }

    /// The waiter slot is released before the continuation resumes, so a caller that immediately
    /// arms another wait isn't torn down by the call that woke it.
    func testWaiterSlotIsFreeAfterSettling() async throws {
        let router = ODNotificationRouter()
        async let first: ODFrame.Notification = router.awaitNotification(operation: "A") { $0.opcode == 0x43 }
        await awaitArmed(router)
        router.receive(note([0x00, 0x43]))
        _ = try await first

        // Would throw .busy if the slot were still occupied.
        async let second: ODFrame.Notification = router.awaitNotification(operation: "B") { $0.opcode == 0x43 }
        await awaitArmed(router)
        router.receive(note([0x00, 0x43]))
        _ = try await second
    }

    // MARK: - Collector

    /// The subtle one: a collector's OWN superseded timeout must not terminate it. Identity alone
    /// would accept this, because the slot legitimately still belongs to the same collector.
    func testStaleCollectorReArmTimeoutDoesNotKillItsOwnCollector() async throws {
        let router = ODNotificationRouter()
        var seen = 0
        async let collected: Int = router.awaitCollected(operation: "C") { _ in
            seen += 1
            return seen == 2 ? seen : nil     // needs two chunks
        }
        await awaitArmed(router)

        // First chunk re-arms the stall window: epoch 0 -> 1.
        router.receive(note([0x00, 0x40, 0x01]))

        // Epoch 0's work item was already dequeued and now fires. It must be inert.
        router.timeoutCollector(id: 1, epoch: 0)

        // The collector is still alive and completes on its second chunk.
        router.receive(note([0x00, 0x40, 0x02]))
        let value = try await collected
        XCTAssertEqual(value, 2, "a superseded re-arm timeout must not end the live collector")
    }

    /// The current epoch's timeout still works — the epoch check must not disable timeouts entirely.
    func testCurrentEpochTimeoutStillFires() async throws {
        let router = ODNotificationRouter()
        async let collected: Int = router.awaitCollected(operation: "C") { _ in nil }  // never completes
        await awaitArmed(router)

        router.receive(note([0x00, 0x40, 0x01]))   // epoch 0 -> 1
        router.timeoutCollector(id: 1, epoch: 1)   // the live window times out

        do {
            _ = try await collected
            XCTFail("expected timeout")
        } catch ODProtocolError.timeout(let operation) {
            XCTAssertEqual(operation, "C")
        }
    }

    /// Collector C's stale timeout must not terminate a later collector D.
    func testStaleCollectorTimeoutDoesNotKillSuccessor() async throws {
        let router = ODNotificationRouter()

        // Collector C (id 1) completes on its first chunk.
        async let first: Int = router.awaitCollected(operation: "C") { _ in 1 }
        await awaitArmed(router)
        router.receive(note([0x00, 0x40, 0x01]))
        _ = try await first

        // Collector D (id 2) takes the slot.
        async let second: Int = router.awaitCollected(operation: "D") { _ in 2 }
        await awaitArmed(router)

        // C's late timer fires. Wrong identity — must be inert for every epoch.
        router.timeoutCollector(id: 1, epoch: 0)
        router.timeoutCollector(id: 1, epoch: 1)

        router.receive(note([0x00, 0x40, 0x02]))
        let value = try await second
        XCTAssertEqual(value, 2, "D must complete on its own frame, not C's stale timeout")
    }

    /// `clearCollector` with a stale id must not release a successor's slot.
    func testStaleClearDoesNotReleaseSuccessorSlot() async throws {
        let router = ODNotificationRouter()
        async let first: Int = router.awaitCollected(operation: "C") { _ in 1 }
        await awaitArmed(router)
        router.receive(note([0x00, 0x40, 0x01]))
        _ = try await first

        async let second: Int = router.awaitCollected(operation: "D") { _ in 2 }
        await awaitArmed(router)

        router.clearCollector(id: 1)               // stale — must be a no-op

        // If the slot had been wrongly released, this frame would fall through to `onUnmatched`
        // and D would hang instead of completing.
        router.receive(note([0x00, 0x40, 0x02]))
        let value = try await second
        XCTAssertEqual(value, 2)
    }

    // MARK: - Exactly-once resumption
    //
    // Resuming a CheckedContinuation twice traps, so these tests passing at all is the assertion.

    func testFailPendingThenStaleTimeoutResumesOnce() async {
        let router = ODNotificationRouter()
        async let collected: Int = router.awaitCollected(operation: "C") { _ in nil }
        await awaitArmed(router)

        router.failPending(ODProtocolError.disconnected)
        router.timeoutCollector(id: 1, epoch: 0)   // would double-resume without the guard

        do {
            _ = try await collected
            XCTFail("expected disconnected")
        } catch ODProtocolError.disconnected {
        } catch { XCTFail("unexpected: \(error)") }
    }

    func testFailPendingTwiceResumesWaiterOnce() async {
        let router = ODNotificationRouter()
        async let waited: ODFrame.Notification = router.awaitNotification(operation: "A") { _ in true }
        await awaitArmed(router)

        router.failPending(ODProtocolError.disconnected)
        router.failPending(ODProtocolError.disconnected)   // second must be inert

        do {
            _ = try await waited
            XCTFail("expected disconnected")
        } catch ODProtocolError.disconnected {
        } catch { XCTFail("unexpected: \(error)") }
    }

    /// A reducer error and a subsequent stale timeout must not both resume.
    func testReducerThrowThenStaleTimeoutResumesOnce() async {
        struct Boom: Error {}
        let router = ODNotificationRouter()
        async let collected: Int = router.awaitCollected(operation: "C") { _ in throw Boom() }
        await awaitArmed(router)

        router.receive(note([0x00, 0x40, 0x01]))   // reducer throws; also re-armed to epoch 1
        router.timeoutCollector(id: 1, epoch: 1)   // would double-resume without the guard

        do {
            _ = try await collected
            XCTFail("expected Boom")
        } catch is Boom {
        } catch { XCTFail("unexpected: \(error)") }
    }
}
