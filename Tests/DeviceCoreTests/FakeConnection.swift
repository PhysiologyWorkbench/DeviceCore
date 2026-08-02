import Foundation
import CoreBluetooth
@testable import DeviceCore

/// A `DeviceConnection` standing in for a radio, for the one thing DeviceCore's
/// own tests still need a connection for: where a notify-only reader's frames come
/// from, and what happens to its stream when the link goes away. The richer
/// siblings in `LovenseKitTests` and `PolarKitTests` answer their vendors' wire
/// protocols; none of that may live here. Locked rather than an actor, because
/// `DeviceConnection`'s properties are nonisolated requirements.
final class FakeConnection: DeviceConnection, @unchecked Sendable {
    let id = PeripheralID(UUID())
    let inbound: AsyncStream<Data>
    let state: AsyncStream<ConnectionState>

    private let lock = NSLock()
    private var connected = true
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    private var subscriptions: [CBUUID: AsyncStream<Data>.Continuation] = [:]

    init() {
        var inboundCont: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { inboundCont = $0 }
        inboundContinuation = inboundCont
        var stateCont: AsyncStream<ConnectionState>.Continuation!
        state = AsyncStream { stateCont = $0 }
        stateContinuation = stateCont
    }

    // MARK: Inspection

    /// Pushes a notification on the bound rx, which no write asks for.
    func push(_ bytes: Data) {
        inboundContinuation.yield(bytes)
    }

    /// Pushes a notification on a subscribed characteristic. Dropped if nothing is
    /// subscribed, as a real notification for an unsubscribed characteristic is.
    func push(_ bytes: Data, on characteristic: CBUUID) {
        lock.withLock { subscriptions[characteristic] }?.yield(bytes)
    }

    // MARK: DeviceConnection

    /// Nothing here writes — a notify-only profile has no tx — so this only has to
    /// tell the truth about a dropped link.
    func write(_ bytes: Data, ifBusy: BusyPolicy, type: WriteType) async throws -> Bool {
        try lock.withLock {
            guard connected else { throw TransportError.notConnected }
        }
        return true
    }

    func read(characteristic: CBUUID) async throws -> Data {
        throw TransportError.characteristicNotFound("fake connection has no readable characteristics")
    }

    /// A live channel, not an immediately-finished stream: a device that accepts a
    /// subscription and then says nothing is the state a reader can hang in, and a
    /// fake that finishes on the spot hides exactly that.
    func subscribe(_ characteristic: CBUUID) async throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        lock.withLock {
            subscriptions.updateValue(continuation, forKey: characteristic)
        }?.finish()
        return stream
    }

    func disconnect() async {
        let channels: [AsyncStream<Data>.Continuation] = lock.withLock {
            connected = false
            defer { subscriptions = [:] }
            return Array(subscriptions.values)
        }
        stateContinuation.yield(.disconnected(reason: nil))
        inboundContinuation.finish()
        for channel in channels { channel.finish() }
        stateContinuation.finish()
    }
}
