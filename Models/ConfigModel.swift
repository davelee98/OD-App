import Foundation
import ODProtocolKit

/// Native representation of the same schema-driven configuration used by the web Toolbox.
///
/// Config packets are decoded by the JS Toolbox engine into `ToolboxPacket` (a packet-type code +
/// string fields), so this is a thin typed accessor over those fields — it does **not** parse the
/// generated packed config structs natively. Packet-type codes come from the generated
/// `ConfigPacketType` (`Generated/opendisplay_structs.swift`) rather than magic numbers.
struct ODConfigModel: Equatable {
    var toolbox: ToolboxConfiguration

    init(toolbox: ToolboxConfiguration = ToolboxConfiguration()) {
        self.toolbox = toolbox
    }

    var version: UInt8 {
        get { UInt8(clamping: toolbox.version) }
        set { toolbox.version = Int(newValue) }
    }

    var displayWidth: Int {
        get { integer(.display, field: "pixel_width") }
        set { set(.display, field: "pixel_width", value: String(newValue)) }
    }

    var displayHeight: Int {
        get { integer(.display, field: "pixel_height") }
        set { set(.display, field: "pixel_height", value: String(newValue)) }
    }

    var colorScheme: UInt8 {
        get { UInt8(clamping: integer(.display, field: "color_scheme")) }
        set { set(.display, field: "color_scheme", value: String(newValue)) }
    }

    var refreshMode: UInt8 {
        get { UInt8(clamping: integer(.display, field: "partial_update_support")) }
        set { set(.display, field: "partial_update_support", value: String(newValue)) }
    }

    /// Bitfield reported by the device (bits are `TransmissionModes`): bit0 = streaming decompression
    /// support, bit1 = zip support. Image uploads may only be deflate-compressed (with a sized Image
    /// Start header) when both bits are set — otherwise the device expects a bare Image Start opcode
    /// followed by raw pixel chunks. Returned as the raw byte because it's forwarded to the JS layer.
    var transmissionModes: UInt8 {
        UInt8(clamping: integer(.display, field: "transmission_modes"))
    }

    var deepSleepEnabled: Bool {
        get { integer(.power, field: "deep_sleep_time_seconds") > 0 }
        set { set(.power, field: "deep_sleep_time_seconds", value: newValue ? "60" : "0") }
    }

    var displayWidthMM: Int {
        integer(.display, field: "active_width_mm")
    }

    var displayHeightMM: Int {
        integer(.display, field: "active_height_mm")
    }

    var displayDiagonalInches: Double? {
        let w = displayWidthMM
        let h = displayHeightMM
        guard w > 0, h > 0 else { return nil }
        let diagMM = sqrt(Double(w * w + h * h))
        return (diagMM / 25.4 * 10).rounded() / 10
    }

    var colorSchemeName: String {
        switch colorScheme {
        case 0: return "B/W"
        case 1: return "B/W/R"
        case 2: return "B/W/Y"
        case 3: return "B/W/R/Y"
        case 4: return "6-Color"
        case 5: return "4-Gray"
        case 6: return "16-Gray"
        case 7: return "7-Color"
        case 100: return "RGB565"
        case 101: return "RGB888"
        default: return "Scheme \(colorScheme)"
        }
    }

    var batteryMSDByteIndex: Int? {
        ODAdvertisementLayout(config: self).bq27220StartByte
    }

    var pskHex: String {
        get { value(.security, field: "encryption_key") ?? "" }
        set {
            if newValue.isEmpty {
                toolbox.remove(type: Int(ConfigPacketType.security.rawValue))
            } else {
                set(.security, field: "encryption_enabled", value: "1")
                set(.security, field: "encryption_key", value: newValue)
                set(.security, field: "flags", value: "2")
                set(.security, field: "reset_pin", value: "0xff")
            }
        }
    }

    private func value(_ type: ConfigPacketType, field: String) -> String? {
        toolbox.packets.first(where: { $0.packetType == Int(type.rawValue) })?.fields[field]
    }

    private func integer(_ type: ConfigPacketType, field: String) -> Int {
        let raw = value(type, field: field) ?? "0"
        if raw.lowercased().hasPrefix("0x") { return Int(raw.dropFirst(2), radix: 16) ?? 0 }
        return Int(raw) ?? 0
    }

    private mutating func set(_ type: ConfigPacketType, field: String, value: String) {
        let code = Int(type.rawValue)
        if let index = toolbox.packets.firstIndex(where: { $0.packetType == code }) {
            toolbox.packets[index].fields[field] = value
        } else {
            toolbox.packets.append(ToolboxPacket(packetType: code, fields: [field: value]))
        }
    }
}
