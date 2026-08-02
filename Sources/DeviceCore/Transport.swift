import Foundation
import CoreBluetooth

// Core vocabulary shared across the package: the value types describing devices
// and connections, and the `Transport`/`DeviceConnection` protocols that the BLE
// layer implements and the (future) session layer consumes. This is the package's
// abstract API surface — not a "model" in the MVC sense; there is no view here.
// Concrete BLE lives in `BleTransport.swift`; device data in `DeviceCatalog.swift`.

/// Stable, host-scoped identity of a peripheral (`CBPeripheral.identifier`).
public struct PeripheralID: Hashable, Sendable {
    public let uuid: UUID
    public init(_ uuid: UUID) { self.uuid = uuid }
}

public struct Discovery: @unchecked Sendable {
    public let id: PeripheralID
    public let name: String
    public let rssi: Int
    public let services: [CBUUID]
}

/// What a scan matches on: an advertised name prefix **or** an advertised service
/// UUID (either is sufficient). Device-neutral — the Lovense catalog and the HR
/// profile each supply their own.
public struct ScanFilter: @unchecked Sendable {
    public let namePrefixes: [String]
    public let serviceUUIDs: [CBUUID]
    public init(namePrefixes: [String], serviceUUIDs: [CBUUID]) {
        self.namePrefixes = namePrefixes
        self.serviceUUIDs = serviceUUIDs
    }
}

/// Picks the endpoints to bind on a connection, from one discovered service's
/// characteristics. This is the input/output seam (extends ARCHITECTURE principle
/// 4 to input): a serial toy resolves a writable tx + notify rx; a notify-only
/// sensor resolves rx alone.
public protocol EndpointResolver: Sendable {
    /// Given one discovered service's characteristics, return the endpoints to
    /// bind, or nil to skip this service. `tx` may be nil (notify-only devices);
    /// `rx` (the notify source, and the readiness signal) is mandatory.
    func resolve(service: CBUUID,
                 characteristics: [CBCharacteristic]) -> (tx: CBCharacteristic?, rx: CBCharacteristic)?
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
                        characteristics: [CBCharacteristic]) -> (tx: CBCharacteristic?, rx: CBCharacteristic)? {
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
                        characteristics: [CBCharacteristic]) -> (tx: CBCharacteristic?, rx: CBCharacteristic)? {
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
/// `.withResponse` exists because some vendors' own apps use Write Request (the
/// Lovense app does), and comparing the two is a measurement worth making.
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

/// The BLE side. Knows nothing about the Lovense protocol — it moves bytes.
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

/// A ready connection to one device. Delivers raw notification chunks; framing of
/// `;`-terminated Lovense messages belongs to the codec layer, not here.
public protocol DeviceConnection: Sendable {
    var id: PeripheralID { get }
    var inbound: AsyncStream<Data> { get }
    var state: AsyncStream<ConnectionState> { get }
    /// Writes command bytes with the requested write type, falling back to
    /// whichever the characteristic actually offers. Returns whether the bytes
    /// were sent (always true for `.wait` and for write-with-response).
    @discardableResult
    func write(_ bytes: Data, ifBusy: BusyPolicy, type: WriteType) async throws -> Bool
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
