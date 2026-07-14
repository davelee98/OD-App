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

    // MARK: - Text field limits (fixed-size, null-terminated, zero-padded strings)

    private func simpleConfiguration() throws -> ToolboxConfiguration {
        try ToolboxConfigRuntime.shared.buildSimple(
            boardID: "reterminal-e1001",
            displayID: "ep75-800x480",
            powerID: "battery-2000",
            deepSleepSeconds: 0,
            encryptionKey: nil
        )
    }

    /// All fields of `packetType` seeded the way `ToolboxView.addPacket` seeds them.
    private func seededFields(packetType: String) throws -> [String: String] {
        let definition = try XCTUnwrap(ToolboxConfigRuntime.shared.schema().packetTypes[packetType])
        return Dictionary(uniqueKeysWithValues: definition.fields.map {
            ($0.name, $0.isTextField ? "" : "0x0")
        })
    }

    func testTextFieldTruncatesTo31BytesWithNullTerminator() throws {
        var configuration = try simpleConfiguration()
        var fields = try seededFields(packetType: "44")
        fields["manufacturer_name"] = String(repeating: "a", count: 40)
        configuration.packets.append(ToolboxPacket(packetType: 44, fields: fields))

        let encoded = try ToolboxConfigRuntime.shared.encode(configuration)
        let decoded = try ToolboxConfigRuntime.shared.decode(encoded)
        let name = decoded.packets.first { $0.packetType == 44 }?.fields["manufacturer_name"]
        XCTAssertEqual(name, String(repeating: "a", count: 31),
                       "a 32-byte text field holds at most 31 content bytes + null terminator")

        // Truncation happens at byte 31: a value already clamped there encodes identically,
        // and a 32-char value still decodes to 31 chars (byte 31 stays 0x00).
        var clamped = configuration
        clamped.packets[clamped.packets.count - 1].fields["manufacturer_name"] = String(repeating: "a", count: 31)
        XCTAssertEqual(try ToolboxConfigRuntime.shared.encode(clamped), encoded)
    }

    func testSwiftTruncatedValuesRoundTripUnchangedThroughEngine() throws {
        // The UI clamps with `prefixFittingUTF8Bytes` before the JS engine ever sees the
        // value; for every clamped value the engine must keep it byte-identical.
        let tricky = [
            String(repeating: "a", count: 40),
            String(repeating: "a", count: 30) + "é",
            String(repeating: "a", count: 29) + "😀",
            "日本語のデバイス名テスト",
            "abc👨‍👩‍👧‍👦xyz"
        ]
        for value in tricky {
            let clamped = value.prefixFittingUTF8Bytes(31)
            var configuration = try simpleConfiguration()
            var fields = try seededFields(packetType: "44")
            fields["friendly_name"] = clamped
            configuration.packets.append(ToolboxPacket(packetType: 44, fields: fields))

            let decoded = try ToolboxConfigRuntime.shared.decode(
                try ToolboxConfigRuntime.shared.encode(configuration))
            XCTAssertEqual(decoded.packets.first { $0.packetType == 44 }?.fields["friendly_name"],
                           clamped, "clamped value for input \(value) must round-trip unchanged")
        }
    }

    func testWifiStringFieldsAreTreatedAsText() throws {
        // config.yaml does not tag ssid/password `type: text`, but the engine encodes them
        // as text by name; the Swift rule must mirror that (it drives seeding and UI limits).
        let schema = try ToolboxConfigRuntime.shared.schema()
        let wifi = try XCTUnwrap(schema.packetTypes["38"])
        for name in ["ssid", "password"] {
            let field = try XCTUnwrap(wifi.fields.first { $0.name == name })
            XCTAssertTrue(field.isTextField)
            XCTAssertEqual(field.maxTextContentBytes, 31)
        }
        let extended = try XCTUnwrap(schema.packetTypes["44"])
        XCTAssertEqual(extended.fields.count, 9)
        XCTAssertTrue(extended.fields.allSatisfy(\.isTextField))
    }

    func testFreshWifiPacketEncodesEmptyStrings() throws {
        var configuration = try simpleConfiguration()
        configuration.packets.append(ToolboxPacket(packetType: 38,
                                                   fields: try seededFields(packetType: "38")))

        let decoded = try ToolboxConfigRuntime.shared.decode(
            try ToolboxConfigRuntime.shared.encode(configuration))
        let wifi = try XCTUnwrap(decoded.packets.first { $0.packetType == 38 })
        XCTAssertEqual(wifi.fields["ssid"], "")
        XCTAssertEqual(wifi.fields["password"], "")

        // Regression guard: seeding ssid with the numeric default writes those literal
        // characters to the device — exactly what the isTextField seeding rule prevents.
        var old = configuration
        old.packets[old.packets.count - 1].fields["ssid"] = "0x0"
        let oldDecoded = try ToolboxConfigRuntime.shared.decode(
            try ToolboxConfigRuntime.shared.encode(old))
        XCTAssertEqual(oldDecoded.packets.first { $0.packetType == 38 }?.fields["ssid"], "0x0")
    }

    func testWifiSSIDRoundTrips() throws {
        var configuration = try simpleConfiguration()
        var fields = try seededFields(packetType: "38")
        fields["ssid"] = "MyNetwork"
        fields["password"] = "hunter2!"
        configuration.packets.append(ToolboxPacket(packetType: 38, fields: fields))

        let decoded = try ToolboxConfigRuntime.shared.decode(
            try ToolboxConfigRuntime.shared.encode(configuration))
        let wifi = try XCTUnwrap(decoded.packets.first { $0.packetType == 38 })
        XCTAssertEqual(wifi.fields["ssid"], "MyNetwork")
        XCTAssertEqual(wifi.fields["password"], "hunter2!")
    }

    func testOverlongTextProducesWarningAndStillEncodes() throws {
        var configuration = try simpleConfiguration()
        var fields = try seededFields(packetType: "44")
        fields["serial_number"] = String(repeating: "s", count: 50)
        configuration.packets.append(ToolboxPacket(packetType: 44, fields: fields))

        let schema = try ToolboxConfigRuntime.shared.schema()
        let issues = ToolboxSwiftValidation.issues(for: configuration, schema: schema)
        XCTAssertTrue(issues.contains { $0.code == "text_too_long" && $0.severity == "warning" })
        XCTAssertNoThrow(try ToolboxConfigRuntime.shared.encode(configuration),
                         "over-long text is a warning, not an error — the engine truncates safely")
    }

    func testEncryptionKeyLengthWarning() throws {
        let schema = try ToolboxConfigRuntime.shared.schema()
        var fields = try seededFields(packetType: "39")

        var configuration = ToolboxConfiguration()
        fields["encryption_key"] = "abc"
        configuration.packets = [ToolboxPacket(packetType: 39, fields: fields)]
        XCTAssertTrue(ToolboxSwiftValidation.issues(for: configuration, schema: schema)
            .contains { $0.code == "key_length" })

        // Disabled (all-zero / default) keys and a proper 32-hex-char key are not flagged.
        for valid in ["0x0", "", String(repeating: "ab", count: 16)] {
            fields["encryption_key"] = valid
            configuration.packets = [ToolboxPacket(packetType: 39, fields: fields)]
            XCTAssertTrue(ToolboxSwiftValidation.issues(for: configuration, schema: schema)
                .filter { $0.code == "key_length" }.isEmpty, "'\(valid)' should not be flagged")
        }
    }

    // MARK: - Saved-display provenance (add-device config-state fix)

    /// A registry entry created without a confirmed read must not masquerade as hardware fact:
    /// `resolutionConfirmed` starts false so provisional values can be marked and safely overwritten.
    func testNewEntityStartsUnconfirmed() {
        let entity = SavedDisplayEntity(id: "dev-1", friendlyName: "Kitchen")
        XCTAssertFalse(entity.resolutionConfirmed)
        XCTAssertEqual(entity.width, 800)
        XCTAssertEqual(entity.height, 480)
    }

    /// `apply(config:)` is the only path that confirms a resolution — it copies the real dimensions
    /// and color scheme off the read and flips the provenance flag.
    func testApplyConfigConfirmsResolution() throws {
        let model = ODConfigModel(toolbox: try simpleConfiguration())   // ep75-800x480 preset
        XCTAssertEqual(model.displayWidth, 800)
        XCTAssertEqual(model.displayHeight, 480)

        let entity = SavedDisplayEntity(id: "dev-2", friendlyName: "Office",
                                        width: 111, height: 222, colorScheme: 9)
        entity.apply(config: model)
        XCTAssertTrue(entity.resolutionConfirmed)
        XCTAssertEqual(entity.width, model.displayWidth)
        XCTAssertEqual(entity.height, model.displayHeight)
        XCTAssertEqual(entity.colorScheme, Int(model.colorScheme))
    }
}
