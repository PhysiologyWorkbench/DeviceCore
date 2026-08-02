import Foundation
import CoreBluetooth

/// A thin reader over a notify-only `DeviceConnection`: maps each inbound
/// `0x2A37` chunk through `HeartRateCodec` into an `AsyncStream<HeartRate>`. The
/// input-side counterpart to a vendor kit's session, but far lighter — no
/// identify, no request/response, pure stream. It is the degenerate
/// `DeviceSession` caller: one source, one standing subscription, no request ever.
public actor HeartRateReader {
    public let id: PeripheralID

    private let connection: DeviceConnection
    private let session = DeviceSession()

    public init(connection: DeviceConnection) {
        self.id = connection.id
        self.connection = connection
    }

    /// Live heart-rate readings, one per notification. The stream ends when the
    /// connection drops.
    public func readings() async -> AsyncStream<HeartRate> {
        await readings(from: connection.inbound)
    }

    /// Like `readings()`, but over a second notify subscription rather than the
    /// connection's bound rx — for a connection whose resolver bound a
    /// control-point pair for some other measurement, with HR taken alongside.
    public func readings(subscribing characteristic: sending CBUUID) async throws -> AsyncStream<HeartRate> {
        await readings(from: try await connection.subscribe(characteristic))
    }

    public func disconnect() async {
        await session.stop()
        await connection.disconnect()
    }

    private func readings(from source: AsyncStream<Data>) async -> AsyncStream<HeartRate> {
        await session.consume(source)
        let (_, stream) = await session.subscribe(HeartRateCodec.parse)
        return stream
    }
}
