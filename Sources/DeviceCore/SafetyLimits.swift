import Foundation

/// The bounds every setpoint on the control path is held to: how high the output
/// may go, how fast it may get there, how fast a fade descends, and how long the
/// loop may run without hearing from its sensor.
///
/// Pure and value-typed, so the whole safety envelope is testable without a radio
/// — `ControlLoop` applies it on every tick and there is no path to a device that
/// goes around it. See ARCHITECTURE.md principle 9.
public struct SafetyLimits: Sendable, Equatable {
    /// Hard maximum level, 0…1. No target above this is ever commanded.
    public var ceiling: Double
    /// How much the level may increase per second. The ramp limit is what keeps a
    /// step change in the control signal from becoming a step change on the body.
    public var riseRatePerSecond: Double
    /// How much the level may decrease per second. Descending is the safe
    /// direction, so this is normally the more generous of the two; a hard stop
    /// ignores it entirely.
    public var fallRatePerSecond: Double
    /// How long the loop may go without a sensor sample before fading to zero.
    public var inputTimeout: Duration

    /// Conservative defaults: three seconds from silence to full ceiling, one
    /// second back down, and a five-second sensor gap ends the session.
    public init(ceiling: Double = 0.6,
                riseRatePerSecond: Double = 0.2,
                fallRatePerSecond: Double = 0.6,
                inputTimeout: Duration = .seconds(5)) {
        self.ceiling = ceiling
        self.riseRatePerSecond = riseRatePerSecond
        self.fallRatePerSecond = fallRatePerSecond
        self.inputTimeout = inputTimeout
    }

    /// The next level to command: `target` clamped into `0...ceiling`, then
    /// approached from `current` by at most one `dt`'s worth of the applicable
    /// rate. Never overshoots the target.
    public func step(current: Double, target: Double, dt: TimeInterval) -> Double {
        let goal = min(max(target, 0), ceiling)
        let bounded = min(max(current, 0), ceiling)
        if goal > bounded {
            return min(goal, bounded + riseRatePerSecond * dt)
        } else {
            return max(goal, bounded - fallRatePerSecond * dt)
        }
    }
}
