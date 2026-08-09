import Foundation
import CoreBluetooth

// Core vocabulary shared across the library: the value types describing devices
// and connections, and the `Transport`/`DeviceConnection` protocols that the BLE
// layer implements and the session layer consumes. This is the library's abstract
// API surface — not a "model" in the MVC sense; there is no view here. Concrete
// BLE lives in `BleTransport.swift`; a device's catalogue, if it has one, lives in
// its vendor kit.

/// Stable, host-scoped identity of a peripheral (`CBPeripheral.identifier`).
public struct PeripheralID: Hashable, Sendable {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

/// Manufacturer-specific advertisement data, split from CoreBluetooth's single
/// blob: 2-byte little-endian company identifier + vendor payload.
public struct ManufacturerData: Sendable, Equatable {
    public let companyID: UInt16
    public let payload: Data
    public init?(advertisementBlob: Data) {
        guard advertisementBlob.count >= 2 else { return nil }
        companyID = UInt16(advertisementBlob[advertisementBlob.startIndex])
                  | UInt16(advertisementBlob[advertisementBlob.startIndex + 1]) << 8
        payload = Data(advertisementBlob.dropFirst(2))
    }
}

public struct Discovery: @unchecked Sendable {
    public let id: PeripheralID
    public let name: String
    public let rssi: Int
    public let services: [CBUUID]
    /// Manufacturer data from the advertisement, if present. May be nil even for
    /// a device that does advertise it: discoveries are coalesced, and the packet
    /// that surfaced this peripheral may have lacked the field.
    public let manufacturer: ManufacturerData?
}

/// What a scan matches on: an advertised name prefix, an advertised service UUID,
/// **or** a manufacturer company identifier (any one is sufficient). Device-neutral
/// — a vendor kit's catalogue and the standard HR profile each supply their own.
/// Company-id matching is deliberately coarse; narrowing on the manufacturer
/// payload (e.g. a model id) is the kit's job, off `Discovery.manufacturer`.
public struct ScanFilter: @unchecked Sendable {
    public let namePrefixes: [String]
    public let serviceUUIDs: [CBUUID]
    public let manufacturerIDs: [UInt16]
    public init(namePrefixes: [String], serviceUUIDs: [CBUUID], manufacturerIDs: [UInt16] = []) {
        self.namePrefixes = namePrefixes
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerIDs = manufacturerIDs
    }
}

/// Picks the endpoints to bind on a connection, from one discovered service's
/// characteristics. This is the input/output seam (extends ARCHITECTURE principle
/// 5 to input): a serial toy resolves a writable tx + notify rx; a notify-only
/// sensor resolves rx alone; a write-only device resolves tx alone.
public protocol EndpointResolver: Sendable {
    /// Given one discovered service's characteristics, return the endpoints to
    /// bind, or nil to skip this service. A non-nil return must bind at least one
    /// endpoint. `rx` is the notify source and, when bound, the readiness signal.
    /// `rx == nil` means a write-only device: the connection becomes ready once
    /// every service's characteristics have been discovered, and `inbound` never
    /// yields (it finishes on disconnect).
    func resolve(service: CBUUID,
                 characteristics: [CBCharacteristic]) -> (tx: CBCharacteristic?, rx: CBCharacteristic?)?
}

/// Binds a single notify characteristic (UUID `rx`) as the readiness/inbound
/// source, with no writable tx. `service` scopes it to one service, or nil to
/// accept the characteristic in whichever service carries it.
public struct NotifyEndpointResolver: EndpointResolver, @unchecked Sendable {
    let service: CBUUID?
    let rx: CBUUID
    public init(service: CBUUID?, rx: CBUUID) {
        self.service = service
        self.rx = rx
    }
    public func resolve(service: CBUUID,
                        characteristics: [CBCharacteristic]) -> (tx: CBCharacteristic?, rx: CBCharacteristic?)? {
        guard self.service == nil || self.service == service else { return nil }
        guard let notify = characteristics.first(where: { $0.uuid == rx }) else { return nil }
        return (tx: nil, rx: notify)
    }
}

/// Binds an explicit writable `tx` and notify `rx` by UUID within one service —
/// for devices with a known control-point + data-stream characteristic pair, where
/// neither the serial heuristic nor the notify-only resolver fits.
public struct FixedEndpointResolver: EndpointResolver, @unchecked Sendable {
    let service: CBUUID
    let tx: CBUUID
    let rx: CBUUID
    public init(service: CBUUID, tx: CBUUID, rx: CBUUID) {
        self.service = service
        self.tx = tx
        self.rx = rx
    }
    public func resolve(service: CBUUID,
                        characteristics: [CBCharacteristic]) -> (tx: CBCharacteristic?, rx: CBCharacteristic?)? {
        guard self.service == service else { return nil }
        guard let txChar = characteristics.first(where: { $0.uuid == tx }),
              let rxChar = characteristics.first(where: { $0.uuid == rx }) else { return nil }
        return (tx: txChar, rx: rxChar)
    }
}

public enum ConnectionState: Sendable, Equatable {
    case ready
    case disconnected(reason: String?)
}

/// How `write` behaves when the write-without-response buffer is full. Only
/// meaningful for the write-without-response path; ignored for write-with-response.
public enum BusyPolicy: Sendable {
    /// Suspend until the link can accept the write, then send. Guarantees delivery.
    case wait
    /// Skip this write and report it as not sent. Correct for a coalescing sender
    /// that will supersede it on the next tick.
    case drop
}

/// Which GATT write to use when the tx characteristic advertises both. The
/// default keeps the low-latency unacknowledged path every shipping caller wants;
/// `.withResponse` exists because some vendors' own apps use Write Request, and
/// comparing the two is a measurement worth making.
public enum WriteType: Sendable {
    case preferWithoutResponse
    case withResponse
}

public enum TransportError: Error, Sendable, Equatable {
    case bluetoothUnavailable(String)
    case connectTimeout
    case connectFailed(String)
    case notConnected
    case unknownPeripheral
    /// A required characteristic is missing, or the tx characteristic is not writable.
    case characteristicNotFound(String)
    case writeFailed(String)
    case readFailed(String)
}

extension TransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let state): return "Bluetooth unavailable (\(state))"
        case .connectTimeout: return "Connection timed out"
        case .connectFailed(let detail): return "Connection failed: \(detail)"
        case .notConnected: return "Device not connected"
        case .unknownPeripheral: return "Unknown device"
        case .characteristicNotFound(let detail): return "Characteristic not found: \(detail)"
        case .writeFailed(let detail): return "Write failed: \(detail)"
        case .readFailed(let detail): return "Read failed: \(detail)"
        }
    }
}

/// The BLE side. Knows no vendor's protocol — it moves bytes.
public protocol Transport: Sendable {
    /// Resolves when Bluetooth is powered on; throws `bluetoothUnavailable` otherwise.
    func waitUntilPoweredOn() async throws
    /// Discoveries matching the transport's `ScanFilter`. Scanning stops when the
    /// stream is terminated.
    func scan() -> AsyncStream<Discovery>
    /// Connects and resolves once the device is ready (serial endpoints found and
    /// notifications subscribed).
    func connect(_ id: PeripheralID, timeout: Duration) async throws -> DeviceConnection
}

/// A ready connection to one device. Delivers raw notification chunks; splitting a
/// chunk into a vendor's messages belongs to that vendor's codec, not here.
public protocol DeviceConnection: Sendable {
    var id: PeripheralID { get }
    var inbound: AsyncStream<Data> { get }
    var state: AsyncStream<ConnectionState> { get }
    /// Writes command bytes with the requested write type, falling back to
    /// whichever the characteristic actually offers. Returns whether the bytes
    /// were sent (always true for `.wait` and for write-with-response).
    @discardableResult
    func write(_ bytes: Data, ifBusy: BusyPolicy, type: WriteType) async throws -> Bool
    /// Writes to a specific discovered characteristic (any service found during
    /// connect setup, not only the resolver's tx) — for one-shot control writes,
    /// e.g. an init byte a device requires before accepting commands. Same
    /// `BusyPolicy`/`WriteType` semantics as `write(_:ifBusy:type:)`.
    @discardableResult
    func write(_ bytes: Data, to characteristic: CBUUID, ifBusy: BusyPolicy, type: WriteType) async throws -> Bool
    /// Reads a GATT characteristic's current value directly (e.g. standard Battery
    /// Level, `0x180F`/`0x2A19`) — for values that are read, not pushed over a
    /// serial notify channel. The characteristic must have been discovered
    /// (any service found during connect setup qualifies, not only the endpoint
    /// resolver's match).
    func read(characteristic: CBUUID) async throws -> Data
    /// Enables notifications on an additional discovered characteristic and returns
    /// its own inbound stream, distinct from `inbound` (the resolver's rx). For
    /// devices whose control-point responses arrive on a second notify
    /// characteristic. Resolves once the subscription is confirmed, so a following
    /// command write cannot race ahead of it. The stream ends when the connection
    /// drops.
    func subscribe(_ characteristic: CBUUID) async throws -> AsyncStream<Data>
    func disconnect() async
}

public extension DeviceConnection {
    /// Convenience: write with the default write type.
    @discardableResult
    func write(_ bytes: Data, ifBusy: BusyPolicy) async throws -> Bool {
        try await write(bytes, ifBusy: ifBusy, type: .preferWithoutResponse)
    }
    /// Convenience: write and wait for the link to be ready.
    @discardableResult
    func write(_ bytes: Data) async throws -> Bool {
        try await write(bytes, ifBusy: .wait, type: .preferWithoutResponse)
    }
}
