import Foundation
import JavaScriptCore
import os

/// Executes the website Toolbox's schema, codec, and simple-preset logic in JavaScriptCore.
/// Swift owns presentation and BLE transport; config.yaml remains the protocol source of truth.
final class ToolboxConfigRuntime {
    static let shared: ToolboxConfigRuntime = {
        do { return try ToolboxConfigRuntime() }
        catch {
            ODLog.toolbox.critical("Could not initialize Toolbox configuration runtime: \(error.localizedDescription, privacy: .public)")
            fatalError("Could not initialize Toolbox configuration runtime: \(error.localizedDescription)")
        }
    }()

    private let context: JSContext
    private let bundledYAML: String

    private init() throws {
        guard let context = JSContext() else { throw RuntimeError.contextCreationFailed }
        self.context = context
        bundledYAML = try Self.resourceString(name: "config", extension: "yaml")

        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in exceptionMessage = exception?.toString() }
        context.evaluateScript("var console = { log: function(){}, warn: function(){}, error: function(){} };")
        try evaluateResource(name: "js-yaml.min")
        try evaluateResource(name: "toolbox-config-engine")
        if let exceptionMessage { throw RuntimeError.javaScript(exceptionMessage) }

        let presets = try Self.resourceString(name: "simple-config-presets", extension: "json")
        _ = try call("initialize", arguments: ["yaml": bundledYAML, "presets_json": presets])
    }

    var schemaText: String {
        (try? call("schema")["yaml"] as? String) ?? bundledYAML
    }

    func schema() throws -> ToolboxSchema {
        let result = try call("schema")
        guard let envelope = result["schema"] as? [String: Any] else {
            throw RuntimeError.invalidResult("Missing schema")
        }
        return try Self.decodeSchema(envelope)
    }

    func applySchema(_ yaml: String) throws -> ToolboxSchema {
        let result = try call("apply_schema", arguments: ["yaml": yaml])
        guard let envelope = result["schema"] as? [String: Any] else {
            throw RuntimeError.invalidResult("Missing parsed schema")
        }
        return try Self.decodeSchema(envelope)
    }

    func resetSchema() throws -> ToolboxSchema { try applySchema(bundledYAML) }

    func encode(_ configuration: ToolboxConfiguration) throws -> Data {
        let object = try configurationObject(configuration)
        let result = try call("encode", arguments: ["configuration": object])
        guard let hex = result["hex"] as? String, let data = Data(hexString: hex) else {
            throw RuntimeError.invalidResult("Invalid encoded bytes")
        }
        return data
    }

    func decode(_ data: Data) throws -> ToolboxConfiguration {
        let result = try call("decode", arguments: ["hex": data.hexStringNoSpaces])
        guard let object = result["configuration"] as? [String: Any] else {
            throw RuntimeError.invalidResult("Missing decoded configuration")
        }
        return try decodeConfiguration(object)
    }

    func buildSimple(boardID: String, displayID: String, powerID: String,
                     deepSleepSeconds: Int, encryptionKey: String?,
                     base: ToolboxConfiguration = ToolboxConfiguration()) throws -> ToolboxConfiguration {
        var arguments: [String: Any] = [
            "board_id": boardID,
            "display_id": displayID,
            "power_id": powerID,
            "deep_sleep_seconds": deepSleepSeconds,
            "configured_at": Int(Date().timeIntervalSince1970),
            "base_config": try configurationObject(base)
        ]
        if let encryptionKey { arguments["encryption_key"] = encryptionKey }
        let result = try call("build_simple", arguments: arguments)
        guard let object = result["configuration"] as? [String: Any] else {
            throw RuntimeError.invalidResult("Missing built configuration")
        }
        return try decodeConfiguration(object)
    }

    func validate(_ configuration: ToolboxConfiguration) throws -> ToolboxValidation {
        let result = try call("validate", arguments: [
            "configuration": try configurationObject(configuration)
        ])
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(ToolboxValidation.self, from: data)
    }

    private func call(_ operation: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        // This context is called synchronously from SwiftUI computed properties (encode/validate
        // are recomputed on nearly every render in Advanced mode) as well as from BLE callbacks
        // (decode, on config read). Tracing entry/exit + duration here pinpoints whether a freeze
        // is this JS call blocking the main thread versus something purely in SwiftUI.
        let start = Date()
        ODLog.toolbox.debug("→ \(operation, privacy: .public) start")
        defer {
            let elapsed = Date().timeIntervalSince(start)
            ODLog.toolbox.debug("← \(operation, privacy: .public) end (\(String(format: "%.3f", elapsed), privacy: .public)s)")
        }
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let json = String(decoding: data, as: UTF8.self)
        guard let value = context.objectForKeyedSubscript("__odToolboxCall")?.call(withArguments: [operation, json]),
              !value.isUndefined,
              let responseJSON = value.toString(),
              let responseData = responseJSON.data(using: .utf8),
              let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw RuntimeError.invalidResult("No response for \(operation)")
        }
        guard response["ok"] as? Bool == true else {
            throw RuntimeError.operationFailed(response["error"] as? String ?? "Unknown configuration error")
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    private func configurationObject(_ configuration: ToolboxConfiguration) throws -> [String: Any] {
        let data = try JSONEncoder.toolbox.encode(configuration)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError.invalidResult("Could not serialize configuration")
        }
        object["unknown_tail_hex"] = configuration.unknownPacketTail.hexStringNoSpaces
        return object
    }

    private func decodeConfiguration(_ object: [String: Any]) throws -> ToolboxConfiguration {
        let data = try JSONSerialization.data(withJSONObject: object)
        var configuration = try JSONDecoder.toolbox.decode(ToolboxConfiguration.self, from: data)
        if let hex = object["unknown_tail_hex"] as? String {
            configuration.unknownPacketTail = Data(hexString: hex) ?? Data()
        }
        return configuration
    }

    private func evaluateResource(name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            throw RuntimeError.missingResource("\(name).js")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: url)
        if let exception = context.exception {
            context.exception = nil
            throw RuntimeError.javaScript(exception.toString())
        }
    }

    private static func resourceString(name: String, extension fileExtension: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
            throw RuntimeError.missingResource("\(name).\(fileExtension)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func decodeSchema(_ object: [String: Any]) throws -> ToolboxSchema {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ToolboxSchemaEnvelope.self, from: data).schema
    }

    enum RuntimeError: LocalizedError {
        case contextCreationFailed
        case missingResource(String)
        case javaScript(String)
        case invalidResult(String)
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed: "Could not create the Toolbox JavaScript context"
            case .missingResource(let name): "Missing bundled resource: \(name)"
            case .javaScript(let message): "Toolbox JavaScript error: \(message)"
            case .invalidResult(let message): "Invalid Toolbox result: \(message)"
            case .operationFailed(let message): message
            }
        }
    }
}

struct ToolboxValidation: Decodable {
    let issues: [ToolboxValidationIssue]
    let encodedLength: Int

    enum CodingKeys: String, CodingKey {
        case issues
        case encodedLength = "encoded_length"
    }

    var errors: [ToolboxValidationIssue] { issues.filter { $0.severity == "error" } }
    var warnings: [ToolboxValidationIssue] { issues.filter { $0.severity == "warning" } }
}

struct ToolboxValidationIssue: Decodable, Identifiable {
    var id: String { "\(severity):\(code):\(message)" }
    let severity: String
    let code: String
    let message: String
}

private struct ToolboxSchemaEnvelope: Decodable {
    let schema: ToolboxSchema
    enum CodingKeys: String, CodingKey { case schema = "ble_proto" }
}

private extension Data {
    var hexStringNoSpaces: String { map { String(format: "%02x", $0) }.joined() }
}
