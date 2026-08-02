# Roadmap — DeviceCore

Open work owned by this library. ARCHITECTURE.md's "Open questions" lists these
in one line each; this file is where the work itself is described. What the
library already does, and why, is in ARCHITECTURE.md and CLAUDE.md.

The first entry this file would have had is already closed: the two
request/response mechanisms that had drifted apart were merged into one
`DeviceSession` before the split, and every vendor session and
`HeartRateReader` is now a caller of it.

## Stop authority as a whole

`ControlLoop`'s reach ends at `Actuator.setVibration`, and a device whose
firmware drives its own motor from its own sensor does not answer it — it
acknowledges the command and keeps running, and it survives the central ceasing
to exist. One such mode is known and documented in LovenseKit, along with a
session call that reads it back and clears it. **Nothing calls that, deliberately.**

The reason is that one known mode is one case out of an unknown number. At least
one vendor's own application offers a setting that keeps a device running when
Bluetooth drops, which has nothing to do with the mode we can read, and which
command sets it — if any is reachable from a central at all — is unknown. Wiring
in a partial guard would be worse than none: it would let an application claim
it had checked, on a check covering one case out of a state space nobody has
mapped.

The work, in order: find the actual state space — which settings survive a
disconnect, which are readable, which are settable by us at all — and only then
decide what this library asserts on connect, and what it is entitled to promise
its callers. It is a per-vendor investigation whose *conclusion* belongs here,
because the guarantee it revises is this library's.

Until then the honest position stands: a device left configured by another
application may not be stoppable by this one, and the mitigation is operational
— power-cycle a device before a session — not architectural.

## The write-with-response fallback in `BleConnection`

Whether to keep it. The numbers are in and it is no longer a matter of taste:
the acknowledged path sustains ~16 Hz against 81 Hz and 331 Hz unacknowledged on
the two devices measured, so it must never be the control path. But real devices
advertise `Write` alongside `Write Without Response`, and at least one vendor's
own application takes the acknowledged path, so the fallback is resilience
rather than dead code.

Deciding it needs a device that *requires* the acknowledged path — none
encountered so far — or a decision to drop the resilience on the grounds that
none ever will.

## Deferred

- Whether an **iOS central** negotiates a shorter connection interval than the
  30 ms macOS settles on with every device measured so far. Answered by the
  first iOS build, not before.
- **Reconnection and background behaviour** (CoreBluetooth state restoration) on
  iOS/iPadOS.
