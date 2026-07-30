import Foundation
import CoreBluetooth
@testable import DeviceCore

/// A `DeviceConnection` standing in for a radio: it records every write, answers
/// the Lovense queries so `identify`/`battery` complete, and can be told to report
/// the link as busy so the `.drop` path is exercisable. Locked rather than an
/// actor, because `DeviceConnection`'s properties are nonisolated requirements.
final class FakeConnection: DeviceConnection, @unchecked Sendable {
    struct Write {
        let text: String
        let ifBusy: BusyPolicy
        let type: WriteType

        var isDrop: Bool { if case .drop = ifBusy { true } else { false } }
    }

    let id = PeripheralID(UUID())
    let inbound: AsyncStream<Data>
    let state: AsyncStream<ConnectionState>

    private let lock = NSLock()
    private var storedWrites: [Write] = []
    private var linkBusy = false
    private var connected = true
    private var holdNext = false
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation

    init() {
        var inboundCont: AsyncStream<Data>.Continuation!
        inbound = AsyncStream { inboundCont = $0 }
        inboundContinuation = inboundCont
        var stateCont: AsyncStream<ConnectionState>.Continuation!
        state = AsyncStream { stateCont = $0 }
        stateContinuation = stateCont
    }

    // MARK: Inspection

    var writes: [Write] {
        lock.withLock { storedWrites }
    }

    /// Just the command text, which is what most assertions care about.
    var commands: [String] {
        writes.map(\.text)
    }

    /// While busy, a `.drop` write is refused and a `.wait` write still succeeds —
    /// the fake does not model the queue, only the outcome the caller sees.
    func setBusy(_ busy: Bool) {
        lock.withLock { linkBusy = busy }
    }

    /// Suspends the next write until `releaseHeldWrite`, letting later writes
    /// through — so a test can run other actor work while one write is in flight.
    func holdNextWrite() {
        lock.withLock { holdNext = true }
    }

    /// Resumes once a write is suspended at the hold.
    func waitForHeldWrite() async {
        await withCheckedContinuation { continuation in
            let alreadyHeld: Bool = lock.withLock {
                if heldWrite != nil { return true }
                arrivalWaiter = continuation
                return false
            }
            if alreadyHeld { continuation.resume() }
        }
    }

    func releaseHeldWrite() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldWrite = nil }
            return heldWrite
        }
        held?.resume()
    }

    // MARK: DeviceConnection

    func write(_ bytes: Data, ifBusy: BusyPolicy, type: WriteType) async throws -> Bool {
        let hold = lock.withLock { () -> Bool in
            defer { holdNext = false }
            return holdNext
        }
        if hold {
            await withCheckedContinuation { continuation in
                let arrival = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    heldWrite = continuation
                    defer { arrivalWaiter = nil }
                    return arrivalWaiter
                }
                arrival?.resume()
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let dropped: Bool = try lock.withLock {
            guard connected else { throw TransportError.notConnected }
            guard linkBusy, case .drop = ifBusy else {
                storedWrites.append(Write(text: text, ifBusy: ifBusy, type: type))
                return false
            }
            return true
        }
        if dropped { return false }
        switch text {
        case "DeviceType;": reply("P:243:0102030405;")
        case "Battery;":    reply("78;")
        default:            break
        }
        return true
    }

    /// A reply is a later notification, never something that lands inside the
    /// write call — a session registers its waiter after writing, so a
    /// synchronous answer would arrive before anyone is listening.
    private func reply(_ frame: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(1))
            inboundContinuation.yield(Data(frame.utf8))
        }
    }

    func read(characteristic: CBUUID) async throws -> Data {
        throw TransportError.characteristicNotFound("fake connection has no readable characteristics")
    }

    func subscribe(_ characteristic: CBUUID) async throws -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {
        lock.withLock { connected = false }
        stateContinuation.yield(.disconnected(reason: nil))
        inboundContinuation.finish()
        stateContinuation.finish()
    }
}
