import Testing
import Foundation
@testable import DeviceCore

/// The pulse path schedules real deadlines, so unlike `ControlLoopTests` these
/// touch the wall clock — level sequences are asserted exactly (the ramp
/// arithmetic is deterministic), while timing is asserted only within generous
/// bounds. Limits are chosen so every ramp value lands on a clean 0…20 step.
@Suite struct ControlLoopPulseTests {
    /// Ceiling 0.6, rise 10/s and fall 4/s over a 50 ms grid: the rise is
    /// 0.5, 0.6 and the fall 0.4, 0.2, 0.
    private func loop(granularity: Duration = .milliseconds(50))
        -> (ControlLoop, FakeActuator) {
        let actuator = FakeActuator()
        actuator.writeGranularity = granularity
        let limits = SafetyLimits(ceiling: 0.6, riseRatePerSecond: 10,
                                  fallRatePerSecond: 4, inputTimeout: .seconds(5))
        return (ControlLoop(actuator: actuator, limits: limits), actuator)
    }

    /// Runs until the pulse's terminal zero has been published.
    private func awaitSilence(_ loop: ControlLoop) async {
        for await status in await loop.status where status.level == 0 { break }
    }

    @Test func rampsBothEdgesThroughTheLimitsAndEndsInSilence() async throws {
        let (loop, actuator) = loop()
        await loop.pulse(0.6, for: .milliseconds(200))
        await awaitSilence(loop)
        #expect(actuator.steps == [10, 12, 8, 4, 0])
        // The terminal zero is a stop-class write; everything else is a setpoint.
        #expect(actuator.setpoints.map(\.isDrop) == [true, true, true, true, false])
        #expect(await loop.appliedLevel == 0)
        #expect(await loop.stopReason == nil)
    }

    @Test func clampsThePlateauToTheCeiling() async throws {
        let (loop, actuator) = loop()
        await loop.pulse(1.0, for: .milliseconds(200))
        await awaitSilence(loop)
        #expect(actuator.steps.max() == 12)
    }

    @Test func offEdgeFallsOnItsDeadlineNotTheTick() async throws {
        let (loop, actuator) = loop()
        await loop.pulse(0.6, for: .milliseconds(200))
        await awaitSilence(loop)
        // First fall write against first rise write: nominally the 200 ms the
        // caller asked for, bounded loosely for a loaded machine.
        let edges = actuator.setpoints
        let length = edges[2].at - edges[0].at
        #expect(length > .milliseconds(150) && length < .milliseconds(350))
    }

    @Test func aRunningPulseOwnsTheOutputOverTheTick() async throws {
        let (loop, actuator) = loop()
        await loop.pulse(0.6, for: .seconds(2))
        for _ in 0..<100 where actuator.steps.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(actuator.steps == [10, 12])

        // A target set mid-pulse must not reach the device through the tick.
        await loop.setTarget(0.6)
        await loop.tick(dt: 1)
        #expect(actuator.steps == [10, 12])

        // The hard stop takes the output back: one zero, then nothing more.
        await loop.hardStop()
        #expect(actuator.steps == [10, 12, 0])
        try await Task.sleep(for: .milliseconds(150))
        #expect(actuator.steps == [10, 12, 0])
        #expect(await loop.appliedLevel == 0)
    }

    @Test func watchdogFadeCancelsAPulse() async throws {
        let (loop, actuator) = loop()
        await loop.expectInput(true)
        await loop.pulse(0.6, for: .seconds(2))
        for _ in 0..<100 where actuator.steps.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        // One starved tick: the watchdog fades down, which takes the output
        // back from the pulse; the same tick then writes the fade's level.
        await loop.tick(dt: 10)
        #expect(await loop.stopReason == .sensorLost)
        #expect(actuator.steps == [10, 12, 0])
    }

    @Test func aNewPulseSupersedesARunningOne() async throws {
        let (loop, actuator) = loop(granularity: .milliseconds(10))
        // On a 10 ms grid these limits plateau in one write and fall in one
        // step per level, so the whole sequence is exact: 0.6, then the second
        // pulse's descent to its own plateau, then silence.
        await loop.setLimits(SafetyLimits(ceiling: 0.6, riseRatePerSecond: 60,
                                          fallRatePerSecond: 60, inputTimeout: .seconds(5)))
        await loop.pulse(0.6, for: .seconds(2))
        for _ in 0..<100 where actuator.steps.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await loop.pulse(0.3, for: .milliseconds(50))
        await awaitSilence(loop)
        #expect(actuator.steps == [12, 6, 0])
        // The first pulse's 2 s deadline no longer governs anything.
        let times = actuator.setpoints
        #expect(times[2].at - times[0].at < .milliseconds(600))
    }

    @Test func aStoppedLoopIgnoresAPulse() async throws {
        let (loop, actuator) = loop()
        await loop.fadeDown(.distress)
        await loop.pulse(0.6, for: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(100))
        #expect(actuator.steps.isEmpty)
    }
}
