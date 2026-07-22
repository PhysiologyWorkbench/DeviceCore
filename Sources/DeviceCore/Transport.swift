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

public enum TransportError: Error, Sendable, Equatable {
    case bluetoothUnavailable(String)
    case connectTimeout
    case notConnected
    case writeFailed(String)
    case unknownPeripheral
}

/// The BLE side. Knows nothing about the Lovense protocol — it moves bytes.
public protocol Transport: Sendable {
    /// Resolves when Bluetooth is powered on; throws `bluetoothUnavailable` otherwise.
    func waitUntilPoweredOn() async throws
    /// Discoveries matching the catalog's scan filters. Scanning stops when the
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
    /// Writes command bytes. Prefers write-without-response when the characteristic
    /// offers it. Returns whether the bytes were sent (always true for `.wait`).
    @discardableResult
    func write(_ bytes: Data, ifBusy: BusyPolicy) async throws -> Bool
    func disconnect() async
}

public extension DeviceConnection {
    /// Convenience: write and wait for the link to be ready.
    @discardableResult
    func write(_ bytes: Data) async throws -> Bool {
        try await write(bytes, ifBusy: .wait)
    }
}
