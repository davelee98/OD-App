import Foundation
import JavaScriptCore

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let root = repositoryRoot.appendingPathComponent("Resources")
let context = JSContext()!
context.evaluateScript("var console = { log:function(){}, warn:function(){}, error:function(){} };")

for name in ["js-yaml.min.js", "toolbox-config-engine.js"] {
    let url = root.appendingPathComponent(name)
    context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
    if let exception = context.exception { fatalError("\(name): \(exception)") }
}

func call(_ operation: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: arguments)
    let json = String(decoding: data, as: UTF8.self)
    let response = context.objectForKeyedSubscript("__odToolboxCall")!
        .call(withArguments: [operation, json])!.toString()!
    let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as! [String: Any]
    guard object["ok"] as? Bool == true else {
        throw NSError(domain: "ToolboxSmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: object["error"] ?? "Unknown error"])
    }
    return object["result"] as! [String: Any]
}

let yaml = try String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
let presets = try String(contentsOf: root.appendingPathComponent("simple-config-presets.json"), encoding: .utf8)
_ = try call("initialize", ["yaml": yaml, "presets_json": presets])

let built = try call("build_simple", [
    "board_id": "reterminal-e1001",
    "display_id": "ep75-800x480",
    "power_id": "battery-2000",
    "deep_sleep_seconds": 600,
    "configured_at": 1_700_000_000
])
let configuration = built["configuration"] as! [String: Any]
let encoded = try call("encode", ["configuration": configuration])
let hex = encoded["hex"] as! String
let decoded = try call("decode", ["hex": hex])
let decodedConfiguration = decoded["configuration"] as! [String: Any]
let validation = try call("validate", ["configuration": decodedConfiguration])
let packets = decodedConfiguration["packets"] as! [[String: Any]]
let issues = validation["issues"] as! [[String: Any]]
precondition(issues.isEmpty, "Expected the preset configuration to validate")

var textConfiguration = configuration
var textPackets = textConfiguration["packets"] as! [[String: Any]]
textPackets.append(["id": "44", "fields": [
    "manufacturer_name": "OpenDisplay",
    "friendly_name": "Kitchen panel 🫖",
    "device_location": "Kitchen"
]])
textConfiguration["packets"] = textPackets
let textHex = try call("encode", ["configuration": textConfiguration])["hex"] as! String
let textDecoded = try call("decode", ["hex": textHex])["configuration"] as! [String: Any]
let textDecodedPackets = textDecoded["packets"] as! [[String: Any]]
let extended = textDecodedPackets.first { ($0["id"] as? String) == "44" }!
let extendedFields = extended["fields"] as! [String: String]
precondition(extendedFields["friendly_name"] == "Kitchen panel 🫖", "UTF-8 text did not round-trip")

var duplicateConfiguration = configuration
var duplicatePackets = duplicateConfiguration["packets"] as! [[String: Any]]
duplicatePackets.append(duplicatePackets.first { ($0["id"] as? String) == "32" }!)
duplicateConfiguration["packets"] = duplicatePackets
let duplicateValidation = try call("validate", ["configuration": duplicateConfiguration])
let duplicateIssues = duplicateValidation["issues"] as! [[String: Any]]
precondition(duplicateIssues.contains { ($0["code"] as? String) == "duplicate_instance" },
             "Duplicate repeat instances were not rejected")

var oversizedConfiguration = configuration
var oversizedPackets = oversizedConfiguration["packets"] as! [[String: Any]]
let displayPacket = oversizedPackets.first { ($0["id"] as? String) == "32" }!
for instance in 1...256 {
    var packet = displayPacket
    var fields = packet["fields"] as! [String: String]
    fields["instance_number"] = String(instance)
    packet["fields"] = fields
    oversizedPackets.append(packet)
}
oversizedConfiguration["packets"] = oversizedPackets
let oversizedValidation = try call("validate", ["configuration": oversizedConfiguration])
let oversizedIssues = oversizedValidation["issues"] as! [[String: Any]]
precondition(oversizedIssues.contains { ($0["code"] as? String) == "packet_limit" },
             "The one-byte packet-number limit was not enforced")

print("Toolbox smoke passed: packets=\(packets.count), bytes=\(hex.count / 2), issues=\(issues.count)")
