import XCTest
@testable import ODProtocolKit

/// End-to-end 0x50 handshake + session-crypto flow through `ODProtocolClient` on a scripted device.
/// The device fixture is the deterministic `test_auth_server_proof.py` case (master 00..0f,
/// client_nonce c8c9..d7, server_nonce 6465..73, device_id 00000001); the derived session_key
/// (dcdb..2c) and session_id (f2d5..0a) and every envelope below were captured from crypto.py, so a
/// green run proves the Swift handshake and AEAD are byte-identical to the firmware reference.
@MainActor
final class AuthFlowTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    private let master = Array<UInt8>(0..<16)
    private let clientNonce = Array(200..<216).map { UInt8($0) }
    private let serverNonce = Array(100..<116).map { UInt8($0) }
    private let deviceID: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private let expectedStep2Mac = "a69d66a9e78109fafb180a8fe02d0235"
    private let serverProof = "61538e788da45f057e2c81a3c115691e"

    /// Wire a MockLink that plays the scripted device for the auth handshake.
    private func makeAuthLink(capture: @escaping (Data) -> Void = { _ in }) -> MockLink {
        let link = MockLink()
        link.responder = { [self] frame in
            capture(frame)
            let bytes = [UInt8](frame)
            guard bytes.count >= 2, bytes[1] == 0x50 else { return [] }
            if bytes.count == 3, bytes[2] == AUTH_STATUS_CHALLENGE {   // step 1 request
                return [Data([0x00, 0x50, AUTH_STATUS_CHALLENGE] + serverNonce + deviceID)]
            }
            // step 2: [00][50][client_nonce:16][mac:16]
            return [Data([0x00, 0x50, AUTH_STATUS_SUCCESS] + hex(serverProof))]
        }
        return link
    }

    func testHandshakeEstablishesSession() async throws {
        var step2: Data?
        let link = makeAuthLink { if $0.count == 34 { step2 = $0 } }
        let client = ODProtocolClient(link: link)
        client.testClientNonceOverride = clientNonce

        XCTAssertFalse(client.isSessionEstablished)
        try await client.authenticate(masterKey: Data(master))
        XCTAssertTrue(client.isSessionEstablished)

        // The step-2 proof the client sent must equal the reference CMAC.
        let sent = try XCTUnwrap(step2)
        XCTAssertEqual([UInt8](sent.prefix(2)), [0x00, 0x50])
        XCTAssertEqual([UInt8](sent[2..<18]), clientNonce)
        XCTAssertEqual([UInt8](sent[18..<34]), hex(expectedStep2Mac))
    }

    func testWrongServerProofRejected() async {
        let link = MockLink()
        link.responder = { [self] frame in
            let b = [UInt8](frame)
            guard b.count >= 2, b[1] == 0x50 else { return [] }
            if b.count == 3 { return [Data([0x00, 0x50, AUTH_STATUS_SUCCESS] + serverNonce + deviceID)] }
            return [Data([0x00, 0x50, AUTH_STATUS_SUCCESS] + Array(repeating: UInt8(0xAA), count: 16))]  // forged proof
        }
        let client = ODProtocolClient(link: link)
        client.testClientNonceOverride = clientNonce
        do {
            try await client.authenticate(masterKey: Data(master))
            XCTFail("expected mutual-auth failure")
        } catch ODProtocolError.authFailed { } catch { XCTFail("unexpected: \(error)") }
        XCTAssertFalse(client.isSessionEstablished)
    }

    func testWrongKeyStatusRejected() async {
        let link = MockLink()
        link.responder = { frame in
            let b = [UInt8](frame)
            guard b.count >= 2, b[1] == 0x50 else { return [] }
            return [Data([0x00, 0x50, AUTH_STATUS_FAILED])]   // device rejects step 1
        }
        let client = ODProtocolClient(link: link)
        client.testClientNonceOverride = clientNonce
        do {
            try await client.authenticate(masterKey: Data(master))
            XCTFail("expected authFailed")
        } catch ODProtocolError.authFailed { } catch { XCTFail("unexpected: \(error)") }
    }

    /// After auth, a gated command must go out CCM-wrapped with the derived session_id at counter 0.
    func testPostAuthOutboundIsEncrypted() async throws {
        var frames: [Data] = []
        let link = makeAuthLink { frames.append($0) }
        let client = ODProtocolClient(link: link)
        client.testClientNonceOverride = clientNonce
        try await client.authenticate(masterKey: Data(master))

        frames.removeAll()
        try await client.send(.reboot)   // 0x0F, fire-and-forget
        let reboot = try XCTUnwrap(frames.first)
        XCTAssertEqual([UInt8](reboot), hex("000ff2d55473ec48de0a0000000000000000eb8e3eedfd5441dcb8fcd46170"))
    }

    /// After auth, a >=31-byte encrypted response must be transparently decrypted before routing.
    func testPostAuthInboundIsDecrypted() async throws {
        let link = MockLink()
        link.responder = { [self] frame in
            let b = [UInt8](frame)
            guard b.count >= 2, b[1] == 0x50 else {
                // Once authenticated, reply to the (encrypted) MSD read with the encrypted fixture.
                if !b.isEmpty { return [Data(hex("0044f2d55473ec48de0a0000000000000000fb13bbe8c8b205c9ff414fdc61b345aa25e55ed99ce461810cb8a664d4"))] }
                return []
            }
            if b.count == 3 { return [Data([0x00, 0x50, AUTH_STATUS_SUCCESS] + serverNonce + deviceID)] }
            return [Data([0x00, 0x50, AUTH_STATUS_SUCCESS] + hex(serverProof))]
        }
        let client = ODProtocolClient(link: link)
        client.testClientNonceOverride = clientNonce
        try await client.authenticate(masterKey: Data(master))

        let msd = try await client.readMSD()
        XCTAssertEqual([UInt8](msd), Array<UInt8>(0..<16))
    }
}
