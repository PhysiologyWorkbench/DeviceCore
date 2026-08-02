import Foundation
import CoreBluetooth

/// A thin reader over a notify-only `DeviceConnection`: maps each inbound
/// `0x2A37` chunk through `HeartRateCodec` into an `AsyncStream<HeartRate>`. The
/// input-side counterpart to `LovenseSession`, but far lighter — no identify, no
/// request/response, pure stream. An `actor` so it owns its reader `Task` safely.
public actor HeartRateReader {
    public let id: PeripheralID

    private let connection: DeviceConnection
    private var reader: Task<Void, Never>?

    public init(connection: DeviceConnection) {
        self.id = connection.id
        self.connection = connection
    }

    /// Live heart-rate readings, one per notification. The stream ends when the
    /// connection drops.
    public func readings() -> AsyncStream<HeartRate> {
        let (stream, continuation) = AsyncStream.makeStream(of: HeartRate.self)
        reader = Task { [connection] in
            for await chunk in connection.inbound {
                if let hr = HeartRateCodec.parse(chunk) {
                    continuation.yield(hr)
                }
            }
            continuation.finish()
        }
        return stream
    }

    /// Like `readings()`, but over a second notify subscription rather than the
    /// connection's bound rx — for a connection whose resolver binds other
    /// endpoints (e.g. the PMD control point + data), with HR taken alongside.
    public func readings(subscribing characteristic: sending CBUUID) async throws -> AsyncStream<HeartRate> {
        let chunks = try await connection.subscribe(characteristic)
        let (stream, continuation) = AsyncStream.makeStream(of: HeartRate.self)
        reader = Task {
            for await chunk in chunks {
                if let hr = HeartRateCodec.parse(chunk) {
                    continuation.yield(hr)
                }
            }
            continuation.finish()
        }
        return stream
    }

    public func disconnect() async {
        reader?.cancel()
        reader = nil
        await connection.disconnect()
    }
}
