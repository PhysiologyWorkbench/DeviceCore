import Foundation
@preconcurrency import CoreBluetooth

/// CoreBluetooth-backed `Transport`. All CoreBluetooth state is confined to a
/// single serial queue; async methods bridge the delegate callbacks via
/// continuations and `AsyncStream`. Platform-identical across macOS/iOS/iPadOS.
public final class BleTransport: NSObject, Transport, CBCentralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.lelut.ble.transport")
    private let scanFilter: ScanFilter
    private let resolver: EndpointResolver
    private var central: CBCentralManager!

    private var poweredOn = false
    private var powerError: TransportError?
    private var powerWaiters: [CheckedContinuation<Void, Error>] = []

    private var scanContinuation: AsyncStream<Discovery>.Continuation?
    private var discovered: [UUID: CBPeripheral] = [:]

    private var connections: [UUID: BleConnection] = [:]
    private var connectWaiters: [UUID: CheckedContinuation<DeviceConnection, Error>] = [:]

    public init(scanFilter: ScanFilter, resolver: EndpointResolver) {
        self.scanFilter = scanFilter
        self.resolver = resolver
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: Transport

    public func waitUntilPoweredOn() async throws {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if self.poweredOn { cont.resume() }
                else if let e = self.powerError { cont.resume(throwing: e) }
                else { self.powerWaiters.append(cont) }
            }
        }
    }

    public func scan() -> AsyncStream<Discovery> {
        AsyncStream { continuation in
            queue.async {
                self.scanContinuation = continuation
                if self.poweredOn { self.central.scanForPeripherals(withServices: nil) }
            }
            continuation.onTermination = { _ in
                self.queue.async {
                    self.central.stopScan()
                    self.scanContinuation = nil
                }
            }
        }
    }

    public func connect(_ id: PeripheralID, timeout: Duration) async throws -> DeviceConnection {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let peripheral = self.discovered[id.uuid] else {
                    cont.resume(throwing: TransportError.unknownPeripheral); return
                }
                let conn = BleConnection(peripheral: peripheral, central: self.central,
                                         resolver: self.resolver, queue: self.queue)
                conn.onReady = { [weak self] in self?.finishConnect(id.uuid, .success(conn)) }
                conn.onFailure = { [weak self] err in self?.finishConnect(id.uuid, .failure(err)) }
                self.connections[id.uuid] = conn
                self.connectWaiters[id.uuid] = cont
                peripheral.delegate = conn
                self.central.connect(peripheral)

                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                self.queue.asyncAfter(deadline: .now() + seconds) {
                    guard self.connectWaiters[id.uuid] != nil else { return }
                    self.central.cancelPeripheralConnection(peripheral)
                    self.finishConnect(id.uuid, .failure(TransportError.connectTimeout))
                }
            }
        }
    }

    // MARK: Helpers (queue-confined)

    private func finishConnect(_ uuid: UUID, _ result: Result<DeviceConnection, Error>) {
        guard let waiter = connectWaiters.removeValue(forKey: uuid) else { return }
        if case .failure = result { connections[uuid] = nil }
        waiter.resume(with: result)
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            poweredOn = true
            powerWaiters.forEach { $0.resume() }
            powerWaiters.removeAll()
            if scanContinuation != nil { central.scanForPeripherals(withServices: nil) }
        case .unauthorized, .poweredOff, .unsupported:
            let err = TransportError.bluetoothUnavailable(String(describing: central.state))
            powerError = err
            powerWaiters.forEach { $0.resume(throwing: err) }
            powerWaiters.removeAll()
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let nameMatch = scanFilter.namePrefixes.contains { name.hasPrefix($0) }
        let serviceMatch = !Set(services).isDisjoint(with: scanFilter.serviceUUIDs)
        guard nameMatch || serviceMatch else { return }

        discovered[peripheral.identifier] = peripheral
        scanContinuation?.yield(Discovery(id: PeripheralID(peripheral.identifier),
                                          name: name, rssi: RSSI.intValue, services: services))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connections[peripheral.identifier]?.centralDidConnect()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnect(peripheral.identifier, .failure(TransportError.connectFailed(error?.localizedDescription ?? "connect failed")))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connections[peripheral.identifier]?.centralDidDisconnect(reason: error?.localizedDescription)
        connections[peripheral.identifier] = nil
        // If it dropped mid-connect, unblock the waiter.
        finishConnect(peripheral.identifier, .failure(TransportError.notConnected))
    }
}

/// One ready connection. Acts as its peripheral's `CBPeripheralDelegate`. All
/// state is touched only on the shared transport queue.
final class BleConnection: NSObject, DeviceConnection, CBPeripheralDelegate, @unchecked Sendable {
    let id: PeripheralID
    let inbound: AsyncStream<Data>
    let state: AsyncStream<ConnectionState>

    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private let peripheral: CBPeripheral
    private let central: CBCentralManager
    private let resolver: EndpointResolver
    private let queue: DispatchQueue
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    private var tx: CBCharacteristic?
    private var rx: CBCharacteristic?
    private var ready = false

    /// Every characteristic discovered across all services, keyed by UUID — not
    /// just the endpoint resolver's tx/rx match — so `read(characteristic:)` can
    /// reach e.g. the standard Battery Level characteristic.
    private var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]

    /// Waiters for a write-with-response ACK, FIFO.
    private var responseWaiters: [CheckedContinuation<Bool, Error>] = []
    /// Queued write-without-response payloads awaiting link readiness, FIFO.
    private var pendingWrites: [(Data, CheckedContinuation<Bool, Error>)] = []
    /// Waiters for a characteristic read, FIFO per characteristic.
    private var readWaiters: [CBUUID: [CheckedContinuation<Data, Error>]] = [:]

    init(peripheral: CBPeripheral, central: CBCentralManager, resolver: EndpointResolver, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.central = central
        self.resolver = resolver
        self.queue = queue
        self.id = PeripheralID(peripheral.identifier)
        var inboundCont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { inboundCont = $0 }
        self.inboundContinuation = inboundCont
        var stateCont: AsyncStream<ConnectionState>.Continuation!
        self.state = AsyncStream { stateCont = $0 }
        self.stateContinuation = stateCont
        super.init()
    }

    // MARK: Lifecycle (called by transport on queue)

    func centralDidConnect() {
        peripheral.discoverServices(nil)
    }

    func centralDidDisconnect(reason: String?) {
        ready = false
        stateContinuation.yield(.disconnected(reason: reason))
        inboundContinuation.finish()
        stateContinuation.finish()
        let waiters = responseWaiters + pendingWrites.map { $0.1 }
        responseWaiters.removeAll(); pendingWrites.removeAll()
        waiters.forEach { $0.resume(throwing: TransportError.notConnected) }
        let readers = readWaiters.values.flatMap { $0 }
        readWaiters.removeAll()
        readers.forEach { $0.resume(throwing: TransportError.notConnected) }
    }

    // MARK: DeviceConnection

    func write(_ bytes: Data, ifBusy: BusyPolicy) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.ready else {
                    cont.resume(throwing: TransportError.notConnected); return
                }
                guard let tx = self.tx else {
                    cont.resume(throwing: TransportError.characteristicNotFound("notify-only device: no writable characteristic")); return
                }
                if tx.properties.contains(.writeWithoutResponse) {
                    if self.peripheral.canSendWriteWithoutResponse {
                        self.peripheral.writeValue(bytes, for: tx, type: .withoutResponse)
                        cont.resume(returning: true)
                    } else {
                        switch ifBusy {
                        case .drop: cont.resume(returning: false)
                        case .wait: self.pendingWrites.append((bytes, cont))
                        }
                    }
                } else if tx.properties.contains(.write) {
                    self.responseWaiters.append(cont)
                    self.peripheral.writeValue(bytes, for: tx, type: .withResponse)
                } else {
                    cont.resume(throwing: TransportError.characteristicNotFound("tx characteristic not writable"))
                }
            }
        }
    }

    func read(characteristic: CBUUID) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.ready else {
                    cont.resume(throwing: TransportError.notConnected); return
                }
                guard let char = self.discoveredCharacteristics[characteristic] else {
                    cont.resume(throwing: TransportError.characteristicNotFound("characteristic not discovered")); return
                }
                self.readWaiters[characteristic, default: []].append(cont)
                self.peripheral.readValue(for: char)
            }
        }
    }

    func disconnect() async {
        queue.async { self.central.cancelPeripheralConnection(self.peripheral) }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return fail(.connectFailed(error.localizedDescription)) }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            discoveredCharacteristics[characteristic.uuid] = characteristic
        }
        guard rx == nil else { return }
        // The injected resolver binds this service's endpoints, or returns nil to
        // skip it (wait for a later service). `tx` may be nil for notify-only
        // devices; `rx` is the readiness/inbound source.
        guard let ep = resolver.resolve(service: service.uuid, characteristics: service.characteristics ?? []) else { return }
        tx = ep.tx
        rx = ep.rx
        peripheral.setNotifyValue(true, for: ep.rx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == rx else { return }
        if let error { return fail(.connectFailed(error.localizedDescription)) }
        ready = true
        stateContinuation.yield(.ready)
        onReady?()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic == rx, let data = characteristic.value {
            inboundContinuation.yield(data)
        }
        guard !readWaiters[characteristic.uuid, default: []].isEmpty else { return }
        let cont = readWaiters[characteristic.uuid]!.removeFirst()
        if let error {
            cont.resume(throwing: TransportError.readFailed(error.localizedDescription))
        } else {
            cont.resume(returning: characteristic.value ?? Data())
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !responseWaiters.isEmpty else { return }
        let cont = responseWaiters.removeFirst()
        if let error { cont.resume(throwing: TransportError.writeFailed(error.localizedDescription)) }
        else { cont.resume(returning: true) }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let tx else { return }
        while peripheral.canSendWriteWithoutResponse, !pendingWrites.isEmpty {
            let (bytes, cont) = pendingWrites.removeFirst()
            peripheral.writeValue(bytes, for: tx, type: .withoutResponse)
            cont.resume(returning: true)
        }
    }

    private func fail(_ error: TransportError) {
        onFailure?(error)
    }
}
