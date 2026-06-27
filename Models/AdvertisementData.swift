import Foundation

/// Config-dependent locations within the 11-byte dynamic portion of OpenDisplay MSD.
struct ODAdvertisementLayout: Equatable {
    var buttonDataByteIndex: Int? = nil
    var touchDataStartByte: Int? = nil
    var sht40StartByte: Int? = nil
    var bq27220StartByte: Int? = nil

    static let empty = ODAdvertisementLayout()

    init(config: ODConfigModel? = nil) {
        guard let config else { return }

        for packet in config.toolbox.packets {
            switch packet.packetType {
            case 35: // sensor_data
                let sensorType = Self.integer(packet.fields["sensor_type"])
                let start = Self.integer(packet.fields["msd_data_start_byte"], default: 0xFF)
                if sensorType == 4, sht40StartByte == nil {
                    // The website treats 0xFF as the SHT40 legacy/default location.
                    sht40StartByte = start == 0xFF ? 7 : Self.valid(start, range: 0...8)
                } else if sensorType == 5, bq27220StartByte == nil {
                    bq27220StartByte = Self.valid(start, range: 0...10)
                }
            case 37: // binary_inputs
                if buttonDataByteIndex == nil {
                    let index = Self.integer(packet.fields["button_data_byte_index"], default: 0xFF)
                    buttonDataByteIndex = Self.valid(index, range: 0...10)
                }
            case 40: // touch_controller
                let controller = Self.integer(packet.fields["touch_ic_type"])
                if controller == 1, touchDataStartByte == nil {
                    let index = Self.integer(packet.fields["touch_data_start_byte"], default: 0xFF)
                    touchDataStartByte = Self.valid(index, range: 0...6)
                }
            default:
                break
            }
        }
    }

    private static func integer(_ value: String?, default defaultValue: Int = 0) -> Int {
        guard let value else { return defaultValue }
        if value.lowercased().hasPrefix("0x") {
            return Int(value.dropFirst(2), radix: 16) ?? defaultValue
        }
        return Int(value) ?? defaultValue
    }

    private static func valid(_ value: Int, range: ClosedRange<Int>) -> Int? {
        value == 0xFF || !range.contains(value) ? nil : value
    }
}

/// Decoded OpenDisplay 16-byte BLE manufacturer-specific data payload.
struct ODAdvertisementData: Equatable {
    struct Status: Equatable {
        let rebootFlag: Bool
        let connectionRequested: Bool
        let mainLoopCounter: Int
    }

    struct Button: Equatable {
        let index: Int
        let buttonID: Int
        let pressCount: Int
        let isPressed: Bool
    }

    struct Touch: Equatable {
        enum Contact: Equatable {
            case none
            case down(Int)
            case released
            case unknown(Int)

            var description: String {
                switch self {
                case .none: return "none"
                case .down(let count): return "\(count) contact(s) down"
                case .released: return "released (last xy kept)"
                case .unknown(let value): return "unknown (\(value))"
                }
            }
        }

        let startByte: Int
        let contact: Contact
        let trackID: Int
        let x: Int
        let y: Int
    }

    struct SHT40: Equatable {
        let startByte: Int
        let isValid: Bool
        let temperatureC: Double?
        let relativeHumidityPercent: Double?
    }

    struct BQ27220: Equatable {
        let byteIndex: Int
        let isValid: Bool
        let percent: Int?
        let isCharging: Bool
        let rawByte: UInt8
    }

    let rawData: Data
    let companyID: UInt16
    let dynamicData: Data
    let chipTemperatureC: Double
    let chipTemperatureByte: UInt8
    let batteryVoltage10mV: Int
    let batteryVoltageV: Double
    let statusByte: UInt8
    let status: Status
    let button: Button?
    let touch: Touch?
    let sht40: SHT40?
    let bq27220: BQ27220?

    static func parse(_ data: Data, layout: ODAdvertisementLayout = .empty) throws -> Self {
        guard data.count >= 16 else {
            throw ParseError.invalidLength(actual: data.count)
        }

        let raw = Data(data.prefix(16))
        let bytes = [UInt8](raw)
        let companyID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let dynamic = Array(bytes[2..<13])
        let chipTemperatureByte = bytes[13]
        let batteryLow = bytes[14]
        let statusByte = bytes[15]
        let battery10mV = Int(batteryLow) | (Int(statusByte & 0x01) << 8)

        let status = Status(
            rebootFlag: statusByte & 0x02 != 0,
            connectionRequested: statusByte & 0x04 != 0,
            mainLoopCounter: Int((statusByte >> 4) & 0x0F)
        )

        let button = layout.buttonDataByteIndex.map { index in
            let value = dynamic[index]
            return Button(
                index: index,
                buttonID: Int(value & 0x07),
                pressCount: Int((value >> 3) & 0x0F),
                isPressed: value & 0x80 != 0
            )
        }

        let touch = layout.touchDataStartByte.map { index in
            let contactBits = Int(dynamic[index] & 0x0F)
            let contact: Touch.Contact
            switch contactBits {
            case 0: contact = .none
            case 1...5: contact = .down(contactBits)
            case 6: contact = .released
            default: contact = .unknown(contactBits)
            }
            return Touch(
                startByte: index,
                contact: contact,
                trackID: Int((dynamic[index] >> 4) & 0x0F),
                x: Int(dynamic[index + 1]) | (Int(dynamic[index + 2]) << 8),
                y: Int(dynamic[index + 3]) | (Int(dynamic[index + 4]) << 8)
            )
        }

        let sht40 = layout.sht40StartByte.map { index in
            let b0 = dynamic[index]
            let b1 = dynamic[index + 1]
            let b2 = dynamic[index + 2]
            guard b0 != 0xFF || b1 != 0xFF || b2 != 0xFF else {
                return SHT40(startByte: index, isValid: false,
                             temperatureC: nil, relativeHumidityPercent: nil)
            }
            let packed = Int(b0) | (Int(b1) << 8) | (Int(b2) << 16)
            let humidityDeci = packed & 0x03FF
            let temperatureDeci = ((packed >> 10) & 0x07FF) - 400
            return SHT40(
                startByte: index,
                isValid: true,
                temperatureC: Double(temperatureDeci) / 10,
                relativeHumidityPercent: Double(humidityDeci) / 10
            )
        }

        let bq27220 = layout.bq27220StartByte.map { index in
            let value = dynamic[index]
            return BQ27220(
                byteIndex: index,
                isValid: value != 0xFF,
                percent: value == 0xFF ? nil : Int(value & 0x7F),
                isCharging: value != 0xFF && value & 0x80 != 0,
                rawByte: value
            )
        }

        return Self(
            rawData: raw,
            companyID: companyID,
            dynamicData: Data(dynamic),
            chipTemperatureC: Double(chipTemperatureByte) / 2 - 40,
            chipTemperatureByte: chipTemperatureByte,
            batteryVoltage10mV: battery10mV,
            batteryVoltageV: Double(battery10mV) / 100,
            statusByte: statusByte,
            status: status,
            button: button,
            touch: touch,
            sht40: sht40,
            bq27220: bq27220
        )
    }

    var formattedDescription: String {
        var lines = [
            String(format: "Company ID: 0x%04X (%d)", Int(companyID), Int(companyID)),
            "Dynamic (11 B): \(dynamicData.hexString)",
            String(format: "Chip temp: %.2f °C (byte 0x%02X)", chipTemperatureC, Int(chipTemperatureByte)),
            batteryVoltage10mV > 0
                ? String(format: "Battery: %.3f V (%d × 10 mV)", batteryVoltageV, batteryVoltage10mV)
                : "Battery: not configured / N/A",
            "Status: reboot=\(status.rebootFlag ? 1 : 0), connReq=\(status.connectionRequested ? 1 : 0), mloop=\(status.mainLoopCounter)"
        ]

        if let bq27220 {
            if let percent = bq27220.percent {
                lines.append("SOC @\(bq27220.byteIndex): \(percent) %\(bq27220.isCharging ? " (charging)" : "")")
            } else {
                lines.append(String(format: "SOC @%d: (no valid sample, raw 0x%02X)",
                                    bq27220.byteIndex, Int(bq27220.rawByte)))
            }
        }
        if let button {
            lines.append("Button @\(button.index): id=\(button.buttonID), presses=\(button.pressCount), \(button.isPressed ? "pressed" : "released")")
        }
        if let touch {
            lines.append("Touch @\(touch.startByte): \(touch.contact.description), track=\(touch.trackID), x=\(touch.x), y=\(touch.y)")
        }
        if let sht40 {
            if let temperature = sht40.temperatureC, let humidity = sht40.relativeHumidityPercent {
                lines.append(String(format: "SHT40 @%d–%d: %.1f °C, %.1f %% RH",
                                    sht40.startByte, sht40.startByte + 2, temperature, humidity))
            } else {
                lines.append("SHT40 @\(sht40.startByte)–\(sht40.startByte + 2): (no valid sample / disabled)")
            }
        }
        lines.append("Raw 16 B: \(rawData.hexString)")
        return lines.joined(separator: "\n")
    }

    enum ParseError: LocalizedError, Equatable {
        case invalidLength(actual: Int)

        var errorDescription: String? {
            switch self {
            case .invalidLength(let actual):
                return "Expected 16 advertisement bytes, got \(actual)"
            }
        }
    }
}
