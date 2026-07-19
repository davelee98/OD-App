import Foundation
import CoreBluetooth

enum AppInfo {
    /// Marketing version (`CFBundleShortVersionString`, i.e. `MARKETING_VERSION`) read from the app
    /// bundle, so the About screen always matches the shipped build instead of a hand-edited literal.
    static let version: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }()
}

enum OD {
    static let serviceUUID        = CBUUID(string: "2446")
    static let characteristicUUID = CBUUID(string: "2446")
    /// Advertised-name prefixes recognized as OpenDisplay devices (matched case-insensitively).
    /// Kept to "OD" on purpose: board variants (reTerminal/Hanshow/Solum) running OD firmware are
    /// admitted via the service-UUID or manufacturer-data signals instead, so stock ESLs from
    /// those vendors don't false-positive.
    static let namePrefixes: [String] = ["OD"]
    static let bleChunkSize       = 230
    /// Chunk size for chunked config writes. Derived from the canonical wire contract
    /// `CONFIG_CHUNK_SIZE` (`Generated/opendisplay_protocol.swift`); ble-common.js's
    /// `writeConfigChunked` mirrors the same value, and `ODDevice.writeConfig` predicts its
    /// expected ACK count from it. `BLEChunkSizeTests` pins it to the bundled JS, tying Swift,
    /// the generated contract, and the JS to one value. Distinct from `bleChunkSize`, which
    /// governs image-data transport chunks.
    static let configWriteChunkSize = Int(CONFIG_CHUNK_SIZE)

    /// Wire command opcodes. Raw values mirror the canonical `CMD_*` constants in the vendored
    /// `Generated/opendisplay_protocol.swift` (Swift enum raw values must be literals, so they can't
    /// reference the `let`s directly) — `ProtocolOpcodeTests` pins every case to its generated
    /// constant so this can't silently drift from the protocol source of truth again.
    enum Cmd: UInt16 {
        case reboot            = 0x000F
        case readConfig        = 0x0040
        case writeConfigFirst  = 0x0041
        case writeConfigChunk  = 0x0042
        case readFirmware      = 0x0043
        case readMSD           = 0x0044
        case authenticate      = 0x0050
        case enterDFU          = 0x0051
        case deepSleep         = 0x0052
        case imageStart        = 0x0070
        case imageData         = 0x0071
        case imageEnd          = 0x0072
        case ledPattern        = 0x0073
        case ledStop           = 0x0075
        case partialUpdate     = 0x0076
        case buzzer            = 0x0077
        case nfc               = 0x0083  // CMD_NFC_ENDPOINT; was 0x0082 (now CMD_PIPE_WRITE_END) — stale pre-v2.0

        var header: Data {
            Data([UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)])
        }

        var displayName: String {
            switch self {
            case .reboot:           return "Reboot (0x000F)"
            case .readConfig:       return "Read Config (0x0040)"
            case .writeConfigFirst: return "Write Config First (0x0041)"
            case .writeConfigChunk: return "Write Config Chunk (0x0042)"
            case .readFirmware:     return "Read Firmware (0x0043)"
            case .readMSD:          return "Read MSD (0x0044)"
            case .authenticate:     return "Authenticate (0x0050)"
            case .enterDFU:         return "Enter DFU (0x0051)"
            case .deepSleep:        return "Deep Sleep (0x0052)"
            case .imageStart:       return "Image Start (0x0070)"
            case .imageData:        return "Image Data (0x0071)"
            case .imageEnd:         return "Image End (0x0072)"
            case .ledPattern:       return "LED Pattern (0x0073)"
            case .ledStop:          return "LED Stop (0x0075)"
            case .partialUpdate:    return "Partial Update (0x0076)"
            case .buzzer:           return "Buzzer (0x0077)"
            case .nfc:              return "NFC (0x0083)"
            }
        }
    }

    static let allCommands: [Cmd] = [
        .readFirmware, .readMSD, .readConfig, .authenticate,
        .imageStart, .imageData, .imageEnd, .partialUpdate,
        .ledPattern, .ledStop, .buzzer, .nfc,
        .enterDFU, .deepSleep, .reboot
    ]
}

enum ConnectionState: Equatable {
    case disconnected, connecting, connected, failed
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let direction: Direction
    let data: Data
    let label: String?

    enum Direction { case sent, received, system }

    var hexString: String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var commandName: String? {
        guard data.count >= 2 else { return nil }
        let opcode = UInt16(data[0]) << 8 | UInt16(data[1])
        return OD.Cmd(rawValue: opcode)?.displayName
    }
}

// MARK: - Color Scheme

enum ColorScheme: UInt8, CaseIterable, Identifiable {
    case blackWhite        = 0
    case blackWhiteRed     = 1
    case blackWhiteYellow  = 2
    case blackWhiteRedYellow = 3
    case sixColor          = 4
    case fourGray          = 5
    case sixteenGray       = 6

    var id: UInt8 { rawValue }

    var displayName: String {
        switch self {
        case .blackWhite:          return "Black & White"
        case .blackWhiteRed:       return "B/W + Red"
        case .blackWhiteYellow:    return "B/W + Yellow"
        case .blackWhiteRedYellow: return "B/W + Red + Yellow"
        case .sixColor:            return "6-Color"
        case .fourGray:            return "4-Grayscale"
        case .sixteenGray:         return "16-Grayscale"
        }
    }

    var bitsPerPixel: Int {
        switch self {
        case .blackWhite:          return 1
        case .blackWhiteRed:       return 1  // 2 bitplanes of 1bpp
        case .blackWhiteYellow:    return 1  // 2 bitplanes of 1bpp
        case .blackWhiteRedYellow: return 2
        case .sixColor:            return 4
        case .fourGray:            return 2
        case .sixteenGray:         return 4
        }
    }
}
