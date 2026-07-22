import Testing
import CoreBluetooth
@testable import DeviceCore

@Suite struct DeviceCatalogTests {
    let catalog = try! DeviceCatalog()

    @Test func scanFilters() {
        #expect(catalog.namePrefixes.contains("LVS-"))
        #expect(catalog.namePrefixes.allSatisfy { !$0.hasSuffix("*") })
        #expect(!catalog.advertisedServiceUUIDs.isEmpty)
    }

    @Test func knownModels() {
        #expect(catalog.model(forDeviceType: "P", firmware: nil).name == "Lovense Edge")
        #expect(catalog.model(forDeviceType: "S", firmware: nil).name == "Lovense Lush")
        #expect(catalog.model(forDeviceType: "N", firmware: nil).name == "Lovense Gemini")
    }

    @Test func edgeHasTwoVibratorsAndBattery() {
        let features = catalog.model(forDeviceType: "P", firmware: nil).features
        let vibrators = features.filter { if case .vibrate = $0 { return true } else { return false } }
        let battery = features.contains { if case .battery = $0 { return true } else { return false } }
        #expect(vibrators.count == 2)
        #expect(battery)
    }

    @Test func firmwareSpecialCase() {
        // EI + firmware >= 3 resolves to the Flexer FW3 row; plain EI does not.
        #expect(catalog.model(forDeviceType: "EI", firmware: 3).identifier == "EI-FW3")
        #expect(catalog.model(forDeviceType: "EI", firmware: 2).identifier != "EI-FW3")
    }

    @Test func unknownFallsBackToGeneric() {
        let model = catalog.model(forDeviceType: "ZZ", firmware: nil)
        #expect(model.isGeneric)
        #expect(!model.features.isEmpty)
    }

    @Test func serialEndpointsResolveForEdgeService() {
        let edgeService = CBUUID(string: "50300001-0023-4bd4-bbd5-a6920e4c5653")
        let ep = catalog.serialEndpoints(amongDiscovered: [edgeService])
        #expect(ep?.tx == CBUUID(string: "50300002-0023-4bd4-bbd5-a6920e4c5653"))
        #expect(ep?.rx == CBUUID(string: "50300003-0023-4bd4-bbd5-a6920e4c5653"))
    }

    @Test func serialEndpointsNilForUnknownService() {
        #expect(catalog.serialEndpoints(amongDiscovered: [CBUUID(string: "180F")]) == nil)
    }
}
