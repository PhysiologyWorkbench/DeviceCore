import Foundation

/// What `ControlLoop` needs of a device, and the whole of it: set one vibrator to
/// a level in 0…1, and say whether the bytes reached the link. A vendor kit
/// conforms its session; `DeviceCore` never learns the wire protocol behind it.
///
/// **The stop authority of everything above reaches exactly as far as this one
/// method does.** Every stop here — the fade, the watchdog, the hard stop — is a
/// zero through `setVibration`, so a device whose firmware drives its own motor
/// from its own sensor cannot be stopped by this library at all, however the loop
/// behaves. That such a mode exists is not hypothetical, and guarding against it
/// is the vendor kit's business: the kit's documentation says which modes its
/// devices have and what a caller must do about them.
public protocol Actuator: Sendable {
    /// The grid this device's command deliveries quantise to — for a BLE toy,
    /// its measured connection interval, or the finest command spacing the
    /// bench has shown it to render. A pulse whose duration is a whole multiple
    /// of this lands both edges the same distance into their delivery slots, so
    /// the quantisation cancels out of the felt length instead of adding to it.
    /// Callers choosing pulse durations should round to this.
    var writeGranularity: Duration { get }

    @discardableResult
    func setVibration(_ ordinal: Int, _ level: Double, ifBusy: BusyPolicy) async throws -> Bool
}

/// Why the loop stopped. The loop itself can only ever originate `.sensorLost`
/// (its watchdog) and `.actuatorLost` (a failed write); the rest are handed to it.
public enum StopReason: Sendable, Equatable {
    /// A person pressed stop.
    case operatorStop
    /// A distress signature in the physiology.
    case distress
    /// No sensor input within the limits' `inputTimeout`.
    case sensorLost
    /// The write failed — the link to the actuator is gone.
    case actuatorLost
}

/// The applied level and, once stopped, why. Emitted on every change.
public struct ControlStatus: Sendable, Equatable {
    public let level: Double
    public let stopped: StopReason?
}

/// The coalescing sender: sensor input sets a target at whatever rate it likes,
/// and a tick task turns that into at most one write per interval. `setTarget`
/// only stores, so a backlog cannot form — the newest value simply replaces the
/// last one, and a link that cannot take a write this tick gets the same value
/// offered again on the next (ARCHITECTURE.md §Latency).
///
/// The safety envelope lives *inside* the loop rather than above it: every level
/// this type commands has been through `SafetyLimits`, the hard stop latches here,
/// and the sensor watchdog runs here. There is no path from a control signal to a
/// device that goes around any of it (ARCHITECTURE.md principle 9).
///
/// Drives one vibrator (ordinal 0). Multi-feature actuation is a later concern;
/// the second case will say what shape it needs.
public actor ControlLoop {
    private let actuator: any Actuator
    private let tick: Duration
    private var limits: SafetyLimits
    private let statusContinuation: AsyncStream<ControlStatus>.Continuation

    /// The applied level — what the actuator was last known to be at, not what the
    /// control signal asked for.
    private var level: Double = 0
    /// The last level a write actually delivered, so a dropped write is retried
    /// rather than assumed to have landed.
    private var lastSent: Double?
    private var target: Double = 0
    private var stopped: StopReason?
    /// Seconds since the last `heartbeat`, advanced by the tick rather than read
    /// off a clock — the watchdog is then as deterministic as everything else here.
    private var sinceInput: TimeInterval = 0
    /// Whether the watchdog counts. Engaged by `expectInput(true)` for exactly
    /// the life of a session: a loop that is merely connected has no sensor
    /// feeding it, and must not be faulted for that silence.
    private var expectingInput = false
    /// Bumped when a hard stop begins. A tick suspended in a write when the stop
    /// lands sees the change on resume and discards its bookkeeping — otherwise it
    /// would record a level the stop's zero has already overwritten on the device,
    /// and the next tick would fade down from it, re-energising a stopped toy.
    private var stopEpoch = 0
    private var ticker: Task<Void, Never>?
    /// The task driving a pulse's edges against absolute deadlines. While it
    /// exists, it owns the output and the tick keeps only the watchdog.
    private var pulseTask: Task<Void, Never>?
    /// Guards `pulseTask` against a finished pulse clearing its successor.
    private var pulseGeneration = 0

    public let status: AsyncStream<ControlStatus>

    /// The level the actuator was last known to be at. `status` is the stream of
    /// changes; this is the same value for a caller that only wants to look.
    public var appliedLevel: Double { level }
    /// Why the loop stopped, or nil while it is free to run.
    public var stopReason: StopReason? { stopped }

    public init(actuator: any Actuator,
                limits: SafetyLimits = SafetyLimits(),
                tick: Duration = .milliseconds(50)) {
        self.actuator = actuator
        self.limits = limits
        self.tick = tick
        var continuation: AsyncStream<ControlStatus>.Continuation!
        self.status = AsyncStream { continuation = $0 }
        self.statusContinuation = continuation
    }

    /// Begins ticking. The watchdog stays disengaged until `expectInput(true)`.
    public func start() {
        guard ticker == nil else { return }
        sinceInput = 0
        let (interval, seconds) = (tick, tick.seconds)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // Ends with the loop: a loop dropped without `shutdown` must not
                // leave its ticker sleeping forever.
                guard let self else { return }
                await self.tick(dt: seconds)
            }
        }
    }

    /// Replaces the envelope. A tightened ceiling takes effect on the next tick,
    /// which pulls the level back inside it rather than honouring the old one.
    public func setLimits(_ limits: SafetyLimits) {
        self.limits = limits
    }

    /// The level the control signal wants, 0…1. Last one before the next tick
    /// wins; a stopped loop ignores it entirely until `release`.
    public func setTarget(_ level: Double) {
        guard stopped == nil else { return }
        target = level
    }

    /// One beat: rise to `level` now and begin the fall `duration` after the
    /// rise began, every write scheduled against an absolute deadline on the
    /// actuator's `writeGranularity` grid — never the tick, whose quantisation
    /// is exactly the pulse-length jitter this exists to remove. The envelope
    /// applies as on the tick path: the level is clamped to the ceiling and
    /// both ramps run at the limits' rates, in granularity-sized steps.
    ///
    /// A pulse ends in silence — the target is zeroed, so nothing re-rises —
    /// and a new pulse supersedes a running one. Durations that are whole
    /// multiples of the granularity render with the least length jitter; a
    /// rise slower than `duration` simply starts the fall when it completes.
    /// A stopped loop ignores this entirely, like `setTarget`.
    public func pulse(_ level: Double, for duration: Duration) {
        guard stopped == nil else { return }
        pulseTask?.cancel()
        target = 0
        pulseGeneration += 1
        let generation = pulseGeneration
        pulseTask = Task { [weak self] in
            await self?.runPulse(to: level, for: duration)
            await self?.pulseEnded(generation)
        }
    }

    /// Notes that the sensor is alive. The watchdog fades the loop down if this
    /// goes quiet for longer than the limits allow.
    public func heartbeat() {
        sinceInput = 0
    }

    /// Engages the watchdog: from now until `release`, `heartbeat` must keep
    /// arriving within the limits' `inputTimeout` or the loop fades down. Called
    /// when a session starts — the grace period starts here.
    public func expectInput(_ expecting: Bool) {
        expectingInput = expecting
        sinceInput = 0
    }

    /// Ramps to zero at the fall-rate limit and stops. New targets are ignored
    /// from this moment, so the fade cannot be fought by a control signal that has
    /// not noticed yet.
    public func fadeDown(_ reason: StopReason) {
        guard stopped == nil else { return }
        cancelPulse()
        target = 0
        stopped = reason
        publish()
    }

    /// Cuts output now — one zero write, not rate-limited, not coalesced. This is
    /// the control the safety case rests on, so it uses `.wait`: a dropped stop is
    /// not acceptable in the way a dropped setpoint is.
    ///
    /// On a loop already stopping, the cut still happens — an operator ending a
    /// fade early must always work — but the first reason sticks: a distress fade
    /// cut short is still a distress stop, and the record must say so.
    public func hardStop(_ reason: StopReason = .operatorStop) async {
        cancelPulse()
        target = 0
        if stopped == nil { stopped = reason }
        stopEpoch += 1
        _ = try? await actuator.setVibration(0, 0, ifBusy: .wait)
        level = 0
        lastSent = 0
        publish()
    }

    /// Clears the stop so the loop can be armed again, and disengages the
    /// watchdog — the session is over, no input is owed. Deliberately separate
    /// from acknowledging the stop: nothing resumes on its own.
    public func release() {
        stopped = nil
        expectingInput = false
        sinceInput = 0
        publish()
    }

    /// Stops output and ends the tick task. The reason says why the loop is
    /// going away — a lost link is not an operator stop.
    public func shutdown(_ reason: StopReason = .operatorStop) async {
        await hardStop(reason)
        ticker?.cancel()
        ticker = nil
        statusContinuation.finish()
    }

    /// One step of the loop. Internal so tests can drive it directly and be free
    /// of wall-clock timing; the tick task is its only other caller.
    func tick(dt: TimeInterval) async {
        sinceInput += dt
        if stopped == nil, expectingInput, sinceInput >= limits.inputTimeout.seconds {
            fadeDown(.sensorLost)
        }
        // A running pulse owns the output; the tick keeps only the watchdog.
        guard pulseTask == nil else { return }
        _ = await command(limits.step(current: level, target: stopped == nil ? target : 0, dt: dt))
    }

    /// A pulse's edges, one write per granularity slot against deadlines fixed
    /// at the start — so the rendered length depends on the deadlines and not on
    /// when any individual write got through. A cancellation (a stop, or the
    /// pulse that superseded this one) surfaces at the next sleep and ends it.
    private func runPulse(to goal: Double, for duration: Duration) async {
        let spacing = max(actuator.writeGranularity, .milliseconds(1))
        let dt = spacing.seconds
        let clock = ContinuousClock()
        let start = clock.now
        do {
            // The level the ramp is heading for — approached from below normally,
            // from above when this pulse superseded a taller one mid-flight.
            let plateau = min(max(goal, 0), limits.ceiling)
            var slot = 0
            while stopped == nil {
                let next = limits.step(current: level, target: goal, dt: dt)
                guard await command(next) else { return }
                guard next != plateau else { break }
                slot += 1
                try await clock.sleep(until: start + spacing * slot, tolerance: .zero)
            }
            try await clock.sleep(until: start + duration, tolerance: .zero)
            slot = 0
            while stopped == nil {
                let next = limits.step(current: level, target: 0, dt: dt)
                guard await command(next) else { return }
                guard next > 0 else { break }
                slot += 1
                try await clock.sleep(until: start + duration + spacing * slot, tolerance: .zero)
            }
        } catch {}
    }

    private func pulseEnded(_ generation: Int) {
        guard generation == pulseGeneration else { return }
        pulseTask = nil
    }

    private func cancelPulse() {
        pulseTask?.cancel()
        pulseTask = nil
    }

    /// The one guarded path a level takes to the device, shared by the tick and
    /// the pulse. Returns whether the caller may keep driving — false when the
    /// link is gone or a hard stop landed while the write was in flight.
    private func command(_ next: Double) async -> Bool {
        guard next != lastSent else {
            level = next
            return true
        }
        // A zero is the tail of a fade or a stop, and must not be dropped; every
        // other level is superseded by the next offer if the link is busy.
        let policy: BusyPolicy = next == 0 ? .wait : .drop
        let epoch = stopEpoch
        do {
            // A refused `.drop` write advances nothing: the level stays where it
            // is for the next offer, so a ramp cannot jump by what was dropped.
            guard try await actuator.setVibration(0, next, ifBusy: policy) else { return true }
        } catch {
            // The write failed, so the link is gone. Nothing can be commanded and
            // nothing should be assumed about the device's state.
            fadeDown(.actuatorLost)
            return false
        }
        // A hard stop that landed while the write was in flight has already zeroed
        // the device and the bookkeeping; committing `next` here would undo it.
        guard epoch == stopEpoch else { return false }
        level = next
        lastSent = next
        publish()
        return true
    }

    private func publish() {
        statusContinuation.yield(ControlStatus(level: level, stopped: stopped))
    }
}

extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
