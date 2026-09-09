import Foundation
import DeviceCore

/// The generic wire tools — the catalogue every host has before any vendor
/// kit is involved. Each takes its measurements through a `WireRadio`,
/// writes the raw capture, and summarises into the record's results.
public enum WireCatalogue {
    public static func catalogue(radio: any WireRadio) -> BenchCatalogue {
        BenchCatalogue(noun: "wire", tools: [
            WireScanTool(radio: radio),
            WireSurveyTool(radio: radio),
            WireNotifyTool(radio: radio),
        ], claimsRadio: true)
    }

    public static func live() -> BenchCatalogue {
        catalogue(radio: LiveWireRadio())
    }
}

/// `wire.scan` — a timed unfiltered scan. Capture: every advertisement as
/// JSONL. Results: totals plus a per-device summary. Seeing nothing is
/// still a pass — the verdict is on the radio work, not on the airwaves.
public struct WireScanTool: BenchTool {
    public let name = "wire.scan"
    public let synopsis = "timed unfiltered BLE scan; every advertisement captured"
    public let declaredArguments = [
        BenchToolArgument(name: "duration", help: "scan window in seconds (default 10)"),
    ]
    let radio: any WireRadio

    public init(radio: any WireRadio) {
        self.radio = radio
    }

    public func run(_ context: BenchContext) async throws -> BenchToolOutput {
        let window = try WireArguments.seconds(context.arguments["duration"],
                                               name: "duration", default: 10)
        let events = try await radio.advertisements(for: .seconds(window))
        try WireJSON.lines(events).write(to: context.captureURL("advertisements.jsonl"))
        return BenchToolOutput(outcome: .pass, results: .object([
            "durationSeconds": .number(window),
            "advertisements": .number(Double(events.count)),
            "devices": Self.deviceSummaries(of: events),
        ]))
    }

    /// Per-device rollup, sorted by peripheral UUID: advertisement count,
    /// RSSI spread (nearest-rank median), last seen name, advertised
    /// service union.
    static func deviceSummaries(of events: [AdvertisementEvent]) -> JSONValue {
        let byPeripheral = Dictionary(grouping: events, by: \.peripheral)
        let summaries = byPeripheral.keys.sorted { $0.uuidString < $1.uuidString }.map { peripheral in
            let seen = byPeripheral[peripheral]!
            let rssi = seen.map(\.rssi).sorted()
            let median = rssi[Int((0.5 * Double(rssi.count - 1)).rounded())]
            let name = seen.compactMap(\.name).last
            let services = Set(seen.flatMap(\.services)).sorted()
            return JSONValue.object([
                "peripheral": .string(peripheral.uuidString),
                "name": name.map(JSONValue.string) ?? .null,
                "advertisements": .number(Double(seen.count)),
                "rssi": .object(["min": .number(Double(rssi.first!)),
                                 "median": .number(Double(median)),
                                 "max": .number(Double(rssi.last!))]),
                "services": .array(services.map(JSONValue.string)),
            ])
        }
        return .array(summaries)
    }
}

/// `wire.survey` — find one device, walk its whole GATT tree, read what is
/// readable. Capture: the tree as `gatt-walk.json`. A device the window
/// never shows is a `.fail`, with the reason in the results.
public struct WireSurveyTool: BenchTool {
    public let name = "wire.survey"
    public let synopsis = "connect to one device and walk its full GATT tree"
    public let declaredArguments = [
        BenchToolArgument(name: "device", help: "peripheral UUID, or an advertised-name prefix",
                          required: true),
        BenchToolArgument(name: "scan-window", help: "seconds to look for the device (default 10)"),
    ]
    let radio: any WireRadio

    public init(radio: any WireRadio) {
        self.radio = radio
    }

    public func run(_ context: BenchContext) async throws -> BenchToolOutput {
        let window = try WireArguments.seconds(context.arguments["scan-window"],
                                               name: "scan-window", default: 10)
        let target = WireTarget(context.arguments["device"]!)
        let survey: GattSurvey
        do {
            survey = try await radio.survey(target, scanWindow: .seconds(window))
        } catch WireError.deviceNotFound(let reason) {
            return BenchToolOutput(outcome: .fail,
                                   results: .object(["reason": .string(reason)]))
        }
        try WireJSON.pretty(survey).write(to: context.captureURL("gatt-walk.json"))
        return BenchToolOutput(outcome: .pass, results: .object([
            "serviceCount": .number(Double(survey.services.count)),
            "characteristicCount": .number(Double(survey.services.map(\.characteristics.count).reduce(0, +))),
        ]), units: [Self.dutUnit(of: survey)])
    }

    /// The `dut` row a survey asserts (`unit-identity.md`, "What the bench
    /// writes"): the connection as a binding, the advertised name and the
    /// Device Information Service strings as claims.
    static func dutUnit(of survey: GattSurvey) -> PhysicalUnit {
        var claims: [String: String] = [:]
        claims["ble.name"] = survey.name
        for service in survey.services
        where service.uuid.uppercased() == DeviceInformationService.uuid {
            for characteristic in service.characteristics {
                guard let key = DeviceInformationService.claimKey(
                        forCharacteristic: characteristic.uuid),
                      let hex = characteristic.value,
                      let bytes = Data(hexString: hex) else { continue }
                claims[key] = DeviceInformationService.claimValue(bytes)
            }
        }
        return PhysicalUnit(role: .dut, claims: claims,
                               bindings: ["cb.peripheral": survey.peripheral.uuidString])
    }
}

/// `wire.notify` — subscribe to one characteristic and log every
/// notification. Capture: the timestamped payloads as JSONL. Zero events in
/// the window is a pass with `events: 0` on the record — silence is a
/// result. A missing device or characteristic is a `.fail`.
public struct WireNotifyTool: BenchTool {
    public let name = "wire.notify"
    public let synopsis = "log one characteristic's notifications for a window"
    public let declaredArguments = [
        BenchToolArgument(name: "device", help: "peripheral UUID, or an advertised-name prefix",
                          required: true),
        BenchToolArgument(name: "characteristic", help: "characteristic UUID (2A37, or 128-bit form)",
                          required: true),
        BenchToolArgument(name: "duration", help: "seconds to listen (default 30)"),
        BenchToolArgument(name: "scan-window", help: "seconds to look for the device (default 10)"),
    ]
    let radio: any WireRadio

    public init(radio: any WireRadio) {
        self.radio = radio
    }

    public func run(_ context: BenchContext) async throws -> BenchToolOutput {
        let listen = try WireArguments.seconds(context.arguments["duration"],
                                               name: "duration", default: 30)
        let window = try WireArguments.seconds(context.arguments["scan-window"],
                                               name: "scan-window", default: 10)
        let target = WireTarget(context.arguments["device"]!)
        let characteristic = context.arguments["characteristic"]!
        let events: [NotifyEvent]
        do {
            events = try await radio.notifications(from: target, characteristic: characteristic,
                                                   scanWindow: .seconds(window),
                                                   for: .seconds(listen))
        } catch WireError.deviceNotFound(let reason), WireError.characteristicNotFound(let reason) {
            return BenchToolOutput(outcome: .fail,
                                   results: .object(["reason": .string(reason)]))
        }
        try WireJSON.lines(events).write(to: context.captureURL("notify-log.jsonl"))
        return BenchToolOutput(outcome: .pass, results: .object([
            "durationSeconds": .number(listen),
            "events": .number(Double(events.count)),
            "bytes": .number(Double(events.map { $0.payload.count / 2 }.reduce(0, +))),
        ]))
    }
}

enum WireArguments {
    /// Seconds from an argument string; a malformed or non-positive value
    /// refuses the run (folded to `.error` by the runner).
    static func seconds(_ raw: String?, name: String, default defaultValue: Double) throws -> Double {
        guard let raw else { return defaultValue }
        guard let value = Double(raw), value > 0 else {
            throw WireError.badArgument("\(name) must be a positive number of seconds, got '\(raw)'")
        }
        return value
    }
}
