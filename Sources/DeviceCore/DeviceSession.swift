import Foundation

/// One connected toy. Owns its identity + features and serialises all traffic:
/// being an `actor`, calls queue and at most one write is ever in flight, so a
/// fast sensor cannot build a command backlog. Vendor-neutral — it speaks to a
/// `Codec` and a `DeviceCatalog`, not to Lovense directly.
///
/// Queries (`identify`, `battery`) are request/response: one is outstanding at a
/// time. Control setters (`setVibration`, …) are fire-and-forget writes.
public actor DeviceSession {
    public let id: PeripheralID
    /// The resolved model, available after `identify`.
    public private(set) var model: DeviceCatalog.Model?

    private let connection: DeviceConnection
    private let catalog: DeviceCatalog
    private let codec: any Codec

    private var reader: Task<Void, Never>?
    private var waiter: (match: @Sendable (DeviceReply) -> Bool,
                         continuation: CheckedContinuation<DeviceReply, Error>)?

    public init(connection: DeviceConnection,
                catalog: DeviceCatalog,
                codec: any Codec = LovenseCodec()) {
        self.id = connection.id
        self.connection = connection
        self.catalog = catalog
        self.codec = codec
    }

    // MARK: Queries

    /// Runs the identity handshake: writes `DeviceType;`, resolves the reply
    /// against the catalog, and caches the model. Throws on timeout.
    ///
    /// The ARCHITECTURE step-5 name-parse fallback (on `DeviceType;` timeout) is
    /// not implemented yet.
    @discardableResult
    public func identify(timeout: Duration = .seconds(5)) async throws -> DeviceCatalog.Model {
        try await connection.write(codec.encode(.deviceType))
        let reply = try await awaitReply(timeout: timeout) {
            if case .deviceType = $0 { true } else { false }
        }
        guard case let .deviceType(code, firmware, _) = reply else { throw SessionError.notIdentified }
        let model = catalog.model(forDeviceType: code, firmware: firmware)
        self.model = model
        return model
    }

    /// Reads the battery level (0…100).
    public func battery(timeout: Duration = .seconds(5)) async throws -> Int {
        try await connection.write(codec.encode(.battery))
        let reply = try await awaitReply(timeout: timeout) {
            if case .battery = $0 { true } else { false }
        }
        guard case let .battery(percent) = reply else { throw SessionError.notIdentified }
        return percent
    }

    // MARK: Control

    /// Sets the `ordinal`-th vibrator (0-based) to `level` in 0…1. On a single-
    /// vibrator toy the wire command is unnumbered; on a multi it is `Vibrate{n}:`.
    public func setVibration(_ ordinal: Int, _ level: Double, ifBusy: BusyPolicy = .wait) async throws {
        let vibrators = try features { if case let .vibrate(index, range) = $0 { (index, range) } else { nil } }
        guard vibrators.indices.contains(ordinal) else { throw SessionError.featureUnavailable("vibrate[\(ordinal)]") }
        let (index, range) = vibrators[ordinal]
        let actuator = vibrators.count > 1 ? index + 1 : nil
        try await connection.write(codec.encode(.vibrate(actuator: actuator, level: scale(level, into: range))), ifBusy: ifBusy)
    }

    /// Sets rotation speed to `level` in 0…1.
    public func setRotation(_ level: Double, ifBusy: BusyPolicy = .wait) async throws {
        let range = try firstRange("rotate") { if case let .rotate(_, r) = $0 { r } else { nil } }
        try await connection.write(codec.encode(.rotate(level: scale(level, into: range))), ifBusy: ifBusy)
    }

    /// Reverses the direction of rotation.
    public func reverseRotation(ifBusy: BusyPolicy = .wait) async throws {
        try await connection.write(codec.encode(.rotateChange), ifBusy: ifBusy)
    }

    /// Sets the air/constriction level to `level` in 0…1 (`Air:Level:n;`).
    public func setAir(_ level: Double, ifBusy: BusyPolicy = .wait) async throws {
        let range = try firstRange("constrict") { if case let .constrict(_, r) = $0 { r } else { nil } }
        try await connection.write(codec.encode(.constrict(level: scale(level, into: range))), ifBusy: ifBusy)
    }

    public func disconnect() async {
        reader?.cancel()
        reader = nil
        failWaiter(CancellationError())
        await connection.disconnect()
    }

    // MARK: Reply plumbing

    private func awaitReply(timeout: Duration,
                            matching match: @escaping @Sendable (DeviceReply) -> Bool) async throws -> DeviceReply {
        ensureReading()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failWaiter(TransportError.connectTimeout)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiter?.continuation.resume(throwing: CancellationError())   // supersede any prior query
            waiter = (match, continuation)
        }
    }

    private func ensureReading() {
        guard reader == nil else { return }
        let frames = codec.frames(from: connection.inbound)
        reader = Task { [weak self] in
            for await frame in frames { await self?.deliver(frame) }
        }
    }

    private func deliver(_ frame: String) {
        let reply = codec.parse(frame)
        guard let waiter, waiter.match(reply) else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: reply)
    }

    private func failWaiter(_ error: Error) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(throwing: error)
    }

    // MARK: Feature lookup / scaling

    private func features<T>(_ select: (Feature) -> T?) throws -> [T] {
        guard let model else { throw SessionError.notIdentified }
        return model.features.compactMap(select)
    }

    private func firstRange(_ kind: String, _ select: (Feature) -> ClosedRange<Int>?) throws -> ClosedRange<Int> {
        guard let range = try features(select).first else { throw SessionError.featureUnavailable(kind) }
        return range
    }

    private func scale(_ level: Double, into range: ClosedRange<Int>) -> Int {
        let clamped = min(max(level, 0), 1)
        return range.lowerBound + Int((clamped * Double(range.upperBound - range.lowerBound)).rounded())
    }
}

public enum SessionError: Error, Equatable {
    /// A command needing the model was issued before `identify`.
    case notIdentified
    /// The toy has no feature of the requested kind (e.g. rotation on a vibrator).
    case featureUnavailable(String)
}
