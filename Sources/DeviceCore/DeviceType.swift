import Foundation
import CoreBluetooth

// The device-type database, v0: what a *model* is and what it can do, as
// compiled-in data. The vocabulary lives here; the records live in the vendor
// kits (`PolarDeviceTypes.catalog` and friends) and an app composes them by
// concatenation. Design, and what it defers, in PWB's
// `design/device-type-db-v0.md`.
//
// This is the type half of the type/instance split. Nothing here describes a
// unit the user owns — one Edge 2's dead motor is a per-unit fact belonging to
// the registered-device registry, designed separately.

/// How well a fact is known. Carried per record and overridable per capability;
/// per-field provenance waits for the full schema.
public enum Provenance: String, Codable, Sendable {
    case tested
    case datasheetInferred = "datasheet-inferred"
    case userReported = "user-reported"
}

/// The controlled vocabulary of sensor modalities, defined centrally so that no
/// kit introduces one of its own. Raw values are the schema study's.
public enum Modality: String, Codable, Sendable, CaseIterable {
    case hr = "HR"
    case rr = "RR"
    case ecg = "ECG"
    case ppg = "PPG"
    case ppi = "PPI"
    case acc = "ACC"
    case gyro = "GYRO"
    case mag = "MAG"
}

/// What an actuator does. Vibration is the only kind the family drives today.
public enum ActuatorKind: String, Codable, Sendable {
    case vibration
}

/// How a device announces itself on request, for the setup step where the user
/// must tell look-alike devices apart. A pulse is user-initiated only: nothing
/// actuates as a side effect.
public enum IdentifyAction: Codable, Sendable, Equatable {
    case pulse(actuator: String)
    case none
}

/// Where a battery reading comes from, if anywhere.
public enum BatterySource: String, Codable, Sendable {
    /// The standard GATT Battery Service — `BatteryService`.
    case gattService = "gatt-service"
    /// A query on the device's own vendor channel, e.g. Lovense `Battery;`.
    case vendorQuery = "vendor-query"
    /// No battery telemetry of any kind. The UX owes an honest "unknown" here,
    /// not a zero.
    case none
}

/// Manufacturer-data constraint: the SIG company identifier, and optionally a
/// prefix the vendor payload must start with. An empty prefix matches the
/// company alone.
public struct ManufacturerDataMatch: Codable, Sendable, Equatable {
    public var companyID: UInt16
    public var payloadPrefix: Data

    public init(companyID: UInt16, payloadPrefix: Data = Data()) {
        self.companyID = companyID
        self.payloadPrefix = payloadPrefix
    }

    public func matches(_ data: ManufacturerData) -> Bool {
        data.companyID == companyID && data.payload.starts(with: payloadPrefix)
    }
}

/// Pre-connection identity: what an advertisement must look like for this record
/// to be a candidate. Every constraint the fingerprint states must hold (an
/// empty one states nothing); within a constraint, any one match suffices. A
/// fingerprint stating nothing matches nothing.
///
/// This is deliberately only half of identity. Matching an advertisement yields
/// *candidates*; where a vendor's models share their advertisement, `ProbeRef`
/// settles which one it is after connecting.
public struct Fingerprint: Codable, Sendable {
    /// Matched case-insensitively: Lovense's Gemini advertises `lvs gemi`
    /// where its siblings advertise `LVS-…` (LOVENSE.md).
    public var namePrefixes: [String]
    /// Advertised service UUIDs, not discovered ones — 16-, 32- and 128-bit
    /// forms compare equal.
    public var serviceUUIDs: [String]
    public var manufacturerData: ManufacturerDataMatch?

    public init(namePrefixes: [String] = [],
                serviceUUIDs: [String] = [],
                manufacturerData: ManufacturerDataMatch? = nil) {
        self.namePrefixes = namePrefixes
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
    }

    public func matches(_ discovery: Discovery) -> Bool {
        var stated = false
        if !namePrefixes.isEmpty {
            stated = true
            let name = discovery.name.lowercased()
            guard namePrefixes.contains(where: { name.hasPrefix($0.lowercased()) }) else { return false }
        }
        if !serviceUUIDs.isEmpty {
            stated = true
            let advertised = Set(discovery.services.map { Self.canonical($0.uuidString) })
            guard serviceUUIDs.contains(where: { advertised.contains(Self.canonical($0)) }) else { return false }
        }
        if let manufacturerData {
            stated = true
            guard let m = discovery.manufacturer, manufacturerData.matches(m) else { return false }
        }
        return stated
    }

    /// Expands a 16- or 32-bit UUID onto the Bluetooth base UUID so that the
    /// short form a record spells and the form CoreBluetooth reports compare
    /// equal. Parsing rather than `CBUUID(string:)` because that traps on a
    /// malformed string, and these strings become external data the day the
    /// catalogue leaves the binary.
    static func canonical(_ uuid: String) -> String {
        let s = uuid.uppercased().hasPrefix("0X") ? String(uuid.dropFirst(2)) : uuid
        switch s.count {
        case 4: return "0000\(s.uppercased())-0000-1000-8000-00805F9B34FB"
        case 8: return "\(s.uppercased())-0000-1000-8000-00805F9B34FB"
        default: return s.uppercased()
        }
    }
}

/// Post-connection confirmation, named rather than described: the kit owning
/// this record resolves `handler` to its own code, because identity queries are
/// protocol, and protocol is not data in v0. `expect` is what that code must
/// report back for the record to be the answer.
public struct ProbeRef: Codable, Sendable, Equatable {
    public var handler: String
    public var expect: String?

    public init(handler: String, expect: String? = nil) {
        self.handler = handler
        self.expect = expect
    }
}

/// A measured commanded-step → produced-output curve: the type-level prior a
/// per-unit calibration is a delta against. Every v0 record carries `nil`, so
/// the UX can say "no baseline recorded" honestly; the curve's own shape is
/// settled with the calibration work, not here.
public struct CalibrationBaseline: Codable, Sendable {
    /// One measured pair on that curve: the commanded `step` and the `output`
    /// it produced, in the baseline's `unit`.
    public struct Point: Codable, Sendable {
        public var step: Int
        public var output: Double

        public init(step: Int, output: Double) {
            self.step = step
            self.output = output
        }
    }

    public var unit: String
    public var points: [Point]
    public var measuredAt: Date

    public init(unit: String, points: [Point], measuredAt: Date) {
        self.unit = unit
        self.points = points
        self.measuredAt = measuredAt
    }
}

/// One stream a model can produce. `sampleRatesHz` lists the rates the device
/// offers; it is empty for a stream that has no rate to choose — a notify-driven
/// GATT profile, or an interval stream arriving as the beats do.
public struct SensorCapability: Codable, Sendable {
    public var id: String
    public var modality: Modality
    public var unit: String
    public var sampleRatesHz: [Double]
    /// IEEE 11073-10101 reference identifier, where one is uncontroversial.
    public var mdcCode: String?
    /// Overrides the record's provenance when this one channel is better or
    /// worse known than the model as a whole.
    public var provenance: Provenance?

    public init(id: String,
                modality: Modality,
                unit: String,
                sampleRatesHz: [Double] = [],
                mdcCode: String? = nil,
                provenance: Provenance? = nil) {
        self.id = id
        self.modality = modality
        self.unit = unit
        self.sampleRatesHz = sampleRatesHz
        self.mdcCode = mdcCode
        self.provenance = provenance
    }
}

/// One thing a model can drive. `stepRange` is the raw range the protocol
/// accepts, not a normalised one — 0…20 for Lovense, 0…100 for Satisfyer.
public struct ActuatorCapability: Codable, Sendable {
    public var id: String
    public var kind: ActuatorKind
    public var stepRange: ClosedRange<Int>
    public var baseline: CalibrationBaseline?
    public var provenance: Provenance?

    public init(id: String,
                kind: ActuatorKind,
                stepRange: ClosedRange<Int>,
                baseline: CalibrationBaseline? = nil,
                provenance: Provenance? = nil) {
        self.id = id
        self.kind = kind
        self.stepRange = stepRange
        self.baseline = baseline
        self.provenance = provenance
    }
}

/// One model of one vendor.
public struct DeviceTypeRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var vendor: String
    public var displayName: String
    public var fingerprint: Fingerprint
    public var probe: ProbeRef?
    public var sensors: [SensorCapability]
    public var actuators: [ActuatorCapability]
    public var identify: IdentifyAction
    public var battery: BatterySource
    public var provenance: Provenance
    public var references: [String]

    public init(id: String,
                vendor: String,
                displayName: String,
                fingerprint: Fingerprint,
                probe: ProbeRef? = nil,
                sensors: [SensorCapability] = [],
                actuators: [ActuatorCapability] = [],
                identify: IdentifyAction = .none,
                battery: BatterySource = .none,
                provenance: Provenance,
                references: [String] = []) {
        self.id = id
        self.vendor = vendor
        self.displayName = displayName
        self.fingerprint = fingerprint
        self.probe = probe
        self.sensors = sensors
        self.actuators = actuators
        self.identify = identify
        self.battery = battery
        self.provenance = provenance
        self.references = references
    }
}

/// The records an app knows about, composed from whichever kits it links. It
/// answers what an advertisement might be; what a model can do and what
/// affordances its row gets are the record's own fields.
public struct DeviceTypeCatalog: Sendable {
    public let records: [DeviceTypeRecord]

    public init(_ records: [DeviceTypeRecord]) {
        self.records = records
    }

    public func record(id: String) -> DeviceTypeRecord? {
        records.first { $0.id == id }
    }

    /// Every record this advertisement could be. More than one is the normal
    /// case for a vendor whose models advertise alike; the caller then runs the
    /// kit's probe and keeps the candidate whose `probe.expect` it met. None
    /// left standing is "supported vendor, unknown model" — a state to render,
    /// never a record to invent.
    public func candidates(for discovery: Discovery) -> [DeviceTypeRecord] {
        records.filter { $0.fingerprint.matches(discovery) }
    }
}
