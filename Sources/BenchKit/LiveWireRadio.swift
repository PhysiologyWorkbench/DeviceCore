import Foundation
@preconcurrency import CoreBluetooth

/// The CoreBluetooth `WireRadio`. Each operation stands up its own central,
/// does its one thing, and tears down — a bench operation is one-shot, and
/// the first central minted is what triggers the host's Bluetooth
/// authorisation prompt, so nothing here runs before a tool does.
///
/// The live end is validated at the owner's bench, not in the automated
/// suite (`benchkit-run-records-2026-09-09`); everything around it — the
/// tools, captures, summaries — tests against a scripted radio.
public struct LiveWireRadio: WireRadio {
    /// Ceiling on a GATT walk after connect; a device that cannot finish
    /// discovery and reads in this long ends the run as an error.
    private static let walkTimeout: Duration = .seconds(30)

    public init() {}

    public func advertisements(for duration: Duration) async throws -> [AdvertisementEvent] {
        try await WireCentral().advertisements(for: duration)
    }

    public func survey(_ target: WireTarget, scanWindow: Duration) async throws -> GattSurvey {
        try await WireCentral().survey(target, scanWindow: scanWindow,
                                       walkTimeout: Self.walkTimeout)
    }

    public func notifications(from target: WireTarget, characteristic: String,
                              scanWindow: Duration, for duration: Duration) async throws -> [NotifyEvent] {
        try await WireCentral().notifications(from: target, characteristic: characteristic,
                                              scanWindow: scanWindow, for: duration,
                                              walkTimeout: Self.walkTimeout)
    }
}

/// One central, one operation. All state is confined to the serial queue,
/// the `BleTransport` discipline; every finish nils its continuation before
/// resuming, so a late delegate callback finds nothing to resume.
private final class WireCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "fi.iki.pnr.benchkit.wire")
    private var central: CBCentralManager!

    private var poweredOn = false
    private var powerError: WireError?
    private var powerWaiter: CheckedContinuation<Void, Error>?

    private enum Phase {
        case idle
        case scanning
        case finding(WireTarget)
        case walking
        case reading
        case notifying(CBCharacteristic)
    }

    private var phase = Phase.idle
    private var start = Date()

    private var advertisementLog: [AdvertisementEvent] = []
    private var scanWaiter: CheckedContinuation<[AdvertisementEvent], Never>?

    private var peripheral: CBPeripheral?
    private var surveyWaiter: CheckedContinuation<GattSurvey, Error>?
    private var pendingCharacteristicDiscoveries = 0
    private var pendingDescriptorDiscoveries = 0
    private var pendingReads = 0
    private var readValues: [ObjectIdentifier: Data] = [:]

    /// Nil while surveying; set when the operation is a notify log, so the
    /// walk skips descriptor discovery and reads and subscribes instead.
    private var notifyCharacteristicName: String?
    private var notifyLog: [NotifyEvent] = []
    private var notifyWaiter: CheckedContinuation<[NotifyEvent], Error>?
    private var listenDuration: Duration = .zero

    // MARK: Operations

    func advertisements(for duration: Duration) async throws -> [AdvertisementEvent] {
        try await waitPoweredOn()
        return await withCheckedContinuation { cont in
            queue.async {
                self.scanWaiter = cont
                self.phase = .scanning
                self.start = Date()
                self.startScan()
                self.queue.asyncAfter(deadline: .now() + duration.wireSeconds) {
                    guard let waiter = self.scanWaiter else { return }
                    self.scanWaiter = nil
                    self.phase = .idle
                    self.central.stopScan()
                    waiter.resume(returning: self.advertisementLog)
                }
            }
        }
    }

    func survey(_ target: WireTarget, scanWindow: Duration,
                walkTimeout: Duration) async throws -> GattSurvey {
        try await waitPoweredOn()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.surveyWaiter = cont
                self.beginFinding(target, scanWindow: scanWindow, walkTimeout: walkTimeout)
            }
        }
    }

    func notifications(from target: WireTarget, characteristic: String,
                       scanWindow: Duration, for duration: Duration,
                       walkTimeout: Duration) async throws -> [NotifyEvent] {
        try await waitPoweredOn()
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.notifyWaiter = cont
                self.notifyCharacteristicName = characteristic
                self.listenDuration = duration
                self.beginFinding(target, scanWindow: scanWindow, walkTimeout: walkTimeout)
            }
        }
    }

    // MARK: Queue-confined machinery

    private func waitPoweredOn() async throws {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: queue)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.poweredOn { cont.resume() }
                else if let error = self.powerError { cont.resume(throwing: error) }
                else { self.powerWaiter = cont }
            }
        }
    }

    private func startScan() {
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func beginFinding(_ target: WireTarget, scanWindow: Duration, walkTimeout: Duration) {
        phase = .finding(target)
        start = Date()
        startScan()
        queue.asyncAfter(deadline: .now() + scanWindow.wireSeconds) {
            guard case .finding = self.phase else { return }
            self.central.stopScan()
            self.finish(throwing: .deviceNotFound(
                "no device matching the target advertised within the scan window"))
        }
        queue.asyncAfter(deadline: .now() + scanWindow.wireSeconds + walkTimeout.wireSeconds) {
            switch self.phase {
            case .walking, .reading:
                self.finish(throwing: .timeout("GATT walk incomplete after \(Int(walkTimeout.wireSeconds)) s"))
            default:
                break
            }
        }
    }

    /// Ends a survey or notify operation, tearing the connection down.
    private func finish(throwing error: WireError) {
        phase = .idle
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        if let waiter = surveyWaiter {
            surveyWaiter = nil
            waiter.resume(throwing: error)
        }
        if let waiter = notifyWaiter {
            notifyWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    private func discoveryStepDone() {
        guard pendingCharacteristicDiscoveries == 0, pendingDescriptorDiscoveries == 0,
              case .walking = phase, let peripheral else { return }
        if let name = notifyCharacteristicName {
            let wanted = name.uppercased()
            let match = (peripheral.services ?? [])
                .flatMap { $0.characteristics ?? [] }
                .first { $0.uuid.uuidString.uppercased() == wanted }
            guard let match else {
                return finish(throwing: .characteristicNotFound(
                    "the device offers no characteristic \(name)"))
            }
            phase = .notifying(match)
            peripheral.setNotifyValue(true, for: match)
            return
        }
        phase = .reading
        for characteristic in (peripheral.services ?? []).flatMap({ $0.characteristics ?? [] })
        where characteristic.properties.contains(.read) {
            pendingReads += 1
            peripheral.readValue(for: characteristic)
        }
        if pendingReads == 0 { completeSurvey() }
    }

    private func completeSurvey() {
        guard let peripheral, let waiter = surveyWaiter else { return }
        let services = (peripheral.services ?? []).map { service in
            GattSurvey.Service(
                uuid: service.uuid.uuidString,
                isPrimary: service.isPrimary,
                characteristics: (service.characteristics ?? []).map { characteristic in
                    GattSurvey.Characteristic(
                        uuid: characteristic.uuid.uuidString,
                        properties: GattSurvey.Characteristic.propertyNames(
                            mask: characteristic.properties.rawValue),
                        value: readValues[ObjectIdentifier(characteristic)]?.hexString,
                        descriptors: (characteristic.descriptors ?? []).map { $0.uuid.uuidString })
                })
        }
        let survey = GattSurvey(peripheral: peripheral.identifier,
                                name: peripheral.name, services: services)
        phase = .idle
        surveyWaiter = nil
        central.cancelPeripheralConnection(peripheral)
        waiter.resume(returning: survey)
    }

    private func completeNotifyLog() {
        guard let peripheral, let waiter = notifyWaiter else { return }
        phase = .idle
        notifyWaiter = nil
        central.cancelPeripheralConnection(peripheral)
        waiter.resume(returning: notifyLog)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            poweredOn = true
            powerWaiter?.resume()
            powerWaiter = nil
        case .unauthorized, .poweredOff, .unsupported:
            let error = WireError.bluetoothUnavailable(String(describing: central.state))
            powerError = error
            powerWaiter?.resume(throwing: error)
            powerWaiter = nil
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        switch phase {
        case .scanning:
            let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            let companyID = manufacturer.flatMap { blob -> Int? in
                blob.count >= 2 ? Int(blob[blob.startIndex]) | Int(blob[blob.index(after: blob.startIndex)]) << 8 : nil
            }
            let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])
                .map { pairs in Dictionary(uniqueKeysWithValues: pairs.map { ($0.uuidString, $1.hexString) }) }
            advertisementLog.append(AdvertisementEvent(
                t: Date().timeIntervalSince(start),
                peripheral: peripheral.identifier,
                name: name,
                rssi: RSSI.intValue,
                services: ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).map(\.uuidString),
                manufacturerData: manufacturer?.hexString,
                companyID: companyID,
                serviceData: serviceData,
                txPower: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
                connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue))
        case .finding(let target):
            guard target.matches(peripheral: peripheral.identifier, name: name) else { return }
            phase = .walking
            self.peripheral = peripheral
            central.stopScan()
            peripheral.delegate = self
            central.connect(peripheral)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(throwing: .disconnected(error?.localizedDescription ?? "connect failed"))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finish(throwing: .disconnected(error?.localizedDescription ?? "device disconnected"))
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return finish(throwing: .disconnected(error.localizedDescription)) }
        let services = peripheral.services ?? []
        pendingCharacteristicDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if services.isEmpty { discoveryStepDone() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingCharacteristicDiscoveries -= 1
        // A notify log needs no descriptor inventory; the survey walks them.
        if notifyCharacteristicName == nil {
            for characteristic in service.characteristics ?? [] {
                pendingDescriptorDiscoveries += 1
                peripheral.discoverDescriptors(for: characteristic)
            }
        }
        discoveryStepDone()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        pendingDescriptorDiscoveries -= 1
        discoveryStepDone()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard case .notifying(let subscribed) = phase, characteristic == subscribed else { return }
        if let error {
            return finish(throwing: .characteristicNotFound(
                "notifications refused: \(error.localizedDescription)"))
        }
        start = Date()
        queue.asyncAfter(deadline: .now() + listenDuration.wireSeconds) {
            guard case .notifying = self.phase else { return }
            peripheral.setNotifyValue(false, for: characteristic)
            self.completeNotifyLog()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        switch phase {
        case .reading:
            if error == nil, let value = characteristic.value {
                readValues[ObjectIdentifier(characteristic)] = value
            }
            pendingReads -= 1
            if pendingReads == 0 { completeSurvey() }
        case .notifying(let subscribed) where characteristic == subscribed:
            if let value = characteristic.value {
                notifyLog.append(NotifyEvent(t: Date().timeIntervalSince(start),
                                             payload: value.hexString))
            }
        default:
            break
        }
    }
}

private extension Duration {
    var wireSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
