import XCTest
import CoreBluetooth
@testable import OD_App

/// Covers the multi-signal BLE admission predicate: name prefix (GAP or advertised local name,
/// case-insensitive), OpenDisplay service UUID, and OD-shaped manufacturer data.
final class ODDeviceAdmissionTests: XCTestCase {

    private func admit(gapName: String? = nil, localName: String? = nil,
                       serviceUUIDs: [CBUUID] = [], msd: Data? = nil,
                       prefixes: [String] = ["OD"]) -> Bool {
        ODDeviceAdmission.isLikelyOpenDisplay(gapName: gapName, localName: localName,
                                              serviceUUIDs: serviceUUIDs, msd: msd,
                                              prefixes: prefixes)
    }

    /// A 16-byte OD-style manufacturer payload with the given little-endian company ID.
    private func msd16(companyID: UInt16 = 0x1234) -> Data {
        var data = Data([UInt8(companyID & 0xFF), UInt8(companyID >> 8)])
        data.append(Data(repeating: 0, count: 14))
        return data
    }

    // MARK: - Name prefix

    func testGAPNamePrefixMatches() {
        XCTAssertTrue(admit(gapName: "OD-Kitchen"))
    }

    func testGAPNamePrefixIsCaseInsensitive() {
        XCTAssertTrue(admit(gapName: "od_display"))
        XCTAssertTrue(admit(gapName: "Od123"))
    }

    func testLocalNameMatchesWhenGAPNameIsNil() {
        XCTAssertTrue(admit(localName: "OD Panel 7.3"))
    }

    func testPrefixIsAnchored() {
        XCTAssertFalse(admit(gapName: "MyOD Device"))
    }

    func testEmptyPrefixIsIgnored() {
        XCTAssertFalse(admit(gapName: "Anything", prefixes: [""]))
    }

    // MARK: - Service UUID

    func testServiceUUIDAdmitsWithNoNameOrMSD() {
        XCTAssertTrue(admit(serviceUUIDs: [CBUUID(string: "2446")]))
    }

    func testUnrelatedServiceUUIDDoesNotAdmit() {
        XCTAssertFalse(admit(serviceUUIDs: [CBUUID(string: "180F")]))   // Battery Service
    }

    // MARK: - Manufacturer data

    func testSixteenByteMSDAdmits() {
        XCTAssertTrue(admit(msd: msd16()))
    }

    func testWrongLengthMSDRejects() {
        XCTAssertFalse(admit(msd: msd16().dropLast()))          // 15 bytes
        XCTAssertFalse(admit(msd: msd16() + Data([0x00])))      // 17 bytes
    }

    func testAppleCompanyIDRejects() {
        XCTAssertFalse(admit(msd: msd16(companyID: 0x004C)))
    }

    // MARK: - No signal

    func testNoSignalRejects() {
        XCTAssertFalse(admit(gapName: "JBL Speaker", localName: "JBL Speaker"))
        XCTAssertFalse(admit())
    }
}
