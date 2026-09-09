import Testing
import Foundation
import DeviceCore
@testable import BenchKit

/// A radio that answers from a script — the live end is the owner's bench.
private struct ScriptedRadio: WireRadio {
    var scanResult: [AdvertisementEvent] = []
    var surveyResult: Result<GattSurvey, WireError> = .failure(.deviceNotFound("unscripted"))
    var notifyResult: Result<[NotifyEvent], WireError> = .failure(.deviceNotFound("unscripted"))

    func advertisements(for duration: Duration) async throws -> [AdvertisementEvent] {
        scanResult
    }

    func survey(_ target: WireTarget, scanWindow: Duration) async throws -> GattSurvey {
        try surveyResult.get()
    }

    func notifications(from target: WireTarget, characteristic: String,
                       scanWindow: Duration, for duration: Duration) async throws -> [NotifyEvent] {
        try notifyResult.get()
    }
}

@Suite struct WireToolTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WireToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func context(_ arguments: [String: String]) -> BenchContext {
        BenchContext(arguments: arguments, runDirectory: directory)
    }

    private let pineTime = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let verity = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private var scanScript: [AdvertisementEvent] {
        [
            AdvertisementEvent(t: 0.1, peripheral: verity, name: nil, rssi: -70,
                               services: ["180D"]),
            AdvertisementEvent(t: 0.4, peripheral: pineTime, name: "InfiniTime", rssi: -55,
                               services: [], manufacturerData: "5900beef", companyID: 0x59,
                               connectable: true),
            AdvertisementEvent(t: 0.9, peripheral: verity, name: "Polar Sense C0FFEE",
                               rssi: -64, services: ["180D", "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8"]),
            AdvertisementEvent(t: 1.2, peripheral: verity, name: "Polar Sense C0FFEE",
                               rssi: -66, services: ["180D"]),
        ]
    }

    @Test func scanCapturesEveryAdvertisementAsJsonlAndSummarisesPerDevice() async throws {
        let tool = WireScanTool(radio: ScriptedRadio(scanResult: scanScript))
        let output = try await tool.run(context(["duration": "2"]))
        #expect(output.outcome == .pass)

        let capture = String(decoding: try Data(contentsOf: directory.appendingPathComponent("advertisements.jsonl")),
                             as: UTF8.self)
        let lines = capture.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[1] == #"{"companyID":89,"connectable":true,"manufacturerData":"5900beef","name":"InfiniTime","peripheral":"AAAAAAAA-0000-0000-0000-000000000001","rssi":-55,"services":[],"t":0.4}"#)

        guard case .object(let results) = output.results,
              case .array(let devices) = results["devices"] else {
            Issue.record("results shape"); return
        }
        #expect(results["durationSeconds"] == .number(2))
        #expect(results["advertisements"] == .number(4))
        #expect(devices.count == 2)
        #expect(devices[0] == .object([
            "peripheral": .string(pineTime.uuidString),
            "name": .string("InfiniTime"),
            "advertisements": .number(1),
            "rssi": .object(["min": .number(-55), "median": .number(-55), "max": .number(-55)]),
            "services": .array([]),
        ]))
        #expect(devices[1] == .object([
            "peripheral": .string(verity.uuidString),
            "name": .string("Polar Sense C0FFEE"),
            "advertisements": .number(3),
            "rssi": .object(["min": .number(-70), "median": .number(-66), "max": .number(-64)]),
            "services": .array([.string("180D"), .string("FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8")]),
        ]))
    }

    @Test func scanOfEmptyAirwavesPassesWithAnEmptyCapture() async throws {
        let tool = WireScanTool(radio: ScriptedRadio())
        let output = try await tool.run(context([:]))
        #expect(output.outcome == .pass)
        let capture = try Data(contentsOf: directory.appendingPathComponent("advertisements.jsonl"))
        #expect(capture.isEmpty)
    }

    @Test func aMalformedDurationRefusesTheRun() async throws {
        let tool = WireScanTool(radio: ScriptedRadio())
        await #expect(throws: WireError.badArgument("duration must be a positive number of seconds, got 'fast'")) {
            _ = try await tool.run(context(["duration": "fast"]))
        }
    }

    private var surveyScript: GattSurvey {
        GattSurvey(peripheral: pineTime, name: "InfiniTime", services: [
            .init(uuid: "180A", isPrimary: true, characteristics: [
                .init(uuid: "2A24", properties: ["read"], value: "496e66696e6954696d65",
                      descriptors: []),
            ]),
            .init(uuid: "180D", isPrimary: true, characteristics: [
                .init(uuid: "2A37", properties: ["read", "notify"], value: nil,
                      descriptors: ["2902"]),
                .init(uuid: "2A38", properties: ["read"], value: "01", descriptors: []),
            ]),
        ])
    }

    @Test func surveyCapturesTheTreeAndCounts() async throws {
        let tool = WireSurveyTool(radio: ScriptedRadio(surveyResult: .success(surveyScript)))
        let output = try await tool.run(context(["device": "InfiniTime"]))
        #expect(output.outcome == .pass)
        guard case .object(let results) = output.results else {
            Issue.record("results shape"); return
        }
        #expect(results["serviceCount"] == .number(2))
        #expect(results["characteristicCount"] == .number(3))
        #expect(output.units == [
            PhysicalUnit(role: .dut,
                 claims: ["ble.name": "InfiniTime", "dis.model": "InfiniTime"],
                 bindings: ["cb.peripheral": pineTime.uuidString]),
        ])

        let capture = try Data(contentsOf: directory.appendingPathComponent("gatt-walk.json"))
        let reread = try JSONDecoder().decode(GattSurvey.self, from: capture)
        #expect(reread == surveyScript)
    }

    @Test func aValuelessDisCharacteristicClaimsNothing() {
        let survey = GattSurvey(peripheral: verity, name: nil, services: [
            .init(uuid: "180a", isPrimary: true, characteristics: [
                .init(uuid: "2a25", properties: ["read"], value: nil, descriptors: []),
                .init(uuid: "2a29", properties: ["read"], value: "506f6c6172", descriptors: []),
            ]),
        ])
        #expect(WireSurveyTool.dutUnit(of: survey) == PhysicalUnit(
            role: .dut, claims: ["dis.manufacturer": "Polar"],
            bindings: ["cb.peripheral": verity.uuidString]))
    }

    @Test func surveyOfAnAbsentDeviceFailsWithTheReason() async throws {
        let tool = WireSurveyTool(radio: ScriptedRadio(
            surveyResult: .failure(.deviceNotFound("no device matching the target advertised within the scan window"))))
        let output = try await tool.run(context(["device": "PineTime"]))
        #expect(output.outcome == .fail)
        #expect(output.results == .object([
            "reason": .string("no device matching the target advertised within the scan window"),
        ]))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("gatt-walk.json").path))
    }

    @Test func notifyLogsEventsAndCountsBytes() async throws {
        let events = [NotifyEvent(t: 0.5, payload: "10486e"),
                      NotifyEvent(t: 1.5, payload: "1049")]
        let tool = WireNotifyTool(radio: ScriptedRadio(notifyResult: .success(events)))
        let output = try await tool.run(context(["device": "Polar", "characteristic": "2A37"]))
        #expect(output.outcome == .pass)
        #expect(output.results == .object([
            "durationSeconds": .number(30),
            "events": .number(2),
            "bytes": .number(5),
        ]))
        let capture = String(decoding: try Data(contentsOf: directory.appendingPathComponent("notify-log.jsonl")),
                             as: UTF8.self)
        #expect(capture == "{\"payload\":\"10486e\",\"t\":0.5}\n{\"payload\":\"1049\",\"t\":1.5}\n")
    }

    @Test func notifyOfAMissingCharacteristicFails() async throws {
        let tool = WireNotifyTool(radio: ScriptedRadio(
            notifyResult: .failure(.characteristicNotFound("the device offers no characteristic 2A37"))))
        let output = try await tool.run(context(["device": "Polar", "characteristic": "2A37"]))
        #expect(output.outcome == .fail)
        #expect(output.results == .object([
            "reason": .string("the device offers no characteristic 2A37"),
        ]))
    }

    @Test func targetsParseAsUuidOrNamePrefix() {
        #expect(WireTarget(pineTime.uuidString) == .peripheral(pineTime))
        #expect(WireTarget("Polar Sense") == .namePrefix("Polar Sense"))
        #expect(WireTarget(pineTime.uuidString).matches(peripheral: pineTime, name: nil))
        #expect(!WireTarget(pineTime.uuidString).matches(peripheral: verity, name: "InfiniTime"))
        #expect(WireTarget("Polar").matches(peripheral: verity, name: "Polar Sense C0FFEE"))
        #expect(!WireTarget("Polar").matches(peripheral: verity, name: nil))
    }

    @Test func gattPropertyNamesFollowTheBitField() {
        #expect(GattSurvey.Characteristic.propertyNames(mask: 0x02 | 0x10) == ["read", "notify"])
        #expect(GattSurvey.Characteristic.propertyNames(mask: 0x04 | 0x08) == ["writeWithoutResponse", "write"])
        #expect(GattSurvey.Characteristic.propertyNames(mask: 0) == [])
    }

    @Test func theWireCatalogueRegistersItsThreeTools() throws {
        let registry = try BenchToolRegistry(catalogues: [
            WireCatalogue.catalogue(radio: ScriptedRadio()),
        ])
        #expect(registry.tools.map(\.name) == ["wire.notify", "wire.scan", "wire.survey"])
        #expect(registry.tool(named: "wire.survey")?.declaredArguments.contains {
            $0.name == "device" && $0.required
        } == true)
    }
}
