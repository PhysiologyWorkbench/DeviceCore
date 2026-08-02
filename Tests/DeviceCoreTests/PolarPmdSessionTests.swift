import Testing
import Foundation
@testable import DeviceCore

/// The PMD handshake and the demux above it, against `FakeConnection`. The strap's
/// control point and its data characteristic are two sources into one session, so
/// these tests push on both.
@Suite struct PolarPmdSessionTests {
    /// The start command reaches the wire before the session registers its waiter,
    /// so a responder that fires on the write alone can answer too early. Waiting a
    /// little past the write is what a real radio does anyway.
    private func respond(to connection: FakeConnection,
                         after writes: Int,
                         with frame: [UInt8]) -> Task<Void, Never> {
        Task {
            while connection.writes.count < writes { try? await Task.sleep(for: .milliseconds(2)) }
            try? await Task.sleep(for: .milliseconds(20))
            connection.push(Data(frame), on: PolarH10.pmdControlPoint)
        }
    }

    private func startResponse(_ measurement: PmdMeasurement) -> [UInt8] {
        [PmdCodec.controlResponseCode, 0x02, measurement.rawValue, 0x00, 0x00]
    }

    private func dataFrame(_ measurement: PmdMeasurement, content: [UInt8]) -> Data {
        Data([measurement.rawValue] + [UInt8](repeating: 0, count: 8) + [0x00] + content)
    }

    /// The acceptance criterion of this step. Before the shared session there was no
    /// timeout on the handshake at all: a strap that accepted the subscription and
    /// then said nothing left the caller awaiting for ever.
    @Test func startThrowsWhenTheStrapNeverAnswers() async throws {
        let connection = FakeConnection()
        let session = PolarPmdSession(connection: connection, handshakeTimeout: .milliseconds(50))
        await #expect(throws: PmdError.noResponse) { _ = try await session.ecg() }
        #expect(connection.writes.first?.bytes.first == 0x02)
    }

    /// The other silence: the control point closes rather than staying quiet. Same
    /// answer to the caller, and it must not wait out the timeout to get it.
    @Test func startThrowsWhenTheControlPointCloses() async throws {
        let connection = FakeConnection()
        let session = PolarPmdSession(connection: connection)
        let closer = Task {
            while connection.writes.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
            connection.finishSubscription(PolarH10.pmdControlPoint)
        }
        await #expect(throws: PmdError.noResponse) { _ = try await session.ecg() }
        await closer.value
    }

    @Test func aRejectedStartSurfacesTheErrorCode() async throws {
        let connection = FakeConnection()
        let session = PolarPmdSession(connection: connection)
        let responder = respond(to: connection, after: 1,
                                with: [PmdCodec.controlResponseCode, 0x02, 0x00, 0x05])
        await #expect(throws: PmdError.startRejected(5)) { _ = try await session.ecg() }
        await responder.value
    }

    /// One data characteristic carries both measurements, and each subscription's
    /// parse is what separates them — no frame reaches the wrong stream, and the
    /// control point's own traffic reaches neither.
    @Test func ecgAndAccFramesReachTheirOwnStreams() async throws {
        let connection = FakeConnection()
        let session = PolarPmdSession(connection: connection)
        let responder = Task {
            while connection.writes.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
            try? await Task.sleep(for: .milliseconds(20))
            connection.push(Data(startResponse(.ecg)), on: PolarH10.pmdControlPoint)
            while connection.writes.count < 2 { try? await Task.sleep(for: .milliseconds(2)) }
            try? await Task.sleep(for: .milliseconds(20))
            connection.push(Data(startResponse(.acc)), on: PolarH10.pmdControlPoint)
        }
        let ecg = try await session.ecg()
        let acc = try await session.acc()
        await responder.value

        connection.push(dataFrame(.ecg, content: [0x0A, 0x00, 0x00]))
        connection.push(dataFrame(.acc, content: [0x01, 0x00, 0x02, 0x00, 0x03, 0x00]))
        // A late control-point response, which is neither measurement's.
        connection.push(Data(startResponse(.ecg)))

        var ecgFrames = ecg.makeAsyncIterator()
        #expect(await ecgFrames.next()?.samplesMicrovolts == [10])
        var accFrames = acc.makeAsyncIterator()
        #expect(await accFrames.next()?.samples == [SIMD3(1, 2, 3)])
    }

    @Test func disconnectStopsEveryStartedMeasurement() async throws {
        let connection = FakeConnection()
        let session = PolarPmdSession(connection: connection)
        let responder = respond(to: connection, after: 1, with: startResponse(.ecg))
        _ = try await session.ecg()
        await responder.value
        await session.disconnect()
        #expect(connection.writes.map(\.bytes).contains(PmdCodec.stopCommand(.ecg)))
    }
}
