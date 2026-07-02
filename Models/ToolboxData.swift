import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Website resource models

enum ToolboxScalar: Codable, Hashable {
    case string(String)

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let value = try? box.decode(String.self) { self = .string(value); return }
        if let value = try? box.decode(Int.self) { self = .string(String(value)); return }
        if let value = try? box.decode(Double.self) { self = .string(String(value)); return }
        if let value = try? box.decode(Bool.self) { self = .string(value ? "1" : "0"); return }
        if box.decodeNil() { self = .string(""); return }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath,
                                                             debugDescription: "Unsupported preset value"))
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(value)
    }

    var value: String {
        switch self { case .string(let value): value }
    }
}

typealias ToolboxFields = [String: ToolboxScalar]

struct ToolboxPresetCatalog: Decodable {
    let driverBoards: [ToolboxBoard]
    let displays: [ToolboxDisplay]
    let powerOptions: [ToolboxPower]
}

struct ToolboxInstallConfig: Decodable {
    let type: String?
    let manifest: String?
    let downloadFile: String?
    let firmwareLetter: String?
    let githubRepo: String?
}

struct ToolboxExtraPacket: Decodable {
    let pid: String
    let fields: ToolboxFields
}

struct ToolboxBoard: Decodable, Identifiable {
    let id: String
    let name: String
    let connectorPins: [Int]
    let systemConfig: ToolboxFields
    let manufacturerData: ToolboxFields
    let displayPins: ToolboxFields?
    let powerDefaults: ToolboxFields?
    let led: ToolboxFields?
    let buttons: ToolboxFields?
    let dataBus: ToolboxFields?
    let nfcConfig: ToolboxFields?
    let flashConfig: ToolboxFields?
    let touchController: ToolboxFields?
    let buzzerConfig: ToolboxFields?
    let sensorData: ToolboxFields?
    let extraPackets: [ToolboxExtraPacket]?
    let defaultDisplay: String?
    let defaultPower: String?
    let installConfig: ToolboxInstallConfig?
    let transmission_modes: ToolboxScalar?
    let index: Int?
}

struct ToolboxDisplay: Decodable, Identifiable {
    let id: String
    let name: String
    let connectorPins: [Int]
    let panelIcType: ToolboxScalar
    let config: ToolboxFields
    let index: Int?
}

struct ToolboxPower: Decodable, Identifiable {
    let id: String
    let name: String
    let powerOption: ToolboxFields
    let index: Int?
}

enum ToolboxFieldSize: Decodable {
    case fixed(Int)
    case variable

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let value = try? box.decode(Int.self) { self = .fixed(value); return }
        let value = try box.decode(String.self)
        self = Int(value).map(Self.fixed) ?? .variable
    }

    var byteCount: Int? {
        if case .fixed(let count) = self { return count }
        return nil
    }
}

struct ToolboxNamedValue: Decodable {
    let name: String
    let description: String?

    enum CodingKeys: String, CodingKey { case name, description }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? box.decode(String.self, forKey: .name) {
            name = value
        } else if let value = try? box.decode(Bool.self, forKey: .name) {
            name = value ? "true" : "false"
        } else if let value = try? box.decode(Int.self, forKey: .name) {
            name = String(value)
        } else {
            name = "Unknown"
        }
        description = try box.decodeIfPresent(String.self, forKey: .description)
    }
}

struct ToolboxConditionalChoices: Decodable {
    let dependsOn: String
    let values: [String: [String: ToolboxNamedValue]]

    enum CodingKeys: String, CodingKey {
        case dependsOn = "depends_on"
        case values
    }
}

struct ToolboxFieldDefinition: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let size: ToolboxFieldSize
    let description: String?
    let choices: [String: ToolboxNamedValue]?
    let conditionalChoices: ToolboxConditionalChoices?
    let bits: [String: ToolboxNamedValue]?

    enum CodingKeys: String, CodingKey {
        case name, size, description, bits
        case choices = "enum"
        case conditionalChoices = "conditional_enum"
    }
}

struct ToolboxPacketDefinition: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let required: Bool?
    let repeatable: Bool?
    let description: String?
    let fields: [ToolboxFieldDefinition]

    var fixedPayloadLength: Int { fields.compactMap(\.size.byteCount).reduce(0, +) }
}

struct ToolboxSchema: Decodable {
    let version: Int
    let minorVersion: Int
    let packetTypes: [String: ToolboxPacketDefinition]

    enum CodingKeys: String, CodingKey {
        case version
        case minorVersion = "minor_version"
        case packetTypes = "packet_types"
    }
}

private struct ToolboxSchemaEnvelope: Decodable {
    let schema: ToolboxSchema
    enum CodingKeys: String, CodingKey { case schema = "ble_proto" }
}

enum ToolboxResources {
    static let catalog: ToolboxPresetCatalog = load("simple-config-presets", as: ToolboxPresetCatalog.self)
    static let schema: ToolboxSchema = load("toolbox-schema", as: ToolboxSchemaEnvelope.self).schema
    static let schemaText: String = {
        guard let url = Bundle.main.url(forResource: "toolbox-schema", withExtension: "json"),
              let value = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return value
    }()

    private static func load<T: Decodable>(_ name: String, as type: T.Type) -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            fatalError("Missing or invalid bundled Toolbox resource: \(name).json")
        }
        return value
    }

    static func decodeSchema(_ text: String) throws -> ToolboxSchema {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(ToolboxSchemaEnvelope.self, from: data).schema
    }
}

// MARK: - Configuration document

struct ToolboxPacket: Identifiable, Codable, Equatable {
    var uuid = UUID()
    var id: UUID { uuid }
    var packetType: Int
    var fields: [String: String]

    enum CodingKeys: String, CodingKey { case packetType = "id", fields }

    init(uuid: UUID = UUID(), packetType: Int, fields: [String: String] = [:]) {
        self.uuid = uuid
        self.packetType = packetType
        self.fields = fields
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let intID = try? box.decode(Int.self, forKey: .packetType) {
            packetType = intID
        } else {
            packetType = Int(try box.decode(String.self, forKey: .packetType)) ?? 0
        }
        if let strings = try? box.decode([String: String].self, forKey: .fields) {
            fields = strings
        } else {
            fields = (try box.decodeIfPresent([String: ToolboxScalar].self, forKey: .fields) ?? [:])
                .mapValues(\.value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(String(packetType), forKey: .packetType)
        try box.encode(fields, forKey: .fields)
    }
}

struct ToolboxConfiguration: Codable, Equatable {
    var version: Int = 1
    var minorVersion: Int = 2
    var packets: [ToolboxPacket] = []
    var exportedAt: Date?
    var exportedBy: String?
    /// Byte-for-byte tail beginning at an unknown packet. Preserved so newer/legacy firmware
    /// extensions survive a read-edit-write cycle even when this app cannot interpret them.
    var unknownPacketTail = Data()

    enum CodingKeys: String, CodingKey {
        case version, packets
        case minorVersion = "minor_version"
        case exportedAt = "exported_at"
        case exportedBy = "exported_by"
    }

    mutating func upsert(_ type: Int, fields: [String: String], instance: String? = nil) {
        if let index = packets.firstIndex(where: {
            $0.packetType == type && (instance == nil || $0.fields["instance_number"] == instance)
        }) {
            packets[index].fields = fields
        } else {
            packets.append(ToolboxPacket(packetType: type, fields: fields))
        }
    }

    mutating func remove(type: Int, autoSecurityOnly: Bool = false) {
        packets.removeAll { $0.packetType == type }
    }
}

enum ToolboxCodecError: LocalizedError {
    case invalidLength, invalidCRC, unknownPacket(Int), truncatedPacket, invalidSchema(String)

    var errorDescription: String? {
        switch self {
        case .invalidLength: "The Toolbox packet length is invalid."
        case .invalidCRC: "The Toolbox packet CRC does not match."
        case .unknownPacket(let id): "Packet type \(id) is not present in the schema."
        case .truncatedPacket: "The Toolbox packet is incomplete."
        case .invalidSchema(let message): "Invalid schema: \(message)"
        }
    }
}

enum ToolboxPacketCodec {
    static func encode(_ config: ToolboxConfiguration, schema: ToolboxSchema = ToolboxResources.schema) throws -> Data {
        var outer = Data([0, 0, UInt8(clamping: config.version)])
        for (sequence, packet) in config.packets.enumerated() {
            guard let definition = schema.packetTypes[String(packet.packetType)] else {
                throw ToolboxCodecError.unknownPacket(packet.packetType)
            }
            outer.append(UInt8(clamping: sequence))
            outer.append(UInt8(clamping: packet.packetType))
            for field in definition.fields {
                guard let size = field.size.byteCount else {
                    throw ToolboxCodecError.invalidSchema("Variable field \(field.name) is not supported inside a packet")
                }
                outer.append(encodeField(packet.fields[field.name] ?? "", name: field.name, size: size))
            }
        }
        outer.append(config.unknownPacketTail)

        // Firmware computes CRC while the length bytes are zero, then patches total length.
        let crc = toolboxCRC16CCITT(outer)
        let totalLength = UInt16(clamping: outer.count + 2)
        outer[0] = UInt8(totalLength & 0xff)
        outer[1] = UInt8(totalLength >> 8)
        outer.append(UInt8(crc & 0xff))
        outer.append(UInt8(crc >> 8))
        return outer
    }

    static func decode(_ data: Data, schema: ToolboxSchema = ToolboxResources.schema) throws -> ToolboxConfiguration {
        guard data.count >= 5 else { throw ToolboxCodecError.invalidLength }
        let declared = Int(data[0]) | Int(data[1]) << 8
        guard declared == data.count else { throw ToolboxCodecError.invalidLength }
        let storedCRC = UInt16(data[data.count - 2]) | UInt16(data[data.count - 1]) << 8
        var crcInput = Data(data.dropLast(2))
        crcInput[0] = 0
        crcInput[1] = 0
        guard toolboxCRC16CCITT(crcInput) == storedCRC else { throw ToolboxCodecError.invalidCRC }

        var config = ToolboxConfiguration(version: Int(data[2]), minorVersion: schema.minorVersion)
        var offset = 3
        while offset < data.count - 2 {
            guard offset + 2 <= data.count - 2 else { throw ToolboxCodecError.truncatedPacket }
            let type = Int(data[offset + 1])
            offset += 2 // sequence byte is intentionally regenerated when writing
            guard let definition = schema.packetTypes[String(type)] else {
                // Packet sizes are schema-defined, so an unknown packet cannot be safely skipped.
                // Preserve this packet and the remaining tail verbatim, then publish all known
                // packets decoded before it (including the display packet).
                config.unknownPacketTail = Data(data[(offset - 2)..<(data.count - 2)])
                break
            }
            var values: [String: String] = [:]
            for field in definition.fields {
                guard let count = field.size.byteCount, offset + count <= data.count - 2 else {
                    throw ToolboxCodecError.truncatedPacket
                }
                let bytes = Data(data[offset ..< offset + count])
                values[field.name] = decodeField(bytes, name: field.name)
                offset += count
            }
            config.packets.append(ToolboxPacket(packetType: type, fields: values))
        }
        return config
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func encodeField(_ raw: String, name: String, size: Int) -> Data {
        if name == "ssid" || name == "password" {
            var result = Data(raw.utf8.prefix(size))
            if result.count < size { result.append(Data(repeating: 0, count: size - result.count)) }
            return result
        }
        if name == "encryption_key" {
            var result = Data(toolboxHexBytes(raw).prefix(size))
            if result.count < size { result.append(Data(repeating: 0, count: size - result.count)) }
            return result
        }
        let value = toolboxInteger(raw)
        var result = Data(count: size)
        for index in 0..<min(size, 8) { result[index] = UInt8((value >> UInt64(index * 8)) & 0xff) }
        return result
    }

    private static func decodeField(_ bytes: Data, name: String) -> String {
        if name == "ssid" || name == "password" {
            let content = bytes.prefix { $0 != 0 }
            return String(data: Data(content), encoding: .utf8) ?? ""
        }
        if name == "encryption_key" {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        var value: UInt64 = 0
        for (index, byte) in bytes.prefix(8).enumerated() { value |= UInt64(byte) << UInt64(index * 8) }
        return value == 0 ? "0x0" : String(value)
    }
}

private func toolboxInteger(_ raw: String) -> UInt64 {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("0x") { return UInt64(value.dropFirst(2), radix: 16) ?? 0 }
    return UInt64(value) ?? 0
}

private func toolboxCRC16CCITT(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xffff
    for byte in data {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

private func toolboxHexBytes(_ raw: String) -> [UInt8] {
    let clean = raw.filter(\.isHexDigit)
    guard clean.count.isMultiple(of: 2) else { return [] }
    return stride(from: 0, to: clean.count, by: 2).compactMap { offset in
        let start = clean.index(clean.startIndex, offsetBy: offset)
        let end = clean.index(start, offsetBy: 2)
        return UInt8(clean[start..<end], radix: 16)
    }
}

// MARK: - Simple configuration builder

enum ToolboxConfigurationBuilder {
    static func build(board: ToolboxBoard, display: ToolboxDisplay, power: ToolboxPower,
                      deepSleepSeconds: Int, encryptionKey: String?) -> ToolboxConfiguration {
        let catalog = ToolboxResources.catalog
        var result = ToolboxConfiguration(version: ToolboxResources.schema.version,
                                          minorVersion: ToolboxResources.schema.minorVersion)
        result.upsert(1, fields: strings(board.systemConfig))

        var manufacturer = strings(board.manufacturerData)
        manufacturer["simple_config_driver_index"] = String(board.index ?? index(of: board.id, in: catalog.driverBoards.map(\.id)))
        manufacturer["simple_config_display_index"] = String(display.index ?? index(of: display.id, in: catalog.displays.map(\.id)))
        manufacturer["simple_config_power_index"] = String(power.index ?? index(of: power.id, in: catalog.powerOptions.map(\.id)))
        manufacturer["simple_config_configured_at"] = String(Int(Date().timeIntervalSince1970))
        result.upsert(2, fields: manufacturer)

        var powerFields = strings(power.powerOption)
        if powerFields["power_mode"] != "2", let defaults = board.powerDefaults {
            for (key, value) in strings(defaults) { powerFields[key] = value }
        }
        if board.installConfig?.type == "esp32" {
            powerFields["deep_sleep_time_seconds"] = String(max(0, min(43_200, deepSleepSeconds)))
        }
        result.upsert(4, fields: powerFields)

        var displayFields = strings(display.config)
        displayFields["instance_number"] = "0x0"
        displayFields["display_technology"] = "1"
        displayFields["panel_ic_type"] = display.panelIcType.value
        displayFields["legacy_tagtype"] = "0x0"
        displayFields["rotation"] = "0"
        displayFields["transmission_modes"] = board.transmission_modes?.value ?? "10"
        let pins = board.displayPins.map(strings) ?? [:]
        displayFields["reset_pin"] = pins["reset"] ?? "0xff"
        displayFields["busy_pin"] = pins["busy"] ?? "0xff"
        displayFields["dc_pin"] = pins["dc"] ?? "0xff"
        displayFields["cs_pin"] = pins["cs"] ?? "0xff"
        displayFields["data_pin"] = pins["data"] ?? "0x0"
        displayFields["clk_pin"] = pins["clk"] ?? "0x0"
        result.upsert(32, fields: displayFields, instance: "0x0")

        add(board.led, type: 33, to: &result)
        add(board.sensorData, type: 35, to: &result)
        add(board.dataBus, type: 36, to: &result)
        add(board.buttons, type: 37, to: &result)
        add(board.touchController, type: 40, to: &result)
        add(board.buzzerConfig, type: 41, to: &result)
        add(board.nfcConfig, type: 42, to: &result)
        add(board.flashConfig, type: 43, to: &result)
        board.extraPackets?.forEach {
            result.upsert(Int($0.pid) ?? 0, fields: strings($0.fields),
                          instance: $0.fields["instance_number"]?.value)
        }

        if let key = encryptionKey, key.count == 32 {
            result.upsert(39, fields: [
                "encryption_enabled": "1", "encryption_key": key,
                "session_timeout_seconds": "0", "flags": "2", "reset_pin": "0xff"
            ])
        }
        return result
    }

    private static func add(_ fields: ToolboxFields?, type: Int, to config: inout ToolboxConfiguration) {
        guard let fields else { return }
        config.upsert(type, fields: strings(fields), instance: fields["instance_number"]?.value)
    }

    private static func strings(_ values: ToolboxFields) -> [String: String] {
        values.mapValues(\.value)
    }

    private static func index(of id: String, in ids: [String]) -> Int {
        (ids.firstIndex(of: id) ?? -1) + 1
    }
}

private func strings(_ values: ToolboxFields) -> [String: String] { values.mapValues(\.value) }

// MARK: - Import / export documents

struct ToolboxJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension JSONEncoder {
    static var toolbox: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var toolbox: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
