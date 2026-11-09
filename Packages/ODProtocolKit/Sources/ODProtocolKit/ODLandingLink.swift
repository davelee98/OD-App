import Foundation

/// A device's own on-screen QR code, decoded.
///
/// OpenDisplay firmware renders a deep link of the form
///
///     https://opendisplay.org/l/?<base64url(23 bytes)>
///
///     offset  size  field
///     0       2     tag_type         u16 BE
///     2       3     device id        == the "OD######" advertised name
///     5       16    AES key          all-zero when the device has no key, or hides it
///     21      2     manufacturer_id  u16 BE
///
/// Mirrors `py-opendisplay/src/opendisplay/landing.py` (`parse_landing_url`), the source of truth
/// for this layout, and the OD-Badge app's `LandingLink`.
public struct ODLandingLink: Equatable {
    public let tagType: UInt16
    public let deviceID: Data          // 3 bytes
    /// nil when the QR carries an all-zero key: encryption off, or the "show key on screen"
    /// security flag is off. The QR alone can't tell which.
    public let encryptionKey: Data?
    public let manufacturerID: UInt16

    /// The advertised BLE name, e.g. `OD507E1C`.
    public var deviceName: String {
        "OD" + deviceID.map { String(format: "%02X", $0) }.joined()
    }

    static let payloadSize = 23
    private static let hosts: Set<String> = ["opendisplay.org", "www.opendisplay.org"]
    private static let paths: Set<String> = ["/l", "/l/"]

    /// Decode a scanned or pasted landing link. Tolerates surrounding whitespace, `http://`, a
    /// missing scheme, a missing trailing slash on `/l` and re-added `=` padding.
    public static func parse(_ text: String) -> ODLandingLink? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://"), !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), hosts.contains(host),
              paths.contains(components.path),
              let query = components.percentEncodedQuery, !query.isEmpty
        else { return nil }

        var encoded = query
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder > 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let payload = Data(base64Encoded: encoded) else { return nil }
        return parse(payload: payload)
    }

    /// Decode the raw 23-byte identity payload.
    public static func parse(payload: Data) -> ODLandingLink? {
        let bytes = [UInt8](payload)
        guard bytes.count == payloadSize else { return nil }
        let key = Data(bytes[5..<21])
        return ODLandingLink(
            tagType: UInt16(bytes[0]) << 8 | UInt16(bytes[1]),
            deviceID: Data(bytes[2..<5]),
            encryptionKey: key.allSatisfy { $0 == 0 } ? nil : key,
            manufacturerID: UInt16(bytes[21]) << 8 | UInt16(bytes[22])
        )
    }

    /// Whether this link names `advertisedName` (case-insensitive). A nil/empty name can't be
    /// checked and is treated as a match, so a peripheral without a cached GAP name isn't refused.
    public func matches(advertisedName: String?) -> Bool {
        guard let advertisedName, !advertisedName.isEmpty else { return true }
        return advertisedName.caseInsensitiveCompare(deviceName) == .orderedSame
    }
}

/// What a user typed, pasted or scanned into a "display key" field.
public enum ODKeyEntry: Equatable {
    /// A raw 16-byte AES key (32 hex characters; spaces, colons, dashes and `0x` are ignored).
    case key(Data)
    /// A landing link from the device's on-screen QR code.
    case link(ODLandingLink)

    public static func parse(_ text: String) -> ODKeyEntry? {
        if let link = ODLandingLink.parse(text) { return .link(link) }
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        hex.removeAll { $0 == " " || $0 == ":" || $0 == "-" || $0 == "\n" || $0 == "\t" }
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return .key(Data(bytes))
    }
}
