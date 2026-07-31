import Foundation

/// One connected toy. Owns its identity + features and serialises all traffic:
/// being an `actor`, calls queue and at most one write is ever in flight, so a
/// fast sensor cannot build a command backlog. Vendor-neutral — it speaks to a
/// `Codec` and a `DeviceCatalog`, not to Lovense directly.
///
/// Queries (`identify`, `battery`) are request/response: one is outstanding at a
/// time. Control setters (`setVibration`, …) write and report whether the bytes
/// reached the link — under `.drop` they may not have, and a coalescing sender
/// must not mistake a dropped write for the device's current state.
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
    private var depthContinuation: AsyncStream<TouchFrame>.Continuation?

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

    /// Reads the runtime actuator list (`GetCap;`).
    ///
    /// Worth asking even when the catalog answered: the vendored config carries no
    /// feature rows at all for Mission 2 or Ferri, so this is the only description
    /// of their actuators that exists. Not every model supports it — Edge 2 is
    /// silent, Gemini answers `unkown` — so a `nil` return is a normal outcome.
    public func capabilities(timeout: Duration = .seconds(2)) async throws -> Capabilities? {
        try await connection.write(codec.encode(.capabilities))
        let reply = try? await awaitReply(timeout: timeout) {
            if case .capabilities = $0 { true } else { false }
        }
        guard case let .capabilities(capabilities) = reply else { return nil }
        return capabilities
    }

    // MARK: Sensor input

    /// The Touch-Sense position stream, enabled for the life of the returned
    /// stream and disabled when it terminates.
    ///
    /// **Silence is the normal resting state.** The stream is motion-gated: 90 s of
    /// holding perfectly still produced no frames at all, and movement resumed them
    /// with nothing re-enabled. So silence is not an error, not end-of-stream, and
    /// not evidence the sensor was switched off — do not build a watchdog that
    /// infers disablement from it. A consumer needing "present versus removed"
    /// cannot get it from here either; at rest the two are identical on the wire.
    ///
    /// The frame rate is bound by the 30 ms connection interval rather than by the
    /// sensor, and writing at up to 33 Hz costs it nothing.
    public func depth() async throws -> AsyncStream<TouchFrame> {
        ensureReading()
        // Unconditionally, every connection: `TouchMode` resets to 0 across a power
        // cycle, so there is never a previous session's enable to inherit.
        try await connection.write(codec.encode(.setTouchMode(.stream)))
        depthContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: TouchFrame.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.endDepth() }
        }
        depthContinuation = continuation
        return stream
    }

    private func endDepth() async {
        depthContinuation = nil
        _ = try? await connection.write(codec.encode(.setTouchMode(.off)))
    }

    /// Ensures the toy is one software can actually stop, returning whether it had
    /// to intervene.
    ///
    /// In `TouchMode:5` the firmware drives the motor from its own sensor: it
    /// ignores `Vibrate:0;` while answering `OK;` to it, and it keeps running after
    /// the central has ceased to exist. Every stop in this library — `ControlLoop`'s
    /// unconditional hard stop included — reduces to that command, so against a
    /// toy in mode 5 none of them work. `DeviceCore` never sends mode 5, but the
    /// mode survives a disconnect and another application may have left it set, so
    /// it has to be read back and cleared before any control claim is honest.
    ///
    /// A toy without `TouchMode` at all answers `unkown` or stays silent; both mean
    /// there is nothing to clear.
    ///
    /// **Nothing calls this yet, on purpose.** Mode 5 is the one such state observed,
    /// not the only one that exists — Lovense's own app has a setting that keeps a
    /// toy running when Bluetooth drops, and no command for it is known. A caller
    /// treating `false` as "this toy is stoppable" would be asserting more than the
    /// check supports. See ROADMAP.md, "Stop authority as a whole".
    @discardableResult
    public func ensureStoppable(timeout: Duration = .seconds(2)) async throws -> Bool {
        try await connection.write(codec.encode(.touchMode))
        let reply = try? await awaitReply(timeout: timeout) {
            switch $0 { case .touchMode, .unsupported: true; default: false }
        }
        guard case let .touchMode(raw) = reply, TouchMode(rawValue: raw) == nil else { return false }
        try await connection.write(codec.encode(.setTouchMode(.off)))
        return true
    }

    // MARK: Control

    /// Sets the `ordinal`-th vibrator (0-based) to `level` in 0…1. On a single-
    /// vibrator toy the wire command is unnumbered; on a multi it is `Vibrate{n}:`.
    /// Returns whether the bytes were sent (always true for `.wait`).
    @discardableResult
    public func setVibration(_ ordinal: Int, _ level: Double, ifBusy: BusyPolicy = .wait) async throws -> Bool {
        let vibrators = try features { if case let .vibrate(index, range) = $0 { (index, range) } else { nil } }
        guard vibrators.indices.contains(ordinal) else { throw SessionError.featureUnavailable("vibrate[\(ordinal)]") }
        let (index, range) = vibrators[ordinal]
        let actuator = vibrators.count > 1 ? index + 1 : nil
        return try await connection.write(codec.encode(.vibrate(actuator: actuator, level: scale(level, into: range))), ifBusy: ifBusy)
    }

    /// Sets rotation speed to `level` in 0…1.
    @discardableResult
    public func setRotation(_ level: Double, ifBusy: BusyPolicy = .wait) async throws -> Bool {
        let range = try firstRange("rotate") { if case let .rotate(_, r) = $0 { r } else { nil } }
        return try await connection.write(codec.encode(.rotate(level: scale(level, into: range))), ifBusy: ifBusy)
    }

    /// Reverses the direction of rotation.
    @discardableResult
    public func reverseRotation(ifBusy: BusyPolicy = .wait) async throws -> Bool {
        try await connection.write(codec.encode(.rotateChange), ifBusy: ifBusy)
    }

    /// Sets the air/constriction level to `level` in 0…1 (`Air:Level:n;`).
    @discardableResult
    public func setAir(_ level: Double, ifBusy: BusyPolicy = .wait) async throws -> Bool {
        let range = try firstRange("constrict") { if case let .constrict(_, r) = $0 { r } else { nil } }
        return try await connection.write(codec.encode(.constrict(level: scale(level, into: range))), ifBusy: ifBusy)
    }

    public func disconnect() async {
        reader?.cancel()
        reader = nil
        depthContinuation?.finish()
        depthContinuation = nil
        failWaiter(CancellationError())
        await connection.disconnect()
    }

    // MARK: Reply plumbing

    private func awaitReply(timeout: Duration,
                            matching match: @escaping @Sendable (DeviceReply) -> Bool) async throws -> DeviceReply {
        ensureReading()
        // `try`, not `try?`: a cancelled sleep must end the task, not fall through
        // to fail whichever waiter is registered by then — which, once this query
        // has been answered and the `defer` has cancelled, is the *next* query's.
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
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

    private func deliver(_ frame: Data) {
        let reply = codec.parse(frame)
        // Sensor frames are fanned out, never used to satisfy a query: a `battery`
        // must not be answered by the stream running underneath it.
        if case let .depth(touch) = reply {
            depthContinuation?.yield(touch)
            return
        }
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
