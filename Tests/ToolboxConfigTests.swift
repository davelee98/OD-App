import XCTest
@testable import OD_App

final class ToolboxConfigTests: XCTestCase {
    func testBundledYAMLLoadsCurrentSchema() throws {
        let schema = try ToolboxConfigRuntime.shared.schema()
        XCTAssertEqual(schema.version, 1)
        XCTAssertEqual(schema.minorVersion, 3)
        XCTAssertNotNil(schema.packetTypes["44"])
    }

    func testSimplePresetRoundTripsThroughJavaScriptCodec() throws {
        let configuration = try ToolboxConfigRuntime.shared.buildSimple(
            boardID: "reterminal-e1001",
            displayID: "ep75-800x480",
            powerID: "battery-2000",
            deepSleepSeconds: 600,
            encryptionKey: nil
        )
        let encoded = try ToolboxConfigRuntime.shared.encode(configuration)
        let decoded = try ToolboxConfigRuntime.shared.decode(encoded)

        XCTAssertEqual(decoded.packets.map(\.packetType), configuration.packets.map(\.packetType))
        XCTAssertTrue(try ToolboxConfigRuntime.shared.validate(decoded).errors.isEmpty)
    }

    func testDuplicateRepeatInstanceIsRejected() throws {
        var configuration = try ToolboxConfigRuntime.shared.buildSimple(
            boardID: "reterminal-e1001",
            displayID: "ep75-800x480",
            powerID: "battery-2000",
            deepSleepSeconds: 0,
            encryptionKey: nil
        )
        configuration.packets.append(try XCTUnwrap(configuration.packets.first { $0.packetType == 32 }))

        let validation = try ToolboxConfigRuntime.shared.validate(configuration)
        XCTAssertTrue(validation.errors.contains { $0.code == "duplicate_instance" })
        XCTAssertThrowsError(try ToolboxConfigRuntime.shared.encode(configuration))
    }
}
