import Testing
import Foundation
@testable import DeviceCore

/// The loop is driven by `tick(dt:)` directly rather than by its own task, so
/// every assertion is about the logic and none about wall-clock timing.
@Suite struct ControlLoopTests {
    let catalog = try! DeviceCatalog()

    private func loop(_ limits: SafetyLimits = SafetyLimits(ceiling: 0.6,
                                                            riseRatePerSecond: 0.2,
                                                            fallRatePerSecond: 0.6,
                                                            inputTimeout: .seconds(5)))
        async throws -> (ControlLoop, FakeConnection) {
        let connection = FakeConnection()
        let session = DeviceSession(connection: connection, catalog: catalog)
        try await session.identify()
        return (ControlLoop(session: session, limits: limits), connection)
    }

    /// The Edge's vibrate range is 0…20, so a level maps to a known wire command.
    private func vibrate(_ step: Int) -> String { "Vibrate1:\(step);" }

    private func setpoints(_ connection: FakeConnection) -> [String] {
        connection.commands.filter { $0.hasPrefix("Vibrate") }
    }

    @Test func coalescesToTheLatestTarget() async throws {
        let (loop, connection) = try await loop()
        await loop.tick(dt: 1)                        // asserts the initial zero
        for value in [0.1, 0.15, 0.2] { await loop.setTarget(value) }
        await loop.tick(dt: 1)
        // Three targets between ticks, one write, carrying the last of them.
        #expect(setpoints(connection) == [vibrate(0), vibrate(4)])
    }

    @Test func limitsTheRiseAcrossTicks() async throws {
        let (loop, connection) = try await loop()
        await loop.setTarget(0.6)
        for _ in 0..<4 { await loop.tick(dt: 0.5) }
        // 0.2/s over four half-seconds: 0.1, 0.2, 0.3, 0.4 → steps 2, 4, 6, 8.
        #expect(setpoints(connection) == [vibrate(2), vibrate(4), vibrate(6), vibrate(8)])
    }

    @Test func usesDropForSetpointsAndWaitForZero() async throws {
        let (loop, connection) = try await loop()
        await loop.setTarget(0.4)
        await loop.tick(dt: 1)
        await loop.hardStop()
        let writes = connection.writes.filter { $0.text.hasPrefix("Vibrate") }
        #expect(writes.map(\.isDrop) == [true, false])
    }

    @Test func retriesADroppedWriteRatherThanAssumingItLanded() async throws {
        let (loop, connection) = try await loop()
        await loop.setTarget(0.6)
        connection.setBusy(true)
        await loop.tick(dt: 1)
        #expect(setpoints(connection).isEmpty)
        // The level did not advance while the link was refusing, so the ramp
        // resumes from where it actually is, not from where it would have been.
        connection.setBusy(false)
        await loop.tick(dt: 1)
        #expect(setpoints(connection) == [vibrate(4)])
    }

    @Test func hardStopCutsOutputAndLatches() async throws {
        let (loop, connection) = try await loop()
        await loop.setTarget(0.6)
        await loop.tick(dt: 1)
        await loop.hardStop()
        #expect(setpoints(connection) == [vibrate(4), vibrate(0)])

        // Latched: a target arriving afterwards is ignored, and ticking commands
        // nothing further.
        await loop.setTarget(0.6)
        for _ in 0..<3 { await loop.tick(dt: 1) }
        #expect(setpoints(connection) == [vibrate(4), vibrate(0)])

        // Released, the loop accepts targets again.
        await loop.release()
        await loop.setTarget(0.6)
        await loop.tick(dt: 1)
        #expect(setpoints(connection) == [vibrate(4), vibrate(0), vibrate(4)])
    }

    @Test func hardStopIsNotRateLimited() async throws {
        let (loop, _) = try await loop(SafetyLimits(ceiling: 1, riseRatePerSecond: 1,
                                                    fallRatePerSecond: 0.01))
        await loop.setTarget(1)
        await loop.tick(dt: 1)
        await loop.hardStop()
        // A fall rate that would take 100 s to descend does not delay a stop.
        #expect(await loop.appliedLevel == 0)
    }

    @Test func aTickInFlightWhenAHardStopLandsCannotRestoreItsLevel() async throws {
        let (loop, connection) = try await loop()
        await loop.setTarget(0.6)

        // Suspend the tick's write in flight, the way a radio would.
        connection.holdNextWrite()
        let tick = Task { await loop.tick(dt: 1) }
        await connection.waitForHeldWrite()

        // The stop lands at that suspension point: its zero reaches the device
        // and its bookkeeping completes before the tick resumes.
        await loop.hardStop()
        connection.releaseHeldWrite()
        await tick.value

        // The resumed tick must not commit the level its write carried — the
        // next ticks would fade down from it, re-energising a stopped toy.
        #expect(await loop.appliedLevel == 0)
        let writes = setpoints(connection).count
        for _ in 0..<3 { await loop.tick(dt: 1) }
        #expect(setpoints(connection).count == writes)
    }

    @Test func fadesDownWhenTheSensorGoesQuiet() async throws {
        let (loop, connection) = try await loop()
        await loop.expectInput(true)
        await loop.setTarget(0.6)
        for _ in 0..<3 { await loop.heartbeat(); await loop.tick(dt: 1) }
        #expect(setpoints(connection) == [vibrate(4), vibrate(8), vibrate(12)])

        // Five seconds without a heartbeat trips the watchdog. The fade then
        // descends at the fall rate — 0.6/s, so two half-second ticks — rather
        // than cutting the way a hard stop does.
        for _ in 0..<10 { await loop.tick(dt: 0.5) }
        #expect(await loop.stopReason == .sensorLost)
        #expect(setpoints(connection) == [vibrate(4), vibrate(8), vibrate(12),
                                          vibrate(6), vibrate(0)])
    }

    @Test func watchdogIsIdleUntilInputIsExpected() async throws {
        let (loop, connection) = try await loop()
        // A connected-but-idle loop gets no heartbeats — there is no sensor
        // feeding it yet — and must not be faulted for that: a held Test press
        // keeps running well past the input timeout.
        await loop.setTarget(0.3)
        for _ in 0..<8 { await loop.tick(dt: 1) }
        #expect(await loop.stopReason == nil)
        #expect(setpoints(connection).last == vibrate(6))

        // Once a session engages it, the same silence trips it.
        await loop.expectInput(true)
        for _ in 0..<8 { await loop.tick(dt: 1) }
        #expect(await loop.stopReason == .sensorLost)

        // And release disengages it along with clearing the stop, so the next
        // idle stretch starts clean.
        await loop.release()
        for _ in 0..<8 { await loop.tick(dt: 1) }
        #expect(await loop.stopReason == nil)
    }

    @Test func stopsWhenTheLinkFails() async throws {
        let (loop, connection) = try await loop()
        await loop.setTarget(0.6)
        await loop.tick(dt: 1)
        await connection.disconnect()
        await loop.tick(dt: 1)
        #expect(await loop.stopReason == .actuatorLost)
    }

    @Test func publishesEveryChangeOnStatus() async throws {
        let (loop, _) = try await loop()
        let stream = await loop.status
        let statuses = Task {
            var seen: [ControlStatus] = []
            for await status in stream {
                seen.append(status)
                if status.stopped != nil { break }
            }
            return seen
        }
        await loop.setTarget(0.4)
        await loop.tick(dt: 1)
        await loop.hardStop(.distress)
        #expect(await statuses.value == [ControlStatus(level: 0.2, stopped: nil),
                                         ControlStatus(level: 0, stopped: .distress)])
    }
}
