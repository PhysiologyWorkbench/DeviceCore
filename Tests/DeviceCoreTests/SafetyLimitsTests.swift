import Testing
import Foundation
@testable import DeviceCore

@Suite struct SafetyLimitsTests {
    let limits = SafetyLimits(ceiling: 0.6, riseRatePerSecond: 0.2, fallRatePerSecond: 0.6)

    @Test func clampsTheTargetToTheCeiling() {
        // A full-scale demand is capped, and getting there still takes the ramp.
        var level = 0.0
        for _ in 0..<10 { level = limits.step(current: level, target: 1.0, dt: 1) }
        #expect(level == 0.6)
    }

    @Test func clampsANegativeTargetToZero() {
        #expect(limits.step(current: 0.1, target: -5, dt: 1) == 0)
    }

    @Test func limitsTheRiseRate() {
        #expect(limits.step(current: 0, target: 0.5, dt: 1) == 0.2)
        #expect(limits.step(current: 0, target: 0.5, dt: 0.5) == 0.1)
        // Rate is per second, so the same ground is covered in the same time
        // whatever the tick length.
        var coarse = 0.0, fine = 0.0
        for _ in 0..<2 { coarse = limits.step(current: coarse, target: 0.5, dt: 0.5) }
        for _ in 0..<10 { fine = limits.step(current: fine, target: 0.5, dt: 0.1) }
        #expect(abs(coarse - fine) < 1e-12)
    }

    @Test func limitsTheFallRateSeparately() {
        #expect(limits.step(current: 0.6, target: 0, dt: 0.5) == 0.3)
    }

    @Test func neverOvershootsTheTarget() {
        // A rate far larger than the remaining distance still lands exactly.
        #expect(limits.step(current: 0.0, target: 0.05, dt: 10) == 0.05)
        #expect(limits.step(current: 0.5, target: 0.45, dt: 10) == 0.45)
    }

    @Test func pullsAnOutOfRangeCurrentBackInsideTheEnvelope() {
        // If the ceiling is lowered under a running level, the next step obeys the
        // new ceiling rather than treating the old level as legitimate.
        #expect(limits.step(current: 0.9, target: 0.9, dt: 1) == 0.6)
    }

    @Test func holdsStillWhenTheTargetIsAlreadyMet() {
        #expect(limits.step(current: 0.3, target: 0.3, dt: 1) == 0.3)
    }
}
