import Testing
import Foundation
@testable import DeviceCore

@Suite struct ManufacturerDataTests {
    @Test func splitsCompanyIDAndPayload() {
        let m = ManufacturerData(advertisementBlob: Data([0x5D, 0x00, 0x00, 0x00, 0x28, 0x43]))
        #expect(m?.companyID == 0x005D)
        #expect(m?.payload == Data([0x00, 0x00, 0x28, 0x43]))
    }

    @Test func rebasesPayloadIndices() {
        // A sliced blob must not leak its parent's indices into `payload`.
        let blob = Data([0xFF, 0x5D, 0x00, 0x01, 0x02]).dropFirst()
        let m = ManufacturerData(advertisementBlob: Data(blob))
        #expect(m?.payload[0] == 0x01)
    }

    @Test func rejectsBlobShorterThanCompanyID() {
        #expect(ManufacturerData(advertisementBlob: Data([0x5D])) == nil)
        #expect(ManufacturerData(advertisementBlob: Data()) == nil)
    }

    @Test func emptyPayloadIsValid() {
        let m = ManufacturerData(advertisementBlob: Data([0x4C, 0x00]))
        #expect(m?.companyID == 0x004C)
        #expect(m?.payload.isEmpty == true)
    }
}
