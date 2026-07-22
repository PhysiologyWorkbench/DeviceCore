import Foundation

/// A thin reader over a notify-only `DeviceConnection`: maps each inbound
/// `0x2A37` chunk through `HeartRateCodec` into an `AsyncStream<HeartRate>`. The
/// input-side counterpart to `DeviceSession`, but far lighter — no identify, no
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
                continuation.yield(HeartRateCodec.parse(chunk))
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
