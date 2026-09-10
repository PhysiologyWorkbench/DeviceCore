import Testing
import Foundation
@testable import DeviceCore

/// `start()` documents an invariant nothing else checks: "a loop dropped without
/// `shutdown` must not leave its ticker sleeping forever". It holds because the
/// ticker captures `[weak self]` — the converse half of ARCHITECTURE.md
/// principle 9, where a *stored* task must capture weakly or the object can never
/// deallocate. A strong capture here would keep a loop, its actuator and its link
/// alive with the ticker still writing setpoints to a toy nobody is watching.
///
/// The technique is the point as much as the assertion: hold the object only
/// through a `weak var`, let every strong reference go out of scope, then wait for
/// the reference to read nil. Timing is polled rather than slept, so the test
/// cannot pass by luck or fail on a loaded machine.
@Suite struct ControlLoopLifetimeTests {
    @Test func aLoopDroppedWithoutShutdownDeallocates() async throws {
        weak var released: ControlLoop?
        do {
            let loop = ControlLoop(actuator: FakeActuator(), tick: .milliseconds(10))
            released = loop
            await loop.start()
            // Two ticks, so the assertion is about a loop that was genuinely
            // running rather than one whose task had not yet begun.
            try await Task.sleep(for: .milliseconds(25))
            #expect(released != nil, "released while still held; the test proves nothing")
        }
        // The ticker ends at its next wake, when `guard let self` fails.
        let deadline = ContinuousClock.now + .seconds(2)
        while released != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil, "the ticker outlived the loop that owns it")
    }
}
