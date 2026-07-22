import Testing
import Foundation
@testable import DeviceCore

@Suite struct PolarH10Tests {
    @Test func parsesBatteryPercentage() {
        #expect(PolarH10.parseBatteryLevel(Data([72])) == 72)
    }

    @Test func emptyDataParsesToNil() {
        #expect(PolarH10.parseBatteryLevel(Data()) == nil)
    }
}
