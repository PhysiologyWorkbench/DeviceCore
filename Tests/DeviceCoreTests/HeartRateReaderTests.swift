import Testing
import Foundation
import CoreBluetooth
@testable import DeviceCore

/// The streaming path `HeartRateCodecTests` cannot reach: which source the frames
/// come off, and what happens to the stream when that source goes away.
@Suite struct HeartRateReaderTests {
    /// Flags 0x10 (RR present), the bpm, and one 1024-tick RR interval — one second.
    private func frame(bpm: UInt8) -> Data { Data([0x10, bpm, 0x00, 0x04]) }

    /// `HeartRateService.measurement` is computed, not stored, so each use gets
    /// its own instance — which is what `readings(subscribing:)`'s `sending`
    /// parameter needs.
    private var heartRateMeasurement: CBUUID { HeartRateService.measurement }

    @Test func readingsComeOffTheBoundRxCharacteristic() async throws {
        let connection = FakeConnection()
        let reader = HeartRateReader(connection: connection)
        let stream = await reader.readings()
        connection.push(frame(bpm: 60))
        var readings = stream.makeAsyncIterator()
        let reading = await readings.next()
        #expect(reading?.bpm == 60)
        #expect(reading?.rrIntervalsMs == [1000])
    }

    /// HR riding a connection whose resolver bound a control-point pair instead:
    /// the bound rx is then someone else's stream, and nothing on it may show up
    /// here.
    @Test func readingsComeOffASubscribedCharacteristic() async throws {
        let connection = FakeConnection()
        let reader = HeartRateReader(connection: connection)
        let stream = try await reader.readings(subscribing: heartRateMeasurement)
        connection.push(frame(bpm: 99))
        connection.push(frame(bpm: 60), on: heartRateMeasurement)
        var readings = stream.makeAsyncIterator()
        #expect(await readings.next()?.bpm == 60)
    }

    @Test func theStreamEndsWhenTheConnectionDrops() async throws {
        let connection = FakeConnection()
        let reader = HeartRateReader(connection: connection)
        let stream = await reader.readings()
        let drained = Task { for await _ in stream {}; return true }
        await reader.disconnect()
        #expect(await drained.value)
    }
}
