import Foundation

public enum PmdError: Error, Sendable, Equatable {
    /// The device rejected a `REQUEST_MEASUREMENT_START` with this PMD error code.
    case startRejected(UInt8)
    /// The control point closed before a start response arrived.
    case noResponse
}

/// Streams PMD measurements (ECG and/or ACC) off a Polar H10. The input-side
/// counterpart to `HeartRateReader`, but with a handshake: it subscribes the
/// control point, writes `REQUEST_MEASUREMENT_START`, awaits the success response,
/// then decodes the data notifications through `PmdCodec`. Both measurements
/// arrive on the one data characteristic, so a single reader task demuxes frames
/// to the per-measurement streams by the header's type byte. Start measurements
/// one at a time (the control point carries one handshake at a time);
/// `disconnect` sends `STOP_MEASUREMENT` for each so the strap stops cleanly.
public actor PmdReader {
    public let id: PeripheralID

    private let connection: DeviceConnection
    private var control: AsyncStream<Data>?
    private var reader: Task<Void, Never>?
    private var active: Set<PmdMeasurement> = []
    private var ecgContinuation: AsyncStream<PmdEcgFrame>.Continuation?
    private var accContinuation: AsyncStream<PmdAccFrame>.Continuation?
    private var ecgSampleRate: Double = 130
    private var accSampleRate: Double = 200
    private var accFactor: Float = 1.0

    public init(connection: DeviceConnection) {
        self.id = connection.id
        self.connection = connection
    }

    /// Starts ECG (default 130 Hz, 14-bit) and streams frames until the connection drops.
    public func ecg(sampleRate: Double = 130) async throws -> AsyncStream<PmdEcgFrame> {
        let settings = PmdCodec.setting(.sampleRate, UInt32(sampleRate)) + PmdCodec.setting(.resolution, 14)
        ecgSampleRate = sampleRate
        _ = try await start(.ecg, settings: settings)
        let (stream, continuation) = AsyncStream.makeStream(of: PmdEcgFrame.self)
        ecgContinuation = continuation
        startReaderIfNeeded()
        return stream
    }

    /// Starts accelerometer (default 200 Hz, 16-bit, ±8 g) and streams frames until
    /// the connection drops. The milli-g scaling `factor` comes from the start response.
    public func acc(sampleRate: Double = 200, range: UInt32 = 8) async throws -> AsyncStream<PmdAccFrame> {
        let settings = PmdCodec.setting(.sampleRate, UInt32(sampleRate))
            + PmdCodec.setting(.resolution, 16) + PmdCodec.setting(.range, range)
        accSampleRate = sampleRate
        let response = try await start(.acc, settings: settings)
        accFactor = PmdCodec.factor(fromStartResponse: response.parameters) ?? 1.0
        let (stream, continuation) = AsyncStream.makeStream(of: PmdAccFrame.self)
        accContinuation = continuation
        startReaderIfNeeded()
        return stream
    }

    public func disconnect() async {
        reader?.cancel()
        reader = nil
        ecgContinuation?.finish()
        ecgContinuation = nil
        accContinuation?.finish()
        accContinuation = nil
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
        let control = try await controlStream()
        try await connection.write(PmdCodec.startCommand(measurement, settings: settings))
        for await chunk in control {
            guard let response = PmdCodec.parseControlResponse(chunk),
                  response.opCode == 0x02, response.measurementType == measurement.rawValue else { continue }
            guard response.isSuccess else { throw PmdError.startRejected(response.errorCode) }
            active.insert(measurement)
            return response
        }
        throw PmdError.noResponse
    }

    private func controlStream() async throws -> AsyncStream<Data> {
        if let control { return control }
        let stream = try await connection.subscribe(PolarH10.pmdControlPoint)
        control = stream
        return stream
    }

    /// The one consumer of the shared data characteristic: routes each frame to
    /// its measurement's stream. Frames for a measurement not (yet) streaming are
    /// dropped by the nil-continuation check.
    private func startReaderIfNeeded() {
        guard reader == nil else { return }
        reader = Task {
            for await chunk in connection.inbound {
                switch PmdCodec.measurementType(of: chunk) {
                case .ecg:
                    if let frame = PmdCodec.parseEcg(chunk, sampleRate: ecgSampleRate) {
                        ecgContinuation?.yield(frame)
                    }
                case .acc:
                    if let frame = PmdCodec.parseAcc(chunk, sampleRate: accSampleRate, factor: accFactor) {
                        accContinuation?.yield(frame)
                    }
                case nil:
                    break
                }
            }
            ecgContinuation?.finish()
            accContinuation?.finish()
        }
    }
}
