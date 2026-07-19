import XCTest
@testable import OD_App

/// Pins the app's hand-ergonomic `OD.Cmd` opcode enum to the canonical wire constants generated
/// from the `opendisplay-protocol` header (`Generated/opendisplay_protocol.swift`). Swift enum raw
/// values must be literals, so `OD.Cmd` can't reference the generated `let`s directly — this test is
/// what guarantees the two never drift. It's the reason the stale `nfc = 0x0082` (which had silently
/// become `CMD_PIPE_WRITE_END` when NFC moved to `0x0083` in protocol v2.0) can't recur.
///
/// Sibling of `BLEChunkSizeTests`, which pins `OD.configWriteChunkSize` against the bundled JS.
final class ProtocolOpcodeTests: XCTestCase {

    /// Every `OD.Cmd` case and the generated `CMD_*` constant it must equal.
    private let mapping: [(OD.Cmd, UInt16)] = [
        (.reboot,           CMD_REBOOT),
        (.readConfig,       CMD_CONFIG_READ),
        (.writeConfigFirst, CMD_CONFIG_WRITE),
        (.writeConfigChunk, CMD_CONFIG_CHUNK),
        (.readFirmware,     CMD_FIRMWARE_VERSION),
        (.readMSD,          CMD_READ_MSD),
        (.authenticate,     CMD_AUTHENTICATE),
        (.enterDFU,         CMD_ENTER_DFU),
        (.deepSleep,        CMD_DEEP_SLEEP),
        (.imageStart,       CMD_DIRECT_WRITE_START),
        (.imageData,        CMD_DIRECT_WRITE_DATA),
        (.imageEnd,         CMD_DIRECT_WRITE_END),
        (.ledPattern,       CMD_LED_ACTIVATE),
        (.ledStop,          CMD_LED_STOP),
        (.partialUpdate,    CMD_PARTIAL_WRITE_START),
        (.buzzer,           CMD_BUZZER),
        (.nfc,              CMD_NFC_ENDPOINT),
    ]

    func testOpcodesMatchGeneratedProtocolConstants() {
        for (cmd, expected) in mapping {
            XCTAssertEqual(cmd.rawValue, expected,
                           "OD.Cmd.\(cmd) (0x\(String(cmd.rawValue, radix: 16))) has drifted from the generated wire constant 0x\(String(expected, radix: 16))")
        }
    }

    /// The specific regression this fixed: NFC is 0x0083 (v2.0), and 0x0082 is now PIPE_WRITE_END —
    /// so a stale NFC opcode would collide with a different command on the wire.
    func testNfcOpcodeIsNotPipeWriteEnd() {
        XCTAssertEqual(OD.Cmd.nfc.rawValue, CMD_NFC_ENDPOINT)
        XCTAssertEqual(OD.Cmd.nfc.rawValue, 0x0083)
        XCTAssertNotEqual(OD.Cmd.nfc.rawValue, CMD_PIPE_WRITE_END)
    }
}
