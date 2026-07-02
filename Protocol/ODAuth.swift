import Foundation
import Security

/// Native credential storage only. Authentication and session encryption are handled by
/// the verbatim `ble-common.js` implementation in `OpenDisplayJSRuntime`.
struct ODAuth {
    static func savePSK(_ psk: Data, forDevice deviceID: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: deviceID,
            kSecAttrService: "com.opendisplay.psk",
            kSecValueData: psk,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func deletePSK(forDevice deviceID: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: deviceID,
            kSecAttrService: "com.opendisplay.psk",
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func randomPSK() -> Data {
        var bytes = Data(count: 16)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        return status == errSecSuccess ? bytes : Data(repeating: 0, count: 16)
    }
}
