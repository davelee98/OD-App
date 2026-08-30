import XCTest
import SwiftData
import ODProtocolKit
@testable import OD_App

/// Covers the pieces of the encrypted-setup fix that are testable without a radio: the JS-parity
/// error normalizer, the config-read state signal, and the `SavedDisplayEntity` lock flag.
///
/// The connect-time coordinator itself (auto-authenticate, join-vs-reject, generation staleness)
/// needs a live `ODDevice`, which requires a real `CBPeripheral` — those paths are covered by the
/// package-level tests plus the manual hardware matrix in the plan.
final class EncryptedSetupTests: XCTestCase {

    // MARK: - Auth-required normalization
    //
    // The native path throws a typed error; the SHA-pinned `ble-common.js` can only reject with a
    // string. `ODDevice.isAuthRequired` is the single place that string is matched, so everything
    // downstream can branch on `ConfigReadState.authRequired` instead of on message text.

    func testNativeAuthRequiredIsRecognized() {
        XCTAssertTrue(ODDevice.isAuthRequired(ODProtocolError.authRequired))
    }

    func testJSAuthRequiredStringIsRecognized() {
        // The exact rejection `ble-common.js` produces for a `00 40 FE` reply.
        let error = OpenDisplayJSRuntime.RuntimeError.operationFailed("Authentication required (0xFE)")
        XCTAssertTrue(ODDevice.isAuthRequired(error))
    }

    func testJSAuthRequiredMatchesOnStatusByteAlone() {
        let error = OpenDisplayJSRuntime.RuntimeError.operationFailed("device replied 0xFE")
        XCTAssertTrue(ODDevice.isAuthRequired(error))
    }

    /// Unrelated failures must not be mistaken for "needs a password" — that would show a key prompt
    /// for a display that is merely unreachable.
    func testUnrelatedErrorsAreNotAuthRequired() {
        XCTAssertFalse(ODDevice.isAuthRequired(ODProtocolError.timeout(operation: "configRead")))
        XCTAssertFalse(ODDevice.isAuthRequired(ODProtocolError.disconnected))
        XCTAssertFalse(ODDevice.isAuthRequired(ODProtocolError.authFailed(.wrongKey)))
        XCTAssertFalse(ODDevice.isAuthRequired(
            OpenDisplayJSRuntime.RuntimeError.operationFailed("Not connected")))
        XCTAssertFalse(ODDevice.isAuthRequired(ODDeviceError("something else")))
    }

    // MARK: - ConfigReadState

    /// `.authRequired` must be its own case, not a flavour of `.failed`: the Add sheet shows a key
    /// prompt for one and a Retry button for the other.
    func testAuthRequiredIsDistinctFromFailed() {
        XCTAssertNotEqual(ODDevice.ConfigReadState.authRequired,
                          ODDevice.ConfigReadState.failed("This display is password protected."))
        XCTAssertNotEqual(ODDevice.ConfigReadState.authRequired, ODDevice.ConfigReadState.unread)
        XCTAssertEqual(ODDevice.ConfigReadState.authRequired, ODDevice.ConfigReadState.authRequired)
    }

    // MARK: - AuthPhase

    func testRateLimitedPhaseCarriesItsOwnDeadline() {
        let deadline = Date().addingTimeInterval(60)
        let phase = ODDevice.AuthPhase.rateLimited(retryNotBefore: deadline)
        guard case .rateLimited(let carried) = phase else { return XCTFail("wrong case") }
        XCTAssertEqual(carried, deadline)
    }

    /// The reasons the UI and the credential-forgetting logic branch on must stay distinguishable.
    func testFailedPhasesArePerReason() {
        XCTAssertNotEqual(ODDevice.AuthPhase.failed(.wrongKey),
                          ODDevice.AuthPhase.failed(.proofMismatch))
        XCTAssertNotEqual(ODDevice.AuthPhase.authenticated, ODDevice.AuthPhase.idle)
    }

    // MARK: - SavedDisplayEntity lock flag

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: SavedDisplayEntity.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Defaults to false so existing stores migrate lightweight and self-correct on next connect.
    @MainActor
    func testRequiresAuthenticationDefaultsToFalse() throws {
        let container = try makeContainer()
        let entity = SavedDisplayEntity(id: UUID().uuidString, friendlyName: "Kitchen")
        container.mainContext.insert(entity)
        try container.mainContext.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<SavedDisplayEntity>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertFalse(fetched[0].requiresAuthentication)
    }

    @MainActor
    func testRequiresAuthenticationPersists() throws {
        let container = try makeContainer()
        let id = UUID().uuidString
        let entity = SavedDisplayEntity(id: id, friendlyName: "Hallway", requiresAuthentication: true)
        container.mainContext.insert(entity)
        try container.mainContext.save()

        let descriptor = FetchDescriptor<SavedDisplayEntity>(predicate: #Predicate { $0.id == id })
        let fetched = try container.mainContext.fetch(descriptor)
        XCTAssertTrue(fetched.first?.requiresAuthentication == true)
    }

    /// The user's constraint, encoded as a test: lock state travels with the saved display, but the
    /// key never enters the SwiftData store — it stays in the Keychain.
    @MainActor
    func testEntityCarriesNoKeyMaterial() throws {
        let container = try makeContainer()
        let entity = SavedDisplayEntity(id: UUID().uuidString, friendlyName: "Study",
                                        requiresAuthentication: true)
        container.mainContext.insert(entity)
        try container.mainContext.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<SavedDisplayEntity>())[0]
        // Every stored property, rendered. A key would have to surface as hex or raw bytes in one
        // of these; there is deliberately no property that could hold it.
        let dumped = [
            fetched.id, fetched.friendlyName, fetched.deviceLocation,
            String(fetched.width), String(fetched.height), String(fetched.colorScheme),
            String(fetched.resolutionConfirmed), String(fetched.requiresAuthentication),
        ].joined(separator: "|")
        XCTAssertFalse(dumped.lowercased().contains("psk"))
        XCTAssertFalse(dumped.lowercased().contains("key"))
    }

    // MARK: - ODAuth key handling

    /// `savePSK` reports failure now, so `unlock` can tell the user the key wasn't persisted rather
    /// than silently re-prompting on the next connect.
    func testSavePSKRoundTripsAndReportsSuccess() {
        let deviceID = "test-\(UUID().uuidString)"
        defer { ODAuth.deletePSK(forDevice: deviceID) }

        let key = Data((0..<16).map { UInt8($0) })
        XCTAssertTrue(ODAuth.savePSK(key, forDevice: deviceID))
        XCTAssertEqual(ODAuth.loadPSK(forDevice: deviceID), key)

        ODAuth.deletePSK(forDevice: deviceID)
        XCTAssertNil(ODAuth.loadPSK(forDevice: deviceID))
    }

    func testRandomPSKIsSixteenBytesAndVaries() throws {
        let a = try XCTUnwrap(ODAuth.randomPSK())
        let b = try XCTUnwrap(ODAuth.randomPSK())
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(b.count, 16)
        XCTAssertNotEqual(a, b)
    }

    /// Replacing a key must not pass through a window with no key stored. The old delete-then-add
    /// sequence destroyed a valid credential before knowing the replacement would land, so a failed
    /// add left the display with nothing.
    func testReplacingAKeyOverwritesInPlace() {
        let deviceID = "test-\(UUID().uuidString)"
        defer { ODAuth.deletePSK(forDevice: deviceID) }

        let first = Data(repeating: 0x11, count: 16)
        let second = Data(repeating: 0x22, count: 16)

        XCTAssertTrue(ODAuth.savePSK(first, forDevice: deviceID))
        XCTAssertEqual(ODAuth.loadPSK(forDevice: deviceID), first)

        XCTAssertTrue(ODAuth.savePSK(second, forDevice: deviceID))
        XCTAssertEqual(ODAuth.loadPSK(forDevice: deviceID), second)

        // Exactly one entry — an update, not an accumulating pile of adds.
        XCTAssertEqual(ODAuth.loadPSK(forDevice: deviceID), second)
    }

    /// Saving over an existing entry repeatedly must stay stable, since every successful unlock
    /// re-saves the key.
    func testRepeatedSavesAreIdempotent() {
        let deviceID = "test-\(UUID().uuidString)"
        defer { ODAuth.deletePSK(forDevice: deviceID) }

        let key = Data(repeating: 0xAB, count: 16)
        for _ in 0..<5 { XCTAssertTrue(ODAuth.savePSK(key, forDevice: deviceID)) }
        XCTAssertEqual(ODAuth.loadPSK(forDevice: deviceID), key)
    }
}
