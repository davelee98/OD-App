import XCTest
@testable import ODProtocolKit

/// Known-answer tests for the crypto primitives and the OpenDisplay session KDF / AEAD envelope.
/// The standards vectors (RFC 4493 CMAC, NIST AESAVS ECB) prove the CryptoSwift primitives; the
/// session/CCM vectors were captured from `py-opendisplay/src/opendisplay/crypto.py` (the firmware
/// reference) with fixed inputs (master=00..0f, client_nonce=10..1f, server_nonce=20..2f,
/// device_id=00000001) so the Swift port is byte-identical to the device before any hardware test.
final class ODCryptoTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    // Fixed inputs shared by the session vectors.
    private let master = Array<UInt8>(0..<16)
    private let clientNonce = Array<UInt8>(16..<32)
    private let serverNonce = Array<UInt8>(32..<48)

    // MARK: - Standards KATs (prove CryptoSwift primitives)

    func testCMAC_RFC4493_empty() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        XCTAssertEqual(hex(try ODCrypto.aesCMAC(key: key, data: [])), "bb1d6929e95937287fa37d129b756746")
    }

    func testCMAC_RFC4493_16byte() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let msg = hex("6bc1bee22e409f96e93d7e117393172a")
        XCTAssertEqual(hex(try ODCrypto.aesCMAC(key: key, data: msg)), "070a16b46b4d4144f79bdd9dd04a287c")
    }

    func testECB_NIST() throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let pt = hex("6bc1bee22e409f96e93d7e117393172a")
        XCTAssertEqual(hex(try ODCrypto.aesECBEncrypt(key: key, block: pt)), "3ad77bb40d7a3660a89ecaf32466ef97")
    }

    // MARK: - Session derivation KATs (captured from crypto.py)

    func testDeriveSessionKey() throws {
        let sk = try ODCrypto.deriveSessionKey(master: master, clientNonce: clientNonce, serverNonce: serverNonce)
        XCTAssertEqual(hex(sk), "3d779ea6d697ad5d0cf982354dec3272")
    }

    func testDeriveSessionID() throws {
        let sk = hex("3d779ea6d697ad5d0cf982354dec3272")
        let sid = try ODCrypto.deriveSessionID(sessionKey: sk, clientNonce: clientNonce, serverNonce: serverNonce)
        XCTAssertEqual(hex(sid), "54a523b2c8d4433c")
    }

    func testChallengeResponse() throws {
        let mac = try ODCrypto.challengeResponse(master: master, serverNonce: serverNonce, clientNonce: clientNonce)
        XCTAssertEqual(hex(mac), "5f173f2c210c0212e2c411b44591bc83")
    }

    func testServerProof() throws {
        let sk = hex("3d779ea6d697ad5d0cf982354dec3272")
        let proof = try ODCrypto.serverProof(sessionKey: sk, serverNonce: serverNonce, clientNonce: clientNonce)
        XCTAssertEqual(hex(proof), "88857bffc0aa2d59bcdfd8c92861fb29")
    }

    // MARK: - AEAD envelope KATs (captured from crypto.py encrypt_command)

    private let sessionKey = Array<UInt8>(0..<16)   // crypto.py TestEncryptDecryptCommand session
    private let sessionID = Array<UInt8>(0..<8)

    func testEncryptCommand_0x70_ctr1() throws {
        let out = try ODCrypto.encryptCommand(sessionKey: sessionKey, sessionID: sessionID, counter: 1,
                                              cmd: [0x00, 0x70], payload: [0xAB, 0xCD])
        XCTAssertEqual(hex(out), "007000010203040506070000000000000001e496bfd28c0b5f8209aa795e52a787")
    }

    func testEncryptCommand_0x50_empty_ctr7() throws {
        let out = try ODCrypto.encryptCommand(sessionKey: sessionKey, sessionID: sessionID, counter: 7,
                                              cmd: [0x00, 0x50], payload: [])
        XCTAssertEqual(hex(out), "005000010203040506070000000000000007" + "aa1b95d8127ce9d2f4b7ebea66")
    }

    func testEncryptCommand_0x50_helloWorld_ctr1() throws {
        let out = try ODCrypto.encryptCommand(sessionKey: sessionKey, sessionID: sessionID, counter: 1,
                                              cmd: [0x00, 0x50], payload: Array("hello world".utf8))
        XCTAssertEqual(hex(out), "005000010203040506070000000000000001" + "ed5517d5762ce67831cc055f13440e970f35af3da11836b2")
    }

    // MARK: - Round-trip + tamper detection

    func testEnvelopeRoundTrip() throws {
        let payload = Array("the quick brown fox".utf8)
        let out = try ODCrypto.encryptCommand(sessionKey: sessionKey, sessionID: sessionID, counter: 99,
                                              cmd: [0x00, 0x40], payload: payload)
        let (cmd, recovered) = try ODCrypto.decryptResponse(sessionKey: sessionKey, raw: out)
        XCTAssertEqual(cmd, 0x0040)
        XCTAssertEqual(recovered, payload)
    }

    func testTamperedTagRejected() throws {
        var out = try ODCrypto.encryptCommand(sessionKey: sessionKey, sessionID: sessionID, counter: 5,
                                              cmd: [0x00, 0x40], payload: [1, 2, 3])
        out[out.count - 1] ^= 0xFF   // flip a tag byte
        XCTAssertThrowsError(try ODCrypto.decryptResponse(sessionKey: sessionKey, raw: out)) { err in
            XCTAssertEqual(err as? ODCrypto.CryptoFailure, .decryptFailed)
        }
    }

    func testDecryptTooShortThrows() {
        XCTAssertThrowsError(try ODCrypto.decryptResponse(sessionKey: sessionKey, raw: [0x00, 0x40, 0x00]))
    }
}
