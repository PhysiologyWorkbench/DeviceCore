import Foundation
@preconcurrency import CoreBluetooth

/// CoreBluetooth-backed `Transport`. All CoreBluetooth state is confined to a
/// single serial queue; async methods bridge the delegate callbacks via
/// continuations and `AsyncStream`. Platform-identical across macOS/iOS/iPadOS.
public final class BleTransport: NSObject, Transport, CBCentralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.lelut.ble.transport")
    private let scanFilter: ScanFilter
    private let resolver: EndpointResolver
    private let scanOptions: [String: Any]?
    private var central: CBCentralManager!

    private var poweredOn = false
    private var powerError: TransportError?
    private var powerWaiters: [CheckedContinuation<Void, Error>] = []

    private var scanContinuation: AsyncStream<Discovery>.Continuation?
    private var scanGeneration = 0
    private var discovered: [UUID: CBPeripheral] = [:]

    private var connections: [UUID: BleConnection] = [:]
    private var connectWaiters: [UUID: CheckedContinuation<DeviceConnection, Error>] = [:]

    /// `reportsDuplicates` yields every advertisement rather than the first per
    /// peripheral. A caller that holds no link has no other way to notice a
    /// device going away — the advertisements stopping is the only signal — and
    /// pays for it in radio wake-ups, so it is off unless asked for.
    public init(scanFilter: ScanFilter, resolver: EndpointResolver, reportsDuplicates: Bool = false) {
        self.scanFilter = scanFilter
        self.resolver = resolver
        scanOptions = reportsDuplicates ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : nil
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
                // Terminate any prior scan stream rather than orphaning it. The
                // generation guard stops the old stream's onTermination from
                // clearing this new continuation.
                self.scanContinuation?.finish()
                self.scanGeneration += 1
                let generation = self.scanGeneration
                self.scanContinuation = continuation
                if self.poweredOn {
                    self.central.scanForPeripherals(withServices: nil, options: self.scanOptions)
                }
                continuation.onTermination = { _ in
                    self.queue.async {
                        guard self.scanGeneration == generation else { return }
                        self.central.stopScan()
                        self.scanContinuation = nil
                    }
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
                // Single-flight: reject a duplicate connect rather than overwriting
                // (and permanently hanging) the in-flight waiter for this peripheral.
                guard self.connectWaiters[id.uuid] == nil else {
                    cont.resume(throwing: TransportError.connectFailed("connect already in progress")); return
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
            if scanContinuation != nil {
                central.scanForPeripherals(withServices: nil, options: scanOptions)
            }
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
        let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
            .flatMap(ManufacturerData.init(advertisementBlob:))
        let nameMatch = scanFilter.namePrefixes.contains { name.hasPrefix($0) }
        let serviceMatch = !Set(services).isDisjoint(with: scanFilter.serviceUUIDs)
        let manufacturerMatch = manufacturer.map { scanFilter.manufacturerIDs.contains($0.companyID) } ?? false
        guard nameMatch || serviceMatch || manufacturerMatch else { return }

        discovered[peripheral.identifier] = peripheral
        scanContinuation?.yield(Discovery(id: PeripheralID(peripheral.identifier),
                                          name: name, rssi: RSSI.intValue, services: services,
                                          manufacturer: manufacturer))
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
    /// Whether the resolver has bound endpoints. `rx` cannot stand in for this:
    /// a write-only device binds tx alone, and a second service must not
    /// re-resolve endpoints.
    private var endpointsResolved = false
    /// Services whose characteristic discovery has not yet called back. A
    /// write-only device (no rx to confirm notifications on) becomes ready only
    /// when this reaches zero, so that every characteristic — e.g. Device
    /// Information's — is cached before `connect()` returns.
    private var pendingServiceDiscoveries = 0

    /// Every characteristic discovered across all services, keyed by UUID — not
    /// just the endpoint resolver's tx/rx match — so `read(characteristic:)` can
    /// reach e.g. the standard Battery Level characteristic.
    private var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]

    /// Waiters for a write-with-response ACK, FIFO.
    private var responseWaiters: [CheckedContinuation<Bool, Error>] = []
    /// Queued write-without-response payloads awaiting link readiness, FIFO,
    /// each bound to its target characteristic.
    private var pendingWrites: [(Data, CBCharacteristic, CheckedContinuation<Bool, Error>)] = []
    /// Waiters for a characteristic read, FIFO per characteristic.
    private var readWaiters: [CBUUID: [CheckedContinuation<Data, Error>]] = [:]
    /// Extra notify streams bound by `subscribe`, keyed by characteristic UUID —
    /// their notifications route here rather than to `inbound` or a read waiter.
    private var subscriptions: [CBUUID: AsyncStream<Data>.Continuation] = [:]
    /// Waiters for a `subscribe`'s notify-enabled confirmation, one per characteristic.
    private var subscribeWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]

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
        let waiters = responseWaiters + pendingWrites.map { $0.2 }
        responseWaiters.removeAll(); pendingWrites.removeAll()
        waiters.forEach { $0.resume(throwing: TransportError.notConnected) }
        let readers = readWaiters.values.flatMap { $0 }
        readWaiters.removeAll()
        readers.forEach { $0.resume(throwing: TransportError.notConnected) }
        subscriptions.values.forEach { $0.finish() }
        subscriptions.removeAll()
        let subscribers = Array(subscribeWaiters.values)
        subscribeWaiters.removeAll()
        subscribers.forEach { $0.resume(throwing: TransportError.notConnected) }
    }

    // MARK: DeviceConnection

    func write(_ bytes: Data, ifBusy: BusyPolicy, type: WriteType) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.ready else {
                    cont.resume(throwing: TransportError.notConnected); return
                }
                guard let tx = self.tx else {
                    cont.resume(throwing: TransportError.characteristicNotFound("notify-only device: no writable characteristic")); return
                }
                self.performWrite(bytes, on: tx, ifBusy: ifBusy, type: type, cont: cont)
            }
        }
    }

    func write(_ bytes: Data, to characteristic: CBUUID, ifBusy: BusyPolicy, type: WriteType) async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.ready else {
                    cont.resume(throwing: TransportError.notConnected); return
                }
                guard let char = self.discoveredCharacteristics[characteristic] else {
                    cont.resume(throwing: TransportError.characteristicNotFound("characteristic not discovered")); return
                }
                self.performWrite(bytes, on: char, ifBusy: ifBusy, type: type, cont: cont)
            }
        }
    }

    /// Queue-confined write body shared by the tx path and the targeted path.
    private func performWrite(_ bytes: Data, on characteristic: CBCharacteristic,
                              ifBusy: BusyPolicy, type: WriteType,
                              cont: CheckedContinuation<Bool, Error>) {
        if type == .withResponse, characteristic.properties.contains(.write) {
            responseWaiters.append(cont)
            peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            if peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(bytes, for: characteristic, type: .withoutResponse)
                cont.resume(returning: true)
            } else {
                switch ifBusy {
                case .drop: cont.resume(returning: false)
                case .wait: pendingWrites.append((bytes, characteristic, cont))
                }
            }
        } else if characteristic.properties.contains(.write) {
            responseWaiters.append(cont)
            peripheral.writeValue(bytes, for: characteristic, type: .withResponse)
        } else {
            cont.resume(throwing: TransportError.characteristicNotFound("tx characteristic not writable"))
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

    func subscribe(_ characteristic: CBUUID) async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.ready else {
                    cont.resume(throwing: TransportError.notConnected); return
                }
                guard let char = self.discoveredCharacteristics[characteristic] else {
                    cont.resume(throwing: TransportError.characteristicNotFound("characteristic not discovered")); return
                }
                self.subscriptions[characteristic] = continuation
                self.subscribeWaiters[characteristic] = cont
                self.peripheral.setNotifyValue(true, for: char)
            }
        }
        return stream
    }

    func disconnect() async {
        queue.async { self.central.cancelPeripheralConnection(self.peripheral) }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return fail(.connectFailed(error.localizedDescription)) }
        pendingServiceDiscoveries = (peripheral.services ?? []).count
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServiceDiscoveries -= 1
        for characteristic in service.characteristics ?? [] {
            discoveredCharacteristics[characteristic.uuid] = characteristic
        }
        // The injected resolver binds this service's endpoints, or returns nil to
        // skip it (wait for a later service). When it binds an rx, notification
        // confirmation is the readiness signal, as before; a write-only device
        // (rx nil) is ready once every service's characteristics are cached, so
        // an immediate read of e.g. Device Information cannot miss.
        if !endpointsResolved,
           let ep = resolver.resolve(service: service.uuid, characteristics: service.characteristics ?? []) {
            endpointsResolved = true
            tx = ep.tx
            rx = ep.rx
            if let rx { peripheral.setNotifyValue(true, for: rx) }
        }
        if pendingServiceDiscoveries == 0, endpointsResolved, rx == nil, !ready {
            becomeReady()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic == rx {
            if let error { return fail(.connectFailed(error.localizedDescription)) }
            becomeReady()
            return
        }
        guard let waiter = subscribeWaiters.removeValue(forKey: characteristic.uuid) else { return }
        if let error {
            subscriptions.removeValue(forKey: characteristic.uuid)?.finish()
            waiter.resume(throwing: TransportError.characteristicNotFound(error.localizedDescription))
        } else {
            waiter.resume()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // An rx notification is inbound stream data, never a read() reply — even if
        // a read() waiter were registered on the same UUID, it must not consume it.
        if characteristic == rx {
            if let data = characteristic.value { inboundContinuation.yield(data) }
            return
        }
        // A subscribed characteristic's notification routes to its own stream, never
        // to a read() waiter registered on the same UUID.
        if let subscription = subscriptions[characteristic.uuid] {
            if let data = characteristic.value { subscription.yield(data) }
            return
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
        while peripheral.canSendWriteWithoutResponse, !pendingWrites.isEmpty {
            let (bytes, characteristic, cont) = pendingWrites.removeFirst()
            peripheral.writeValue(bytes, for: characteristic, type: .withoutResponse)
            cont.resume(returning: true)
        }
    }

    private func becomeReady() {
        ready = true
        stateContinuation.yield(.ready)
        onReady?()
    }

    private func fail(_ error: TransportError) {
        onFailure?(error)
    }
}
