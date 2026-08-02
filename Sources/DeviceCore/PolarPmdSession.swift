import Foundation

public enum PmdError: Error, Sendable, Equatable {
    /// The device rejected a `REQUEST_MEASUREMENT_START` with this PMD error code.
    case startRejected(UInt8)
    /// No start response arrived: the control point fell silent, or closed.
    case noResponse
}

/// Streams PMD measurements (ECG and/or ACC) off a Polar H10, on the shared
/// `DeviceSession`. The handshake — subscribe the control point, write
/// `REQUEST_MEASUREMENT_START`, await the success response — is a request; each
/// measurement is a standing subscription. Both control point and data
/// characteristic feed the one session, so the separation between a response and a
/// data frame is made by predicate rather than by which stream it arrived on.
///
/// Start measurements one at a time (the control point carries one handshake at a
/// time); `disconnect` sends `STOP_MEASUREMENT` for each so the strap stops cleanly.
public actor PolarPmdSession {
    public let id: PeripheralID

    private let connection: DeviceConnection
    private let session = DeviceSession()
    private let handshakeTimeout: Duration
    private var controlSubscribed = false
    private var dataSubscribed = false
    private var active: Set<PmdMeasurement> = []

    /// `handshakeTimeout` bounds a fault rather than pacing anything: a strap that
    /// accepts the subscription and then answers nothing must not leave the caller
    /// awaiting for ever. The default is generous against a device that replies in
    /// milliseconds.
    public init(connection: DeviceConnection, handshakeTimeout: Duration = .seconds(5)) {
        self.id = connection.id
        self.connection = connection
        self.handshakeTimeout = handshakeTimeout
    }

    /// Starts ECG (default 130 Hz, 14-bit) and streams frames until the connection drops.
    public func ecg(sampleRate: Double = 130) async throws -> AsyncStream<PmdEcgFrame> {
        let settings = PmdCodec.setting(.sampleRate, UInt32(sampleRate)) + PmdCodec.setting(.resolution, 14)
        _ = try await start(.ecg, settings: settings)
        await consumeData()
        let (_, stream) = await session.subscribe { PmdCodec.parseEcg($0, sampleRate: sampleRate) }
        return stream
    }

    /// Starts accelerometer (default 200 Hz, 16-bit, ±8 g) and streams frames until
    /// the connection drops. The milli-g scaling `factor` comes from the start response.
    public func acc(sampleRate: Double = 200, range: UInt32 = 8) async throws -> AsyncStream<PmdAccFrame> {
        let settings = PmdCodec.setting(.sampleRate, UInt32(sampleRate))
            + PmdCodec.setting(.resolution, 16) + PmdCodec.setting(.range, range)
        let response = try await start(.acc, settings: settings)
        let factor = PmdCodec.factor(fromStartResponse: response.parameters) ?? 1.0
        await consumeData()
        let (_, stream) = await session.subscribe {
            PmdCodec.parseAcc($0, sampleRate: sampleRate, factor: factor)
        }
        return stream
    }

    public func disconnect() async {
        await session.stop()
        for measurement in active {
            _ = try? await connection.write(PmdCodec.stopCommand(measurement))
        }
        active = []
        await connection.disconnect()
    }

    /// Requests a measurement start over the (once-subscribed) control point and
    /// returns the success response (whose parameters carry the negotiated
    /// settings + factor).
    private func start(_ measurement: PmdMeasurement, settings: [UInt8]) async throws -> PmdControlResponse {
        try await consumeControl()
        try await connection.write(PmdCodec.startCommand(measurement, settings: settings))
        let response: PmdControlResponse
        do {
            response = try await session.request(timeout: handshakeTimeout) {
                guard let response = PmdCodec.parseControlResponse($0),
                      response.opCode == 0x02,
                      response.measurementType == measurement.rawValue else { return nil }
                return response
            }
        } catch {
            // Silence and a closed control point are the same outcome to a caller:
            // the strap never answered.
            throw PmdError.noResponse
        }
        guard response.isSuccess else { throw PmdError.startRejected(response.errorCode) }
        active.insert(measurement)
        return response
    }

    private func consumeControl() async throws {
        guard !controlSubscribed else { return }
        let control = try await connection.subscribe(PolarH10.pmdControlPoint)
        controlSubscribed = true
        await session.consume(control)
    }

    /// The shared data characteristic carries both measurements; each subscription's
    /// parse rejects the other's frames, so no demux by type byte is needed here.
    private func consumeData() async {
        guard !dataSubscribed else { return }
        dataSubscribed = true
        await session.consume(connection.inbound)
    }
}
