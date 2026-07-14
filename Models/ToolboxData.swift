import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os

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

/// Presets that carry an explicit catalog `index` — the value `build_simple` writes into the
/// manufacturer packet's `simple_config_*_index` fields (see `presetIndex` in
/// `toolbox-config-engine.js`). Read-back must invert that mapping through `index`, not list
/// position, or every preset whose `index` ≠ position mis-resolves.
protocol ToolboxIndexedPreset: Identifiable where ID == String {
    var index: Int? { get }
}

extension ToolboxBoard: ToolboxIndexedPreset {}
extension ToolboxDisplay: ToolboxIndexedPreset {}
extension ToolboxPower: ToolboxIndexedPreset {}

extension Array where Element: ToolboxIndexedPreset {
    /// The stored `simple_config_*_index` value for `item` — a mirror of `presetIndex` in
    /// `toolbox-config-engine.js`: the preset's explicit catalog `index`, or its 1-based list
    /// position when it has none.
    func presetIndex(for item: Element) -> Int {
        if let index = item.index { return index }
        return (firstIndex { $0.id == item.id } ?? -1) + 1
    }

    /// Inverse of `presetIndex`: the preset id a stored `simple_config_*_index` value refers to.
    /// Resolves by the explicit catalog `index` (falling back to list position for presets that
    /// lack one) rather than treating the number as a raw list position. First match wins, keeping
    /// read-back deterministic for the three displays that share `index: 33` in
    /// `simple-config-presets.json` — a Resources-side data duplication Swift cannot disambiguate.
    func id(forPresetIndex index: Int) -> Element.ID? {
        first { presetIndex(for: $0) == index }?.id
    }
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
    let type: String?
    let choices: [String: ToolboxNamedValue]?
    let conditionalChoices: ToolboxConditionalChoices?
    let bits: [String: ToolboxNamedValue]?

    enum CodingKeys: String, CodingKey {
        case name, size, description, type, bits
        case choices = "enum"
        case conditionalChoices = "conditional_enum"
    }

    /// Mirrors `encodeField`/`decodeField` in the bundled toolbox-config-engine.js: `ssid`
    /// and `password` are fixed-size zero-padded strings even though the schema does not
    /// tag them `type: text`. The bundled Resources are read-only, so the rule is repeated
    /// here — it must stay identical to the engine's special case.
    var isTextField: Bool {
        type == "text" || name == "ssid" || name == "password"
    }

    /// Maximum UTF-8 content bytes the engine keeps for a fixed-size text field: `size - 1`,
    /// reserving the trailing null terminator (a 32-byte field holds at most 31 content
    /// bytes). `nil` for non-text or variable-size fields.
    var maxTextContentBytes: Int? {
        guard isTextField, let bytes = size.byteCount else { return nil }
        return max(0, bytes - 1)
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

enum ToolboxResources {
    static let catalog: ToolboxPresetCatalog = load("simple-config-presets", as: ToolboxPresetCatalog.self)
    static var schema: ToolboxSchema { (try? ToolboxConfigRuntime.shared.schema()) ?? fallbackSchema }
    static var schemaText: String { ToolboxConfigRuntime.shared.schemaText }

    private static let fallbackSchema = ToolboxSchema(version: 1, minorVersion: 0, packetTypes: [:])

    private static func load<T: Decodable>(_ name: String, as type: T.Type) -> T {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            ODLog.toolbox.critical("Missing or invalid bundled Toolbox resource: \(name, privacy: .public).json")
            fatalError("Missing or invalid bundled Toolbox resource: \(name).json")
        }
        return value
    }

    static func decodeSchema(_ text: String) throws -> ToolboxSchema {
        try ToolboxConfigRuntime.shared.applySchema(text)
    }

    static func resetSchema() throws -> ToolboxSchema { try ToolboxConfigRuntime.shared.resetSchema() }
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

    mutating func remove(type: Int) {
        packets.removeAll { $0.packetType == type }
    }
}

/// Checks the bundled engine's `validationIssues` does not perform, computed in Swift because
/// the bundled Resources are read-only. Over-limit text (typed before the UI enforced limits,
/// or imported) is a warning, not an error — the engine truncates it safely to `size - 1`
/// bytes + null terminator at encode time; this just stops that truncation from being silent.
enum ToolboxSwiftValidation {
    static func issues(for configuration: ToolboxConfiguration,
                       schema: ToolboxSchema) -> [ToolboxValidationIssue] {
        var issues: [ToolboxValidationIssue] = []
        for packet in configuration.packets {
            guard let definition = schema.packetTypes[String(packet.packetType)] else { continue }
            for field in definition.fields {
                if let limit = field.maxTextContentBytes,
                   let value = packet.fields[field.name],
                   value.utf8.count > limit {
                    issues.append(ToolboxValidationIssue(
                        severity: "warning", code: "text_too_long",
                        message: "\(definition.name).\(field.name) exceeds \(limit) bytes and will be truncated"))
                }
                if field.name == "encryption_key", let bytes = field.size.byteCount {
                    let value = packet.fields[field.name] ?? ""
                    let hex = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
                    let isDisabled = hex.isEmpty || hex.allSatisfy { $0 == "0" }
                    if !isDisabled, hex.count != bytes * 2 || !hex.allSatisfy(\.isHexDigit) {
                        issues.append(ToolboxValidationIssue(
                            severity: "warning", code: "key_length",
                            message: "\(definition.name).\(field.name) should be \(bytes * 2) hex characters"))
                    }
                }
            }
        }
        return issues
    }
}

/// Compatibility facade for app code that consumes Toolbox bytes. Encoding and decoding are
/// performed by the YAML-driven JavaScript runtime rather than duplicated in Swift.
enum ToolboxPacketCodec {
    static func encode(_ config: ToolboxConfiguration, schema: ToolboxSchema = ToolboxResources.schema) throws -> Data {
        try ToolboxConfigRuntime.shared.encode(config)
    }

    static func decode(_ data: Data, schema: ToolboxSchema = ToolboxResources.schema) throws -> ToolboxConfiguration {
        try ToolboxConfigRuntime.shared.decode(data)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: - Import / export documents

struct ToolboxJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
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
