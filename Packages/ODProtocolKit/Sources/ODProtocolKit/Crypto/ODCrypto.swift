import Foundation
import CryptoSwift

/// AES-128 CMAC / ECB / CCM primitives and the OpenDisplay session KDF, ported name-for-name from
/// `py-opendisplay/src/opendisplay/crypto.py` (which in turn matches the firmware's
/// mbedtls/CryptoCell implementations). Every function here is deterministic and hardware-free, so
/// the whole handshake + envelope is pinned by KATs (`ODCryptoTests`) before any device is involved.
///
/// Byte order note: the KDF/CCM counters are **big-endian** (see `counterBE`); this differs from the
/// little-endian config/pipe lengths elsewhere in the protocol. Keep them separate.
enum ODCrypto {

    /// Firmware placeholder device ID (hardcoded in firmware, never changes). Feeds the CMAC/KDF
    /// inputs; the challenge response returns the device's own id but the client signs with this.
    static let deviceID: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    /// CCM auth tag length used by firmware.
    static let tagLength = 12

    enum CryptoFailure: Error, Equatable {
        case badLength(String)
        case decryptFailed          // CCM tag verification failed
    }

    // MARK: - Primitives

    /// AES-128-CMAC. `key` must be 16 bytes.
    static func aesCMAC(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try CMAC(key: key).authenticate(data)
    }

    /// Encrypt a single 16-byte block with AES-ECB (KDF step only; no padding).
    static func aesECBEncrypt(key: [UInt8], block: [UInt8]) throws -> [UInt8] {
        try AES(key: key, blockMode: ECB(), padding: .noPadding).encrypt(block)
    }

    /// Constant-time equality (used for the mutual-auth server-proof compare — never leak via timing
    /// whether an attacker's forged proof matched a prefix of the real one).
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// Big-endian counter, `width` bytes.
    static func counterBE(_ value: UInt64, width: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width)
        var v = value
        var i = width - 1
        while i >= 0 { out[i] = UInt8(v & 0xFF); v >>= 8; i -= 1 }
        return out
    }

    // MARK: - Session derivation (mirrors deriveSessionKey / deriveSessionId)

    /// Derive the per-session AES-128 key.
    ///   1. `intermediate = CMAC(master, "OpenDisplay session" || 0x00 || device_id || client_nonce || server_nonce || 0x00 0x80)`
    ///   2. `session_key  = AES-ECB(master, counter_be(1, 8) || intermediate[0..<8])`
    static func deriveSessionKey(master: [UInt8], clientNonce: [UInt8], serverNonce: [UInt8],
                                 deviceID: [UInt8] = deviceID) throws -> [UInt8] {
        let label = Array("OpenDisplay session".utf8)
        let cmacInput = label + [0x00] + deviceID + clientNonce + serverNonce + [0x00, 0x80]
        let intermediate = try aesCMAC(key: master, data: cmacInput)
        let finalInput = counterBE(1, width: 8) + Array(intermediate[0..<8])
        return try aesECBEncrypt(key: master, block: finalInput)
    }

    /// `session_id = CMAC(session_key, client_nonce || server_nonce)[0..<8]`.
    static func deriveSessionID(sessionKey: [UInt8], clientNonce: [UInt8], serverNonce: [UInt8]) throws -> [UInt8] {
        Array(try aesCMAC(key: sessionKey, data: clientNonce + serverNonce)[0..<8])
    }

    /// The proof the client sends the device in auth step 2:
    /// `CMAC(master, server_nonce || client_nonce || device_id)`.
    static func challengeResponse(master: [UInt8], serverNonce: [UInt8], clientNonce: [UInt8],
                                  deviceID: [UInt8] = deviceID) throws -> [UInt8] {
        try aesCMAC(key: master, data: serverNonce + clientNonce + deviceID)
    }

    /// The device's mutual-auth proof the client recomputes to authenticate the device:
    /// `CMAC(session_key, server_nonce || client_nonce || device_id)`.
    static func serverProof(sessionKey: [UInt8], serverNonce: [UInt8], clientNonce: [UInt8],
                            deviceID: [UInt8] = deviceID) throws -> [UInt8] {
        try aesCMAC(key: sessionKey, data: serverNonce + clientNonce + deviceID)
    }

    // MARK: - AEAD envelope (mirrors encrypt_command / decrypt_response)

    /// Full 16-byte nonce: `session_id(8) || counter_be(8)`. The CCM nonce is its last 13 bytes.
    static func fullNonce(sessionID: [UInt8], counter: UInt64) -> [UInt8] {
        sessionID + counterBE(counter, width: 8)
    }

    /// Encrypt a command payload → full BLE write bytes `[cmd:2][nonce_full:16][ciphertext][tag:12]`.
    /// CCM nonce = `nonce_full[3...]` (13 bytes); AAD = the 2 command bytes; plaintext = `[len:1][payload]`.
    static func encryptCommand(sessionKey: [UInt8], sessionID: [UInt8], counter: UInt64,
                               cmd: [UInt8], payload: [UInt8]) throws -> [UInt8] {
        let nonceFull = fullNonce(sessionID: sessionID, counter: counter)
        let ccmNonce = Array(nonceFull[3...])
        let plaintext = [UInt8(payload.count)] + payload
        let ccm = CCM(iv: ccmNonce, tagLength: tagLength, messageLength: plaintext.count, additionalAuthenticatedData: cmd)
        let ctAndTag = try AES(key: sessionKey, blockMode: ccm, padding: .noPadding).encrypt(plaintext)
        // CryptoSwift returns ciphertext with the tag appended, matching the wire layout.
        return cmd + nonceFull + ctAndTag
    }

    /// Decrypt an encrypted response `[cmd:2][nonce_full:16][ciphertext][tag:12]` → `(cmdCode, payload)`.
    static func decryptResponse(sessionKey: [UInt8], raw: [UInt8]) throws -> (cmd: UInt16, payload: [UInt8]) {
        let minLen = 2 + 16 + 1 + tagLength
        guard raw.count >= minLen else { throw CryptoFailure.badLength("encrypted response \(raw.count) < \(minLen)") }
        let cmdBytes = Array(raw[0..<2])
        let cmdCode = (UInt16(cmdBytes[0]) << 8) | UInt16(cmdBytes[1])   // big-endian command code
        let nonceFull = Array(raw[2..<18])
        let ctAndTag = Array(raw[18...])
        let ccmNonce = Array(nonceFull[3...])
        let ccm = CCM(iv: ccmNonce, tagLength: tagLength, messageLength: ctAndTag.count - tagLength, additionalAuthenticatedData: cmdBytes)
        let decrypted: [UInt8]
        do {
            decrypted = try AES(key: sessionKey, blockMode: ccm, padding: .noPadding).decrypt(ctAndTag)
        } catch {
            throw CryptoFailure.decryptFailed
        }
        guard let lenByte = decrypted.first else { throw CryptoFailure.badLength("empty plaintext") }
        let payloadLen = Int(lenByte)
        guard decrypted.count >= 1 + payloadLen else { throw CryptoFailure.badLength("plaintext len prefix > body") }
        return (cmdCode, Array(decrypted[1..<(1 + payloadLen)]))
    }
}
