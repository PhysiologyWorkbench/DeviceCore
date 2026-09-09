import Testing
import Foundation
@testable import DeviceCore

@Suite struct DeviceInformationTests {
    @Test func mapsTheFiveDisCharacteristicsToClaimKeys() {
        #expect(DeviceInformationService.claimKey(forCharacteristic: "2A24") == "dis.model")
        #expect(DeviceInformationService.claimKey(forCharacteristic: "2a25") == "dis.serial")
        #expect(DeviceInformationService.claimKey(forCharacteristic: "2A26") == "dis.firmware")
        #expect(DeviceInformationService.claimKey(forCharacteristic: "2A27") == "dis.hardware")
        #expect(DeviceInformationService.claimKey(forCharacteristic: "2A29") == "dis.manufacturer")
        #expect(DeviceInformationService.claimKey(forCharacteristic: "2A23") == nil)
    }

    @Test func claimValuesAreVerbatimUtf8OrHex() {
        #expect(DeviceInformationService.claimValue(Data("InfiniTime".utf8)) == "InfiniTime")
        #expect(DeviceInformationService.claimValue(Data([0xFF, 0x00, 0xC3])) == "ff00c3")
    }
}
