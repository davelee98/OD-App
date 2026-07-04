import Foundation
import JavaScriptCore
import CryptoSwift
import Security
import os

enum BLELogging {
    /// Enable in a Debug scheme with the launch argument `-BLEVerbosePayloadLogging`.
    /// Release builds always suppress image-chunk payload logging.
    static let detailedPayloads: Bool = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-BLEVerbosePayloadLogging")
#else
        false
#endif
    }()
}

@objc private protocol OpenDisplayNativeBridgeExports: JSExport {
    func invoke(_ json: String)
    func emit(_ json: String)
    func randomHex(_ count: Int) -> String
    func aesCBC(_ json: String) -> String
    func log(_ message: String)
}

/// Hosts the verbatim web BLE library and exposes a small typed boundary to Swift.
/// This object is main-thread confined because JavaScriptCore contexts are not thread-safe.
final class OpenDisplayJSRuntime {
    typealias Completion = (Result<[String: Any], Error>) -> Void

    var onWrite: ((Data, @escaping (Error?) -> Void) -> Void)?
    var onEvent: ((String, [String: Any]) -> Void)?

    private let context: JSContext
    private var nextOperationID = 1
    private var completions: [Int: Completion] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var bridge: NativeBridge!

    init() throws {
        guard let context = JSContext() else { throw RuntimeError.contextCreationFailed }
        self.context = context
        bridge = NativeBridge(runtime: self)

        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "Unknown JavaScript exception"
            self?.onEvent?("error", ["message": message])
        }
        context.setObject(bridge, forKeyedSubscript: "nativeBridge" as NSString)

        let configYAML = try resourceString(name: "config", extension: "yaml")
        context.setObject(configYAML, forKeyedSubscript: "__odConfigYAML" as NSString)

        try evaluateResource(name: "ble-native-bridge")
        try evaluateResource(name: "js-yaml.min")
        try evaluateResource(name: "pako")
        try evaluateResource(name: "ble-common")
        try evaluateResource(name: "ble-app-adapter")

        guard context.objectForKeyedSubscript("__odRuntimeReady")?.toBool() == true else {
            throw RuntimeError.bootstrapFailed
        }
    }

    func setConnected(_ connected: Bool) {
        context.objectForKeyedSubscript("__odSetConnected")?.call(withArguments: [connected])
    }

    func receiveNotification(_ data: Data) {
        context.objectForKeyedSubscript("__odNotify")?.call(withArguments: [data.hexStringNoSpaces])
    }

    @discardableResult
    func call(_ operation: String, arguments: [String: Any] = [:],
              completion: Completion? = nil) -> Int {
        let id = nextOperationID
        nextOperationID += 1
        if let completion { completions[id] = completion }

        ODLog.proto.debug("call #\(id) \(operation, privacy: .public) dispatching to __odCall")
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            let json = String(decoding: data, as: UTF8.self)
            context.objectForKeyedSubscript("__odCall")?.call(withArguments: [id, operation, json])
            ODLog.proto.debug("call #\(id) \(operation, privacy: .public) __odCall returned (JS runs async from here)")
        } catch {
            ODLog.proto.warning("call #\(id) \(operation, privacy: .public) failed to serialize arguments: \(error.localizedDescription, privacy: .public)")
            completions.removeValue(forKey: id)?(.failure(error))
        }
        return id
    }

    private func evaluateResource(name: String) throws {
        let (source, url) = try resourceStringAndURL(name: name, extension: "js")
        context.evaluateScript(source, withSourceURL: url)
        if let exception = context.exception {
            context.exception = nil
            throw RuntimeError.javaScript(exception.toString())
        }
    }

    private func resourceString(name: String, extension fileExtension: String) throws -> String {
        try resourceStringAndURL(name: name, extension: fileExtension).source
    }

    private func resourceStringAndURL(
        name: String,
        extension fileExtension: String
    ) throws -> (source: String, url: URL) {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
            throw RuntimeError.missingResource("\(name).\(fileExtension)")
        }
        return (try String(contentsOf: url, encoding: .utf8), url)
    }

    fileprivate func handleInvocation(_ json: String) {
        guard let object = Self.jsonObject(json), let method = object["method"] as? String else { return }
        switch method {
        case "write":
            guard let id = Self.integer(object["id"]),
                  let hex = object["hex"] as? String,
                  let data = Data(hexString: hex) else {
                ODLog.proto.warning("JS write invocation malformed: \(json, privacy: .public)")
                return
            }
            ODLog.proto.debug("JS requested BLE write id=\(id) bytes=\(data.count)")
            guard let onWrite else {
                ODLog.proto.warning("JS write id=\(id) failed: onWrite handler unavailable")
                resolveWrite(id: id, error: RuntimeError.transportUnavailable.localizedDescription)
                return
            }
            onWrite(data) { [weak self] error in
                ODLog.proto.debug("JS write id=\(id) transport completion: error=\(error?.localizedDescription ?? "nil", privacy: .public)")
                self?.resolveWrite(id: id, error: error?.localizedDescription)
            }
        case "scheduleTimer":
            guard let id = Self.integer(object["id"]) else { return }
            let milliseconds = (object["milliseconds"] as? NSNumber)?.doubleValue ?? 0
            scheduleTimer(id: id, milliseconds: milliseconds)
        case "cancelTimer":
            guard let id = Self.integer(object["id"]) else { return }
            timers.removeValue(forKey: id)?.cancel()
        default:
            break
        }
    }

    fileprivate func handleEvent(_ json: String) {
        guard let object = Self.jsonObject(json), let type = object["type"] as? String else { return }
        let payload = object["payload"] as? [String: Any] ?? [:]

        if type == "operation", let id = Self.integer(payload["id"]) {
            let ok = (payload["ok"] as? Bool) == true
            ODLog.proto.debug("operation #\(id) resolved ok=\(ok) error=\(String(describing: payload["error"] ?? "nil"), privacy: .public)")
            if let completion = completions.removeValue(forKey: id) {
                if ok {
                    completion(.success(payload["result"] as? [String: Any] ?? [:]))
                } else {
                    completion(.failure(RuntimeError.operationFailed(payload["error"] as? String ?? "Unknown error")))
                }
            } else {
                ODLog.proto.warning("operation #\(id) resolved but no completion was registered (already consumed or unknown id)")
            }
            return
        }
        if type != "log" {
            ODLog.proto.debug("event type=\(type, privacy: .public) payload=\(String(describing: payload), privacy: .public)")
        }
        onEvent?(type, payload)
    }

    private func resolveWrite(id: Int, error: String?) {
        context.objectForKeyedSubscript("__odResolveWrite")?.call(withArguments: [id, error ?? NSNull()])
    }

    private func scheduleTimer(id: Int, milliseconds: Double) {
        timers.removeValue(forKey: id)?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timers.removeValue(forKey: id)
            self.context.objectForKeyedSubscript("__odFireTimer")?.call(withArguments: [id])
        }
        timers[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, milliseconds) / 1000, execute: item)
    }

    fileprivate func makeRandomHex(count: Int) -> String {
        guard count > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return "" }
        return Data(bytes).hexStringNoSpaces
    }

    fileprivate func encryptAESCBC(_ json: String) -> String {
        guard let object = Self.jsonObject(json),
              let keyHex = object["key"] as? String,
              let ivHex = object["iv"] as? String,
              let dataHex = object["data"] as? String,
              let key = Data(hexString: keyHex),
              let iv = Data(hexString: ivHex),
              let input = Data(hexString: dataHex) else { return "error:Invalid AES-CBC input" }
        do {
            let aes = try AES(key: Array(key), blockMode: CBC(iv: Array(iv)), padding: .pkcs7)
            return Data(try aes.encrypt(Array(input))).hexStringNoSpaces
        } catch {
            return "error:\(error.localizedDescription)"
        }
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    enum RuntimeError: LocalizedError {
        case contextCreationFailed
        case missingResource(String)
        case bootstrapFailed
        case javaScript(String)
        case transportUnavailable
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .contextCreationFailed: return "Could not create JavaScriptCore context"
            case .missingResource(let name): return "Missing bundled resource: \(name)"
            case .bootstrapFailed: return "ble-common.js bridge did not initialize"
            case .javaScript(let message): return "JavaScript error: \(message)"
            case .transportUnavailable: return "Core Bluetooth transport is unavailable"
            case .operationFailed(let message): return message
            }
        }
    }
}

private final class NativeBridge: NSObject, OpenDisplayNativeBridgeExports {
    weak var runtime: OpenDisplayJSRuntime?

    init(runtime: OpenDisplayJSRuntime) {
        self.runtime = runtime
    }

    func invoke(_ json: String) { runtime?.handleInvocation(json) }
    func emit(_ json: String) { runtime?.handleEvent(json) }
    func randomHex(_ count: Int) -> String { runtime?.makeRandomHex(count: count) ?? "" }
    func aesCBC(_ json: String) -> String { runtime?.encryptAESCBC(json) ?? "error:Runtime unavailable" }
    func log(_ message: String) {
        // Image data generates two log lines for every 0x71 chunk. Suppress those payload/ACK
        // messages by default while retaining them behind the Debug launch flag.
        let isImageChunk = message.hasPrefix("CMD> 0071") || message.hasPrefix("BLE< 00 71")
        guard BLELogging.detailedPayloads || !isImageChunk else { return }
        ODLog.proto.debug("\(message, privacy: .public)")
    }
}

private extension Data {
    var hexStringNoSpaces: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
