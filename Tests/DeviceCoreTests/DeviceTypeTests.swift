import Testing
import Foundation
import CoreBluetooth
@testable import DeviceCore

@Suite struct FingerprintTests {
    private func discovery(name: String = "",
                           services: [CBUUID] = [],
                           manufacturer: ManufacturerData? = nil) -> Discovery {
        Discovery(id: PeripheralID(UUID()), name: name, rssi: -50,
                  services: services, manufacturer: manufacturer)
    }

    @Test func statedConstraintsAreConjunctive() {
        // The H10 shape: two straps serve 0x180D, so the name must also hold.
        let h10 = Fingerprint(namePrefixes: ["Polar H10"], serviceUUIDs: ["180D"])
        #expect(h10.matches(discovery(name: "Polar H10 B2C3D4", services: [CBUUID(string: "180D")])))
        #expect(!h10.matches(discovery(name: "Polar Sense C7A1", services: [CBUUID(string: "180D")])))
        #expect(!h10.matches(discovery(name: "Polar H10 B2C3D4")))
    }

    @Test func namePrefixesAreAlternativesAndCaseInsensitive() {
        // Gemini advertises `lvs gemi`: lowercase, space, no hyphen.
        let lovense = Fingerprint(namePrefixes: ["LVS", "LOVE"])
        #expect(lovense.matches(discovery(name: "lvs gemi")))
        #expect(lovense.matches(discovery(name: "LVS-Edge")))
        #expect(!lovense.matches(discovery(name: "Pro 2 Generation 3")))
    }

    @Test func shortAndLongServiceUUIDsCompareEqual() {
        let f = Fingerprint(serviceUUIDs: ["180D"])
        #expect(f.matches(discovery(services: [CBUUID(string: "0000180D-0000-1000-8000-00805F9B34FB")])))
        #expect(Fingerprint(serviceUUIDs: ["0000180d-0000-1000-8000-00805f9b34fb"])
            .matches(discovery(services: [CBUUID(string: "180D")])))
    }

    @Test func manufacturerPayloadPrefixDiscriminates() {
        let f = Fingerprint(manufacturerData: ManufacturerDataMatch(
            companyID: 0x005D, payloadPrefix: Data([0x00, 0x00, 0x28, 0x43])))
        #expect(f.matches(discovery(manufacturer: ManufacturerData(
            advertisementBlob: Data([0x5D, 0x00, 0x00, 0x00, 0x28, 0x43])))))
        // A different model id under the same company.
        #expect(!f.matches(discovery(manufacturer: ManufacturerData(
            advertisementBlob: Data([0x5D, 0x00, 0x00, 0x00, 0x28, 0x50])))))
        // A coalesced advertisement may carry no manufacturer field at all.
        #expect(!f.matches(discovery(name: "Pro 2 Generation 3")))
    }

    @Test func fingerprintStatingNothingMatchesNothing() {
        #expect(!Fingerprint().matches(discovery(name: "Polar H10 B2C3D4",
                                                 services: [CBUUID(string: "180D")])))
    }
}

@Suite struct DeviceTypeCatalogTests {
    private let catalog = DeviceTypeCatalog([
        DeviceTypeRecord(id: "a", vendor: "V", displayName: "A",
                         fingerprint: Fingerprint(namePrefixes: ["VND"]),
                         probe: ProbeRef(handler: "v.type", expect: "A"),
                         provenance: .tested),
        DeviceTypeRecord(id: "b", vendor: "V", displayName: "B",
                         fingerprint: Fingerprint(namePrefixes: ["VND"]),
                         probe: ProbeRef(handler: "v.type", expect: "B"),
                         provenance: .tested)
    ])

    @Test func oneAdvertisementYieldsEveryVendorCandidate() {
        let d = Discovery(id: PeripheralID(UUID()), name: "VND-42", rssi: -50,
                          services: [], manufacturer: nil)
        let candidates = catalog.candidates(for: d)
        #expect(candidates.map(\.id) == ["a", "b"])
        // The probe is what narrows them; an unrecognised answer narrows to none.
        #expect(candidates.first { $0.probe?.expect == "B" }?.id == "b")
        #expect(candidates.first { $0.probe?.expect == "Z" } == nil)
    }

    @Test func recordLookupByID() {
        #expect(catalog.record(id: "a")?.displayName == "A")
        #expect(catalog.record(id: "z") == nil)
    }

    @Test func recordSurvivesACodableRoundTrip() throws {
        // v0 is compiled in, but the whole point of Codable from day one is that
        // externalisation stays a serialisation task.
        let original = DeviceTypeRecord(
            id: "x", vendor: "V", displayName: "X",
            fingerprint: Fingerprint(namePrefixes: ["VND"], serviceUUIDs: ["180D"],
                                     manufacturerData: ManufacturerDataMatch(
                                        companyID: 0x005D, payloadPrefix: Data([0x01]))),
            probe: ProbeRef(handler: "v.type", expect: "X"),
            sensors: [SensorCapability(id: "ecg", modality: .ecg, unit: "µV",
                                       sampleRatesHz: [130], mdcCode: "MDC_ECG_ELEC_POTL")],
            actuators: [ActuatorCapability(id: "vibe0", kind: .vibration, stepRange: 0...20,
                                           provenance: .userReported)],
            identify: .pulse(actuator: "vibe0"), battery: .vendorQuery,
            provenance: .datasheetInferred, references: ["X.md"])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeviceTypeRecord.self, from: data)

        #expect(decoded.identify == .pulse(actuator: "vibe0"))
        #expect(decoded.battery == .vendorQuery)
        #expect(decoded.provenance == .datasheetInferred)
        #expect(decoded.fingerprint.manufacturerData == original.fingerprint.manufacturerData)
        #expect(decoded.sensors.first?.modality == .ecg)
        #expect(decoded.actuators.first?.stepRange == 0...20)
        #expect(decoded.actuators.first?.baseline == nil)
    }
}
