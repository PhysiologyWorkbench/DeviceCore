import Foundation
@testable import DeviceCore

/// An `Actuator` standing in for a toy: it records every setpoint, can refuse a
/// `.drop` write the way a busy link does, can suspend one write in flight, and
/// can fail outright the way a dropped connection does. Locked rather than an
/// actor, so a test can inspect it without an await in the middle of an assertion.
final class FakeActuator: Actuator, @unchecked Sendable {
    struct Setpoint {
        let ordinal: Int
        let level: Double
        let ifBusy: BusyPolicy
        /// When the write arrived, for the pulse tests' edge-timing assertions.
        let at: ContinuousClock.Instant

        /// The raw step a 0…20 toy would have been sent. The scaling itself is the
        /// vendor session's, and tested there; here it only keeps the assertions in
        /// integers, away from the float equality `0.4 + 0.2 != 0.6` would bring.
        var step: Int { Int((level * 20).rounded()) }
        var isDrop: Bool { if case .drop = ifBusy { true } else { false } }
    }

    private let lock = NSLock()
    private var storedSetpoints: [Setpoint] = []
    private var linkBusy = false
    private var linkFailed = false
    private var holdNext = false
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var arrivalWaiter: CheckedContinuation<Void, Never>?

    // MARK: Inspection

    var setpoints: [Setpoint] {
        lock.withLock { storedSetpoints }
    }

    /// The recorded steps, which is what most assertions care about.
    var steps: [Int] {
        setpoints.map(\.step)
    }

    /// While busy, a `.drop` write is refused and a `.wait` write still succeeds —
    /// the fake does not model the queue, only the outcome the caller sees.
    func setBusy(_ busy: Bool) {
        lock.withLock { linkBusy = busy }
    }

    /// The link is gone: every write from here on throws.
    func fail() {
        lock.withLock { linkFailed = true }
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

    // MARK: Actuator

    /// Small enough that a pulse test's ramps finish in a few tens of
    /// milliseconds; individual tests override where the arithmetic wants a
    /// particular step size.
    var writeGranularity: Duration = .milliseconds(10)

    func setVibration(_ ordinal: Int, _ level: Double, ifBusy: BusyPolicy) async throws -> Bool {
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
        return try lock.withLock {
            guard !linkFailed else { throw TransportError.notConnected }
            guard linkBusy, case .drop = ifBusy else {
                storedSetpoints.append(Setpoint(ordinal: ordinal, level: level, ifBusy: ifBusy, at: .now))
                return true
            }
            return false
        }
    }
}
