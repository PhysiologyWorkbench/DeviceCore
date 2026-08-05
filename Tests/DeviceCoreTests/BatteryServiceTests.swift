import Testing
import Foundation
@testable import DeviceCore

@Suite struct BatteryServiceTests {
    @Test func parsesPercentageAndRejectsEmpty() {
        #expect(BatteryService.parse(Data([87])) == 87)
        #expect(BatteryService.parse(Data()) == nil)
    }
}
