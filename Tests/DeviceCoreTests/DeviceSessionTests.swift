import Testing
import Foundation
@testable import DeviceCore

/// The shared mechanism, tested without any vendor: frames are pushed straight
/// into it and the assertions are about correlation, demux and teardown.
@Suite struct DeviceSessionTests {
    /// Registering a request and delivering a frame are each several actor hops
    /// away from the caller, so a test that asserts across them has to let them run.
    private func settle() async { try? await Task.sleep(for: .milliseconds(20)) }

    private func session() -> (DeviceSession, AsyncStream<Data>.Continuation) {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let session = DeviceSession()
        Task { await session.consume(stream) }
        return (session, continuation)
    }

    /// Everything, parsed as itself — the null `select`.
    private let anyFrame: @Sendable (Data) -> Data? = { $0 }

    @Test func requestTimesOutWhenNothingMatches() async throws {
        let (session, continuation) = session()
        await settle()
        continuation.yield(Data([0x01]))
        await #expect(throws: SessionError.timedOut) {
            try await session.request(timeout: .milliseconds(50)) { $0 == Data([0x02]) ? $0 : nil }
        }
    }

    /// A device may answer a superseded query late; the mechanism's rule is that
    /// the abandoned caller hears about it rather than waiting for the timeout.
    @Test func aSecondRequestSupersedesTheFirst() async throws {
        let (session, continuation) = session()
        let first = Task { try await session.request(timeout: .seconds(5), matching: anyFrame) }
        await settle()
        let second = Task { try await session.request(timeout: .seconds(5), matching: anyFrame) }
        await settle()
        continuation.yield(Data([0x07]))
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == Data([0x07]))
    }

    /// The load-bearing rule: a sensor frame must not answer a query running
    /// underneath it, even when the query would have accepted it.
    @Test func aStandingSubscriptionConsumesBeforeARequest() async throws {
        let (session, continuation) = session()
        let (_, sensor) = await session.subscribe { $0.first == 0xAA ? $0 : nil }
        let query = Task { try await session.request(timeout: .seconds(5), matching: anyFrame) }
        await settle()
        continuation.yield(Data([0xAA, 0x01]))       // the subscription's
        continuation.yield(Data([0x0B]))             // the query's
        #expect(try await query.value == Data([0x0B]))
        var frames = sensor.makeAsyncIterator()
        #expect(await frames.next() == Data([0xAA, 0x01]))
    }

    @Test func theFramerSplitsOneNotificationIntoMessages() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        let session = DeviceSession()
        await session.consume(stream) { chunk in
            chunk.split(separator: UInt8(ascii: ";")).map { Data($0) }
        }
        let (_, messages) = await session.subscribe(anyFrame)
        continuation.yield(Data("one;two;".utf8))
        var iterator = messages.makeAsyncIterator()
        #expect(await iterator.next() == Data("one".utf8))
        #expect(await iterator.next() == Data("two".utf8))
    }

    /// The link going away is not a timeout, and the caller should not be made to
    /// wait for one to find out.
    @Test func theSourceRunningOutEndsEverything() async throws {
        let (session, continuation) = session()
        let (_, sensor) = await session.subscribe(anyFrame)
        let drained = Task { var count = 0; for await _ in sensor { count += 1 }; return count }
        let query = Task { try await session.request(timeout: .seconds(30), matching: anyFrame) }
        await settle()
        continuation.finish()
        await #expect(throws: TransportError.notConnected) { try await query.value }
        #expect(await drained.value == 0)
        // And a request made afterwards fails at once rather than waiting 30 s.
        await #expect(throws: TransportError.notConnected) {
            try await session.request(timeout: .seconds(30), matching: anyFrame)
        }
    }

    @Test func cancellingOneSubscriptionLeavesTheOther() async throws {
        let (session, continuation) = session()
        let (first, ended) = await session.subscribe(anyFrame)
        let (_, kept) = await session.subscribe { $0.first == 0xAA ? $0 : nil }
        let drained = Task { var count = 0; for await _ in ended { count += 1 }; return count }
        await settle()
        await session.cancel(first)
        continuation.yield(Data([0xAA]))
        #expect(await drained.value == 0)
        var frames = kept.makeAsyncIterator()
        #expect(await frames.next() == Data([0xAA]))
    }

    /// The hook a caller needs to switch the device's own stream off again when its
    /// consumer walks away.
    @Test func droppingASubscriptionStreamRunsItsTerminationHook() async throws {
        let (session, _) = session()
        let terminated = Terminated()
        do {
            _ = await session.subscribe(anyFrame, onTermination: { terminated.record() })
        }
        // The stream is deallocated here; termination is asynchronous.
        try await Task.sleep(for: .milliseconds(50))
        #expect(terminated.value)
    }

    @Test func stopCancelsTheOutstandingRequest() async throws {
        let (session, _) = session()
        let query = Task { try await session.request(timeout: .seconds(30), matching: anyFrame) }
        await settle()
        await session.stop()
        await #expect(throws: CancellationError.self) { try await query.value }
    }
}

/// A flag a `@Sendable` termination hook can set.
private final class Terminated: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func record() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}
