import Foundation

/// The generic wire-analysis value types (R46: vendor-agnostic by
/// construction — the Pine64 story is a survey against a device no kit
/// supports). Pure data, shared by the `wire.*` tools, their captures, and
/// whatever radio produces them; nothing here touches CoreBluetooth.

/// One advertisement as seen during a scan window. `t` is seconds since the
/// scan started; wall time is the run record's `started`.
public struct AdvertisementEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var peripheral: UUID
    public var name: String?
    public var rssi: Int
    /// Advertised service UUIDs as CoreBluetooth prints them (`180D`, or the
    /// full 128-bit form).
    public var services: [String]
    /// The manufacturer-specific blob, hex; `companyID` is its first two
    /// bytes little-endian (the Bluetooth SIG company identifier).
    public var manufacturerData: String?
    public var companyID: Int?
    public var serviceData: [String: String]?
    public var txPower: Int?
    public var connectable: Bool?

    public init(t: Double, peripheral: UUID, name: String? = nil, rssi: Int,
                services: [String] = [], manufacturerData: String? = nil,
                companyID: Int? = nil, serviceData: [String: String]? = nil,
                txPower: Int? = nil, connectable: Bool? = nil) {
        self.t = t
        self.peripheral = peripheral
        self.name = name
        self.rssi = rssi
        self.services = services
        self.manufacturerData = manufacturerData
        self.companyID = companyID
        self.serviceData = serviceData
        self.txPower = txPower
        self.connectable = connectable
    }
}

/// A full GATT walk of one connected device: every service, characteristic
/// and descriptor UUID, with the value of each readable characteristic (hex;
/// nil when the read failed or the characteristic is not readable).
public struct GattSurvey: Codable, Equatable, Sendable {
    public var peripheral: UUID
    public var name: String?
    public var services: [Service]

    public struct Service: Codable, Equatable, Sendable {
        public var uuid: String
        public var isPrimary: Bool
        public var characteristics: [Characteristic]

        public init(uuid: String, isPrimary: Bool, characteristics: [Characteristic]) {
            self.uuid = uuid
            self.isPrimary = isPrimary
            self.characteristics = characteristics
        }
    }

    public struct Characteristic: Codable, Equatable, Sendable {
        public var uuid: String
        public var properties: [String]
        public var value: String?
        public var descriptors: [String]

        public init(uuid: String, properties: [String], value: String? = nil,
                    descriptors: [String] = []) {
            self.uuid = uuid
            self.properties = properties
            self.value = value
            self.descriptors = descriptors
        }

        /// The GATT characteristic-properties bit field as names, in bit
        /// order — the wire's own layout, which CoreBluetooth's raw value
        /// mirrors.
        public static func propertyNames(mask: UInt) -> [String] {
            let bits: [(UInt, String)] = [
                (0x001, "broadcast"), (0x002, "read"),
                (0x004, "writeWithoutResponse"), (0x008, "write"),
                (0x010, "notify"), (0x020, "indicate"),
                (0x040, "authenticatedSignedWrites"), (0x080, "extendedProperties"),
                (0x100, "notifyEncryptionRequired"), (0x200, "indicateEncryptionRequired"),
            ]
            return bits.filter { mask & $0.0 != 0 }.map(\.1)
        }
    }

    public init(peripheral: UUID, name: String? = nil, services: [Service]) {
        self.peripheral = peripheral
        self.name = name
        self.services = services
    }
}

/// One logged notification. `t` is seconds since notifications were enabled.
public struct NotifyEvent: Codable, Equatable, Sendable {
    public var t: Double
    public var payload: String

    public init(t: Double, payload: String) {
        self.t = t
        self.payload = payload
    }
}

/// How a wire tool names its device: a peripheral UUID when the string
/// parses as one, otherwise an advertised-name prefix.
public enum WireTarget: Equatable, Sendable {
    case peripheral(UUID)
    case namePrefix(String)

    public init(_ raw: String) {
        if let uuid = UUID(uuidString: raw) {
            self = .peripheral(uuid)
        } else {
            self = .namePrefix(raw)
        }
    }

    public func matches(peripheral: UUID, name: String?) -> Bool {
        switch self {
        case .peripheral(let uuid): uuid == peripheral
        case .namePrefix(let prefix): name?.hasPrefix(prefix) == true
        }
    }
}

/// Wire-operation failures. `deviceNotFound` and `characteristicNotFound`
/// are verdicts about the bench setup — the tools fold them into `.fail` —
/// the rest end a run as `.error`.
public enum WireError: Error, Equatable {
    case badArgument(String)
    case deviceNotFound(String)
    case characteristicNotFound(String)
    case bluetoothUnavailable(String)
    case disconnected(String)
    case timeout(String)
}

/// The capture serialisations: JSONL (one compact sorted-keys object per
/// line) for event logs, pretty for trees — deterministic either way, so a
/// rerun's capture diffs clean.
public enum WireJSON {
    public static func lines(_ events: [some Encodable]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        return data
    }

    public static func pretty(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

extension JSONValue {
    /// The value's JSON tree — how a typed result (a GATT survey) lands in
    /// `RunRecord.results` without the record knowing its shape.
    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
