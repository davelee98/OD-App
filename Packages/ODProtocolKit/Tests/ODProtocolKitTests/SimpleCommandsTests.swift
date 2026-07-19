import XCTest
@testable import ODProtocolKit

@MainActor
final class SimpleCommandsTests: XCTestCase {

    func testFirmwareVersion() async throws {
        let link = MockLink()
        link.responder = { f in
            guard f.count >= 2, f[1] == 0x43 else { return [] }
            // 0043 | major | minor | sha_len | "abc"
            return [Data([0x00, 0x43, 3, 7, 3, 0x61, 0x62, 0x63])]
        }
        let (major, minor, sha) = try await ODProtocolClient(link: link).firmwareVersion()
        XCTAssertEqual(major, 3); XCTAssertEqual(minor, 7); XCTAssertEqual(sha, "abc")
    }

    func testFirmwareNoSha() async throws {
        let link = MockLink()
        link.responder = { f in (f.count >= 2 && f[1] == 0x43) ? [Data([0x00, 0x43, 1, 2, 0])] : [] }
        let (major, minor, sha) = try await ODProtocolClient(link: link).firmwareVersion()
        XCTAssertEqual(major, 1); XCTAssertEqual(minor, 2); XCTAssertNil(sha)
    }

    func testReadMSD() async throws {
        let msd = (0..<16).map { UInt8($0) }
        let link = MockLink()
        link.responder = { f in (f.count >= 2 && f[1] == 0x44) ? [Data([0x00, 0x44] + msd)] : [] }
        let got = try await ODProtocolClient(link: link).readMSD()
        XCTAssertEqual([UInt8](got), msd)
    }

    func testFireAndForgetFrames() async throws {
        let link = MockLink()
        link.responder = { _ in [] }   // no device response for fire-and-forget
        let client = ODProtocolClient(link: link)
        try await client.send(.reboot)
        try await client.send(.enterDFU)
        try await client.send(.deepSleep(seconds: nil))
        try await client.send(.deepSleep(seconds: 300))
        try await client.send(.powerOff)
        XCTAssertEqual(link.sent[0], Data([0x00, 0x0F]))               // reboot
        XCTAssertEqual(link.sent[1], Data([0x00, 0x51]))               // enter DFU
        XCTAssertEqual(link.sent[2], Data([0x00, 0x52]))               // deep sleep, no override
        XCTAssertEqual(link.sent[3], Data([0x00, 0x52, 0x01, 0x2C]))   // deep sleep 300s (u16 BE)
        XCTAssertEqual(link.sent[4], Data([0x00, 0x53]))               // power off
    }
}
