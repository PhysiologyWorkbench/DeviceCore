import Foundation

public enum PmdError: Error, Sendable, Equatable {
    /// The device rejected a `REQUEST_MEASUREMENT_START` with this PMD error code.
    case startRejected(UInt8)
    /// The control point closed before a start response arrived.
    case noResponse
}

/// Streams one PMD measurement (ECG or ACC) off a Polar H10. The input-side
/// counterpart to `HeartRateReader`, but with a handshake: it subscribes the
/// control point, writes `REQUEST_MEASUREMENT_START`, awaits the success response,
/// then decodes the data notifications through `PmdCodec`. `disconnect` sends
/// `STOP_MEASUREMENT` so the strap stops cleanly. One measurement per reader.
public actor PmdReader {
    public let id: PeripheralID

    private let connection: DeviceConnection
    private var reader: Task<Void, Never>?
    private var active: PmdMeasurement?

    public init(connection: DeviceConnection) {
        self.id = connection.id
        self.connection = connection
    }

    /// Starts ECG (default 130 Hz, 14-bit) and streams frames until the connection drops.
    public func ecg(sampleRate: Double = 130) async throws -> AsyncStream<PmdEcgFrame> {
        let settings = PmdCodec.setting(.sampleRate, UInt32(sampleRate)) + PmdCodec.setting(.resolution, 14)
        _ = try await start(.ecg, settings: settings)
        let (stream, continuation) = AsyncStream.makeStream(of: PmdEcgFrame.self)
        reader = Task { [connection] in
            for await chunk in connection.inbound {
                if let frame = PmdCodec.parseEcg(chunk, sampleRate: sampleRate) { continuation.yield(frame) }
            }
            continuation.finish()
        }
        return stream
    }

    /// Starts accelerometer (default 200 Hz, 16-bit, ±8 g) and streams frames until
    /// the connection drops. The milli-g scaling `factor` comes from the start response.
    public func acc(sampleRate: Double = 200, range: UInt32 = 8) async throws -> AsyncStream<PmdAccFrame> {
        let settings = PmdCodec.setting(.sampleRate, UInt32(sampleRate))
            + PmdCodec.setting(.resolution, 16) + PmdCodec.setting(.range, range)
        let response = try await start(.acc, settings: settings)
        let factor = PmdCodec.factor(fromStartResponse: response.parameters) ?? 1.0
        let (stream, continuation) = AsyncStream.makeStream(of: PmdAccFrame.self)
        reader = Task { [connection] in
            for await chunk in connection.inbound {
                if let frame = PmdCodec.parseAcc(chunk, sampleRate: sampleRate, factor: factor) { continuation.yield(frame) }
            }
            continuation.finish()
        }
        return stream
    }

    public func disconnect() async {
        reader?.cancel()
        reader = nil
        if let active {
            _ = try? await connection.write(PmdCodec.stopCommand(active))
            self.active = nil
        }
        await connection.disconnect()
    }

    /// Subscribes the control point, requests a measurement start, and returns the
    /// success response (whose parameters carry the negotiated settings + factor).
    private func start(_ measurement: PmdMeasurement, settings: [UInt8]) async throws -> PmdControlResponse {
        let control = try await connection.subscribe(PolarH10.pmdControlPoint)
        try await connection.write(PmdCodec.startCommand(measurement, settings: settings))
        for await chunk in control {
            guard let response = PmdCodec.parseControlResponse(chunk),
                  response.opCode == 0x02, response.measurementType == measurement.rawValue else { continue }
            guard response.isSuccess else { throw PmdError.startRejected(response.errorCode) }
            active = measurement
            return response
        }
        throw PmdError.noResponse
    }
}
