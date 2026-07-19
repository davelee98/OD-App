import XCTest
@testable import OD_App

/// Guards the MSD-advertisement parse after migrating its fixed 16-byte header onto the generated
/// `MsdAdvertisement` struct and its status byte onto `MsdStatusBits`, and the config-packet /
/// sensor / touch magic numbers onto `ConfigPacketType` / `SensorType` / `TouchIcType`. Asserts the
/// decode is byte-for-byte equivalent to the former hand-parse.
final class AdvertisementDataTests: XCTestCase {

    func testFixedHeaderDecodeMatchesHandParse() throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 0xE5; bytes[1] = 0x02   // companyID 0x02E5 (little-endian)
        bytes[13] = 0xA0                    // chip-temp byte 160 → 160/2 - 40 = 40.0 °C
        bytes[14] = 0xC8                    // battery-low 200
        bytes[15] = 0x37                    // bit0 battery MSB, bit1 reboot, bit2 connReq, hi nibble mloop=3

        let ad = try ODAdvertisementData.parse(Data(bytes))
        XCTAssertEqual(ad.companyID, 0x02E5)
        XCTAssertEqual(ad.chipTemperatureC, 40.0, accuracy: 0.001)
        XCTAssertEqual(ad.batteryVoltage10mV, 456)                 // 200 | (batteryVoltageBit8 << 8)
        XCTAssertEqual(ad.batteryVoltageV, 4.56, accuracy: 0.001)
        XCTAssertTrue(ad.status.rebootFlag)
        XCTAssertTrue(ad.status.connectionRequested)
        XCTAssertEqual(ad.status.mainLoopCounter, 3)
        XCTAssertEqual(ad.dynamicData.count, 11)
    }

    func testStatusBitsClearedDecodeAsFalse() throws {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[14] = 0x0A                    // battery-low 10, no MSB bit
        bytes[15] = 0x00                    // all status bits clear
        let ad = try ODAdvertisementData.parse(Data(bytes))
        XCTAssertEqual(ad.batteryVoltage10mV, 10)
        XCTAssertFalse(ad.status.rebootFlag)
        XCTAssertFalse(ad.status.connectionRequested)
        XCTAssertEqual(ad.status.mainLoopCounter, 0)
    }

    func testRejectsShortPayload() {
        XCTAssertThrowsError(try ODAdvertisementData.parse(Data([0x00, 0x01])))
    }

    func testSensorLayoutFromGeneratedConfigPacketTypes() {
        // A sensor packet (ConfigPacketType.sensor = 35) declaring SensorType.bq27220 (5) at start
        // byte 3 must produce a bq27220 layout slot — exercises the generated-enum overlay path.
        var config = ODConfigModel()
        config.toolbox.packets.append(
            ToolboxPacket(packetType: Int(ConfigPacketType.sensor.rawValue),
                          fields: ["sensor_type": "\(SensorType.bq27220.rawValue)", "msd_data_start_byte": "3"]))
        let layout = ODAdvertisementLayout(config: config)
        XCTAssertEqual(layout.bq27220StartByte, 3)
        XCTAssertNil(layout.sht40StartByte)
    }
}
