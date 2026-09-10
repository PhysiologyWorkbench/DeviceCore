import Testing
import Foundation
@testable import DeviceCore

/// A session dropped without `stop()` must end what it was serving: a dropped
/// continuation does not finish its stream, so without a `deinit` a subscriber
/// suspends for ever and the pump keeps draining a source nobody reads. The
/// technique is `ControlLoopLifetimeTests`': hold the object only weakly, let the
/// strong references go, then poll rather than sleep.
@Suite struct DeviceSessionLifetimeTests {
    @Test func aSessionDroppedWithoutStopFinishesItsSubscribersAndDeallocates() async throws {
        weak var released: DeviceSession?
        // A source that never yields and never finishes — the pump has nothing
        // to exit on but cancellation.
        let (source, _) = AsyncStream.makeStream(of: Data.self)
        let stream: AsyncStream<Data>
        do {
            let session = DeviceSession()
            released = session
            await session.consume(source)
            (_, stream) = await session.subscribe { $0 }
        }
        let drained = Task { for await _ in stream {}; return true }
        let deadline = ContinuousClock.now + .seconds(2)
        while released != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil, "the pump outlived the session that owns it")
        #expect(await drained.value, "the subscriber outlived the session")
    }

    /// The reader is the case the card was written for: a caller holding only the
    /// returned stream — the natural spelling — must not hang when the reader goes.
    @Test func aReaderDroppedWithoutDisconnectFinishesItsReadings() async throws {
        let connection = FakeConnection()
        let stream: AsyncStream<HeartRate>
        do {
            let reader = HeartRateReader(connection: connection)
            stream = await reader.readings()
        }
        let drained = Task { for await _ in stream {}; return true }
        #expect(await drained.value)
    }
}
