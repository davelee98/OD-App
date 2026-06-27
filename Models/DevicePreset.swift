import Foundation

struct DevicePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let board: String
    let panel: String
    let width: Int
    let height: Int
    let colorMode: ColorMode

    enum ColorMode: String, CaseIterable {
        case blackWhite    = "Black & White"
        case blackWhiteRed = "Black, White & Red"
        case spectra6      = "Spectra 6"
        case fourGray      = "4-Gray"
    }
}

extension DevicePreset {
    static let all: [DevicePreset] = [
        DevicePreset(
            id: "waveshare-esp32s3-75",
            name: "Waveshare ESP32-S3 PhotoPainter (7.5\")",
            board: "ESP32-S3",
            panel: "Waveshare 7.5\" B/W",
            width: 800, height: 480,
            colorMode: .blackWhite
        ),
        DevicePreset(
            id: "seeed-xiao-c3-29",
            name: "Seeed XIAO ESP32-C3 (2.9\")",
            board: "ESP32-C3",
            panel: "2.9\" B/W/R",
            width: 296, height: 128,
            colorMode: .blackWhiteRed
        ),
        DevicePreset(
            id: "seeed-xiao-s3-42",
            name: "Seeed XIAO ESP32-S3 (4.2\")",
            board: "ESP32-S3",
            panel: "4.2\" B/W",
            width: 400, height: 300,
            colorMode: .blackWhite
        ),
        DevicePreset(
            id: "reterminal-nrf-75",
            name: "reTerminal nRF52840 (7.5\")",
            board: "nRF52840",
            panel: "7.5\" Spectra 6",
            width: 800, height: 480,
            colorMode: .spectra6
        ),
        DevicePreset(
            id: "custom",
            name: "Custom",
            board: "",
            panel: "",
            width: 0, height: 0,
            colorMode: .blackWhite
        ),
    ]

    static var custom: DevicePreset { all.last! }
}
