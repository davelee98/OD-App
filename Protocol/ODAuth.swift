import Foundation
import Security
import os

/// Native credential storage only.
///
/// The handshake and session encryption live in `ODProtocolKit` on the native path (and in the
/// verbatim `ble-common.js` on the `-ODUseJSUpload` fallback); this type only holds the key.
///
/// The account key is the CoreBluetooth peripheral UUID, which is a *local reconnect/cache key*,
/// not a durable device identity — it is assigned per iOS host and changes on reinstall, restore,
/// or migration. So a restored entity may reference an unreachable id and a restored Keychain item
/// may be orphaned. Never re-associate a key with a newly-seen UUID by matching display name.
struct ODAuth {
    private static let log = ODLog.auth

    /// - Returns: whether the key is actually stored. Callers that report success to the user must
    ///   check this: silently failing here means the next connect prompts again for a key the user
    ///   believes they already saved.
    @discardableResult
    static func savePSK(_ psk: Data, forDevice deviceID: String) -> Bool {
        // Update in place when an entry exists, rather than delete-then-add. The old sequence
        // destroyed a perfectly good credential first, so a failing add left the display with no
        // key at all — worse than having kept the previous one.
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: deviceID,
            kSecAttrService: "com.opendisplay.psk",
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary,
                                         [kSecValueData: psk] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            log.error("savePSK: SecItemUpdate failed with status \(updateStatus)")
            return false
        }

        var addQuery = identity
        addQuery[kSecValueData] = psk
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            log.error("savePSK: SecItemAdd failed with status \(addStatus)")
            return false
        }
        return true
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
