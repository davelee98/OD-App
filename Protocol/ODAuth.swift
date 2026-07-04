import Foundation
import Security
import os

/// Native credential storage only. Authentication and session encryption are handled by
/// the verbatim `ble-common.js` implementation in `OpenDisplayJSRuntime`.
struct ODAuth {
    private static let log = Logger(subsystem: "org.opendisplay.app", category: "auth")

    static func savePSK(_ psk: Data, forDevice deviceID: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: deviceID,
            kSecAttrService: "com.opendisplay.psk",
            kSecValueData: psk,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            log.error("savePSK: SecItemAdd failed with status \(status)")
        }
    }

    static func loadPSK(forDevice deviceID: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: deviceID,
            kSecAttrService: "com.opendisplay.psk",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                log.error("loadPSK: SecItemCopyMatching failed with status \(status)")
            }
            return nil
        }
        return result as? Data
    }

    static func deletePSK(forDevice deviceID: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: deviceID,
            kSecAttrService: "com.opendisplay.psk",
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("deletePSK: SecItemDelete failed with status \(status)")
        }
    }

    /// Generates a cryptographically random 16-byte PSK.
    /// Returns `nil` (never a predictable key) if secure random generation fails.
    static func randomPSK() -> Data? {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            log.error("randomPSK: SecRandomCopyBytes failed with status \(status)")
            return nil
        }
        return bytes
    }
}
