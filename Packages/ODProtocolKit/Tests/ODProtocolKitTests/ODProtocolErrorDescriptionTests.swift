import XCTest
@testable import ODProtocolKit

/// Regression tests for the root cause of the encrypted-setup bug: `ODProtocolError` had no
/// `LocalizedError` conformance, so every one of these errors reached the user as the Foundation
/// default — "The operation couldn't be completed. (ODProtocolKit.ODProtocolError error 5.)" —
/// once `ODDevice` stuffed `error.localizedDescription` into `lastError`.
final class ODProtocolErrorDescriptionTests: XCTestCase {

    private let allCases: [ODProtocolError] = [
        .busy,
        .notConnected,
        .disconnected,
        .timeout(operation: "configRead"),
        .deviceRejected(opcode: 0x0040, code: 0x03),
        .deviceRejected(opcode: 0x0040, code: nil),
        .authRequired,
        .authFailed(.wrongKey),
        .authFailed(.notConfigured),
        .authFailed(.rateLimited),
        .authFailed(.proofMismatch),
        .authFailed(.noFreshChallenge),
        .authFailed(.deviceError(0xFF)),
        .malformedResponse("auth proof too short"),
        .sizeMismatch(expected: 100, actual: 40),
    ]

    /// No case may fall back to the Foundation default rendering.
    func testEveryCaseHasAHumanReadableDescription() {
        for error in allCases {
            let text = error.localizedDescription
            XCTAssertFalse(text.isEmpty, "\(error) produced an empty description")
            XCTAssertFalse(text.contains("ODProtocolKit.ODProtocolError error"),
                           "\(error) fell back to the Foundation default: \(text)")
            XCTAssertFalse(text.contains("couldn't be completed"),
                           "\(error) fell back to the Foundation default: \(text)")
        }
    }

    /// The strings the encrypted-setup UI actually shows the user.
    func testAuthDescriptionsReadAsSentences() {
        XCTAssertEqual(ODProtocolError.authRequired.localizedDescription,
                       "This display is password protected.")
        XCTAssertEqual(ODProtocolError.authFailed(.wrongKey).localizedDescription,
                       "Authentication failed: wrong key.")
        XCTAssertEqual(ODProtocolError.authFailed(.rateLimited).localizedDescription,
                       "Authentication failed: rate limited (too many attempts).")
        XCTAssertEqual(ODProtocolError.authFailed(.deviceError(0xFF)).localizedDescription,
                       "Authentication failed: device error 0xff.")
    }

    /// The reasons callers branch on must stay distinguishable, not collapse into one another.
    func testAuthFailureReasonsAreDistinct() {
        XCTAssertNotEqual(ODProtocolError.authFailed(.wrongKey),
                          ODProtocolError.authFailed(.proofMismatch))
        XCTAssertNotEqual(ODProtocolError.authFailed(.rateLimited),
                          ODProtocolError.authFailed(.wrongKey))
        XCTAssertNotEqual(ODProtocolError.authFailed(.deviceError(0x01)),
                          ODProtocolError.authFailed(.deviceError(0x02)))
    }
}
