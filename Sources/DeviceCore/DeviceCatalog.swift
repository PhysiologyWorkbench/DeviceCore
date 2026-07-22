import Foundation
import CoreBluetooth

/// A device feature projected from the vendored config. `index` is the actuator
/// slot the protocol layer addresses (e.g. `Vibrate2:n;`); `range` is the raw
/// value range the toy accepts. Unmodelled output kinds fall through to `.other`
/// so the actuator index is never lost.
public enum Feature: Sendable, Equatable {
    case vibrate(index: Int, range: ClosedRange<Int>)
    case rotate(index: Int, range: ClosedRange<Int>)
    case constrict(index: Int, range: ClosedRange<Int>)
    case battery(index: Int, range: ClosedRange<Int>)
    case other(kind: String, index: Int, range: ClosedRange<Int>)
}

/// Parses the vendored Buttplug device config (currently only the Lovense subset)
/// and answers identity/feature/endpoint queries. Pure data: no BLE, no command
/// encoding.
public struct DeviceCatalog: @unchecked Sendable {
    /// Bundled config resource (a Buttplug build artifact). Single source of truth
    /// for the filename; re-syncing the config replaces the file, not this name.
    public static let defaultConfigResource = "buttplug-device-config-v5"

    /// Advertised-name prefixes to match while scanning, e.g. `["LVS-", "LOVE-"]`.
    public let namePrefixes: [String]
    /// Advertised service UUIDs, for a service-filtered scan.
    public let advertisedServiceUUIDs: [CBUUID]

    private let endpointsByService: [CBUUID: SerialEndpoints]
    private let modelsByIdentifier: [String: Model]
    private let generic: Model

    public struct SerialEndpoints: @unchecked Sendable, Equatable {
        public let service: CBUUID
        public let tx: CBUUID   // host writes commands here
        public let rx: CBUUID   // host receives notifications here
    }

    public struct Model: Sendable, Equatable {
        public let identifier: String
        public let name: String
        public let features: [Feature]
        public let isGeneric: Bool
    }

    public init(resource: String = DeviceCatalog.defaultConfigResource) throws {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let node = try Self.decodeNode(Lovense.protocolKey, from: try Data(contentsOf: url))

        let btle = node.communication.first?.btle
        namePrefixes = (btle?.names ?? []).map { $0.hasSuffix("*") ? String($0.dropLast()) : $0 }
        advertisedServiceUUIDs = (btle?.advertised_services ?? []).map(CBUUID.init(string:))

        var endpoints: [CBUUID: SerialEndpoints] = [:]
        for (service, ep) in btle?.services ?? [:] {
            let s = CBUUID(string: service)
            endpoints[s] = SerialEndpoints(service: s, tx: CBUUID(string: ep.tx), rx: CBUUID(string: ep.rx))
        }
        endpointsByService = endpoints

        var models: [String: Model] = [:]
        for cfg in node.configurations {
            // A configuration may omit `features` and inherit the defaults.
            let rawFeatures = cfg.features ?? node.defaults.features
            let model = Model(identifier: cfg.identifier.first ?? "",
                              name: cfg.name,
                              features: rawFeatures.map(Feature.init(raw:)),
                              isGeneric: false)
            for id in cfg.identifier { models[id] = model }
        }
        modelsByIdentifier = models
        generic = Model(identifier: "",
                        name: node.defaults.name,
                        features: node.defaults.features.map(Feature.init(raw:)),
                        isGeneric: true)
    }

    /// Returns the known serial endpoints for whichever discovered service we
    /// recognise, or nil so the caller can fall back to a property heuristic.
    public func serialEndpoints(amongDiscovered discovered: [CBUUID]) -> SerialEndpoints? {
        discovered.lazy.compactMap { endpointsByService[$0] }.first
    }

    /// Resolves a `DeviceType;` code (and optional firmware) to a model. Unknown →
    /// generic profile so the toy is still controllable.
    public func model(forDeviceType code: String, firmware: Int?) -> Model {
        modelsByIdentifier[Lovense.resolveIdentifier(code, firmware: firmware)] ?? generic
    }

    /// Extracts one named protocol node from the Buttplug config and decodes it,
    /// so we never parse the other ~136 protocols with their differing shapes.
    private static func decodeNode(_ name: String, from data: Data) throws -> RawNode {
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let protocols = top?["protocols"] as? [String: Any],
              let node = protocols[name] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(RawNode.self, from: JSONSerialization.data(withJSONObject: node))
    }
}

// MARK: - Feature projection

private extension Feature {
    /// Buttplug output kinds modelled as first-class `Feature` cases. Enum cases
    /// double as constructors, so this table maps kind → case directly.
    static let outputBuilders: [String: @Sendable (Int, ClosedRange<Int>) -> Feature] = [
        "vibrate": Feature.vibrate,
        "rotate": Feature.rotate,
        "constrict": Feature.constrict,
    ]

    init(raw: DeviceCatalog.RawFeature) {
        if let (kind, spec) = raw.output?.first {
            let range = (spec.value.first ?? 0)...(spec.value.last ?? 0)
            self = Feature.outputBuilders[kind]?(raw.index, range)
                ?? .other(kind: kind, index: raw.index, range: range)
        } else if let battery = raw.input?["battery"] {
            let v = battery.value.first ?? [0, 100]
            self = .battery(index: raw.index, range: (v.first ?? 0)...(v.last ?? 100))
        } else {
            self = .other(kind: "unknown", index: raw.index, range: 0...0)
        }
    }
}

// MARK: - Raw config decoding (one protocol subtree)

extension DeviceCatalog {
    struct RawNode: Decodable {
        let communication: [RawComm]
        let configurations: [RawConfig]
        let defaults: RawDefaults
    }
    struct RawComm: Decodable { let btle: RawBtle? }
    struct RawBtle: Decodable {
        let names: [String]?
        let advertised_services: [String]?
        let services: [String: RawEndpoint]?
    }
    struct RawEndpoint: Decodable { let tx: String; let rx: String }
    struct RawConfig: Decodable {
        let identifier: [String]
        let name: String
        let features: [RawFeature]?
    }
    struct RawDefaults: Decodable {
        let name: String
        let features: [RawFeature]
    }
    struct RawFeature: Decodable {
        let index: Int
        let output: [String: RawValue]?
        let input: [String: RawInput]?
    }
    struct RawValue: Decodable { let value: [Int] }
    struct RawInput: Decodable { let value: [[Int]] }
}
