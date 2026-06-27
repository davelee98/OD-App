import Foundation
import CommonCrypto
import Security
import CryptoSwift

// AES-128-CMAC authentication (RFC 4493) using CommonCrypto's CCCmac
struct ODAuth {

    // MARK: - CMAC

    static func cmac(key: Data, message: Data) -> Data {
        precondition(key.count == 16, "AES-128-CMAC requires a 16-byte key")
        let mac = (try? CMAC(key: [UInt8](key)).authenticate([UInt8](message))) ?? []
        return Data(mac)
    }

    // MARK: - Challenge/Response

    /// challenge_response = AES-128-CMAC(psk, serverNonce ‖ clientNonce ‖ deviceID)
    static func challengeResponse(psk: Data, serverNonce: Data, clientNonce: Data, deviceID: Data) -> Data {
        var message = Data()
        message.append(serverNonce)
        message.append(clientNonce)
        message.append(deviceID)
        return cmac(key: psk, message: message)
    }

    static func randomNonce(length: Int = 16) -> Data {
        var bytes = Data(count: length)
        _ = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!)
        }
        return bytes
    }

    // MARK: - PSK Storage (Keychain)

    static func savePSK(_ psk: Data, forDevice deviceID: String) {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     deviceID,
            kSecAttrService:     "com.opendisplay.psk",
            kSecValueData:       psk,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadPSK(forDevice deviceID: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrAccount:  deviceID,
            kSecAttrService:  "com.opendisplay.psk",
            kSecReturnData:   true,
            kSecMatchLimit:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func deletePSK(forDevice deviceID: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: deviceID,
            kSecAttrService: "com.opendisplay.psk",
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func randomPSK() -> Data { randomNonce(length: 16) }
}

// MARK: - Session Encryption (AES-CCM)
// Requires CryptoSwift: https://github.com/krzyzanowskim/CryptoSwift
// Add via Xcode: File > Add Package Dependencies > https://github.com/krzyzanowskim/CryptoSwift
//
// Encrypted command layout:
//   [cmd_hi][cmd_lo][nonce: 16B][ciphertext][auth_tag: 12B]
// Nonce: 8B session ID || 8B big-endian counter
// AES-CCM; associated data = command bytes only

struct ODSession {
    let sessionID: Data    // 8 bytes
    let sessionKey: Data   // 16 bytes
    private(set) var counter: UInt64 = 0

    mutating func encrypt(command: OD.Cmd, payload: Data) throws -> Data {
        let nonce = buildNonce()
        counter += 1

        let aad = [UInt8](command.header)
        let ccm = CCM(iv: [UInt8](nonce), tagLength: 12, messageLength: payload.count + 1,
                      additionalAuthenticatedData: aad)
        let aes = try AES(key: [UInt8](sessionKey), blockMode: ccm, padding: .noPadding)
        let lengthPrefixed = [UInt8(payload.count)] + [UInt8](payload)
        let ciphertext = try aes.encrypt(lengthPrefixed)

        var packet = command.header
        packet.append(nonce)
        packet.append(Data(ciphertext))
        return packet
    }

    private func buildNonce() -> Data {
        var nonce = sessionID
        var ctr = counter.bigEndian
        nonce.append(Data(bytes: &ctr, count: 8))
        return nonce
    }
}

enum ODError: Error, LocalizedError {
    case encryptionNotImplemented
    case authFailed
    case badResponse
    case crcMismatch
    case timeout

    var errorDescription: String? {
        switch self {
        case .encryptionNotImplemented: return "AES-CCM encryption requires CryptoSwift dependency"
        case .authFailed:               return "Authentication failed"
        case .badResponse:              return "Unexpected response from device"
        case .crcMismatch:              return "Config CRC mismatch"
        case .timeout:                  return "Operation timed out"
        }
    }
}
