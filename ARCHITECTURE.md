# Architecture — DeviceCore

The vendor-neutral device I/O layer under the Physiology Workbench apps: one
CoreBluetooth transport serving sensor input and actuator output, with the safety
envelope for closed-loop actuation built into the sender rather than wrapped
around it.

This document is the durable design of **this library** — its seams and why they
are where they are. The system-wide picture (the app streaming substrate, the
pipeline, recording, the two research programmes the whole thing serves) is in
the **PWB** repo's ARCHITECTURE.md; the principles below are restated there in
their system-wide form, and the overlap is deliberate: a library that ships
separately has to carry the reasoning for its own shape.

Companion documents here: `CLAUDE.md` (working notes), `LESSONS.md` (dated
lessons), `ROADMAP.md` (open work).

## Where this sits

```
┌───────────────────────────────────────────────┐
│ Apps  (SwiftUI, macOS + iOS)                  │
├───────────────────┬───────────────────────────┤
│ Vendor kits — one module per manufacturer:    │
│ wire protocol, device profile, catalogue      │
├───────────────────┴───────────────────────────┤
│ DeviceCore                                    │
│   Transport / EndpointResolver / DeviceSession│
│   ControlLoop + SafetyLimits / Actuator       │
│   standard-GATT readers                       │
├───────────────────────────────────────────────┤
│ CoreBluetooth                                 │
└───────────────────────────────────────────────┘
```

Arrows point down only. A kit depends on `DeviceCore`; `DeviceCore` depends on no
kit and names none. Adding a vendor adds a module — it touches transport,
session and UI not at all.

## Principles this library enforces

Four of the family's nine, the ones that are this library's own:

1. **Be resilient to unknown devices.** Identify endpoints by GATT properties
   where feasible, not only by hardcoded UUIDs; configuration enriches, it does
   not gate. And radio input never traps — every BLE-facing parser guards and
   skips.
2. **Add as little latency as possible over the radio.** The connection interval
   is the floor; software's job is to not add to it. Thin native path,
   write-without-response, one in-flight command, coalesce to the latest
   setpoint.
3. **Multi-vendor via narrow seams, and a vendor is a module.** The seams are
   `Transport`/`DeviceConnection` (bytes), `ScanFilter` + `EndpointResolver`
   (device shape), `DeviceSession` (correlation and demux) and `Actuator` (the
   one method the control loop drives a device through). A vendor's protocol
   logic is a **library above** them, never a conformance inside this one.

   *This is a correction, and worth stating as one.* There was a `Codec`
   protocol, designed as the vendor seam and plausible for a year. It had exactly
   one conformer for its whole life, and when a second vendor arrived it bypassed
   the seam entirely — that vendor's codecs are plain enums over a binary control
   point, with nothing in common with a `;`-terminated ASCII one but the word
   "codec". A vendor's wire protocol turns out to have no useful abstract shape.
   What it does have in common with another vendor's is the transport under it
   and the correlator beside it, which is exactly what this library keeps. **Look
   for the seam from the consuming side**: a seam derived from what the first
   implementation happens to do will be bypassed by the second.
4. **Safety is architecture, not garnish.** For closed-loop actuation on a human,
   the hard stop, fail-safe on connection loss, bounds and ramp limits are
   first-class components of the sender, designed with the control loop rather
   than wrapped around it.

## The transport layer

- **`Transport.swift` — the abstract vocabulary.** `Transport` (scan/connect),
  `DeviceConnection` (inbound stream, write with a `BusyPolicy` — to the resolved
  tx or to a named characteristic, for one-shot control writes like an init
  byte — GATT read, extra notify subscriptions), `ScanFilter`, and the
  `EndpointResolver` seam.

  The resolver is the input/output pivot: a notify-only sensor binds rx alone
  (`NotifyEndpointResolver`); a control-point device binds an explicit pair
  (`FixedEndpointResolver`); a serial device that needs a catalogue to find its
  writable tx binds both, and that resolver lives in the kit that owns the
  catalogue; a write-only device (Satisfyer — no notify characteristic anywhere)
  binds tx alone, and its resolver lives in its kit. **Resist further resolver
  shapes here until a real device demands one.**

  Readiness follows the binding: rx, when bound, is the readiness signal (notify
  confirmation), as it always was. With no rx, the connection is ready once every
  service's characteristics are discovered — later than strictly necessary, and
  deliberately so, because the first thing a nameless device's kit does is
  `read(characteristic:)` against Device Information, which must already be
  cached. `inbound` then never yields and finishes on disconnect.

  `ScanFilter` matches on any of: name prefix, advertised service UUID, or
  manufacturer company id. The company-id match is deliberately coarse —
  narrowing on the manufacturer payload (a model id, say) is the kit's job, off
  `Discovery.manufacturer`. It exists because some devices (Satisfyer) advertise
  no name and no service, only manufacturer data.
- **`BleTransport` / `BleConnection` — the one CoreBluetooth implementation**,
  device-neutral: it takes a `ScanFilter` and an `EndpointResolver`, never a
  catalogue. Identical on macOS and iOS.

  It hand-rolls four waiter sets (`responseWaiters`, `pendingWrites`,
  `readWaiters`, `subscribeWaiters`), and they look like callers for
  `DeviceSession`. They are not: those correlate CoreBluetooth *delegate
  callbacks* keyed by `CBUUID`, not messages in a byte stream matched by
  predicate. Leave them where they are.
- **A GATT read needs the characteristic cached, not just the resolver's match.**
  The resolver binds one service's endpoints; `read(characteristic:)` needs every
  discovered characteristic cached by UUID. Read waiters get their own
  FIFO-per-characteristic map, failed on disconnect the same way as the others —
  otherwise a lost reply is a silent hang.

## `DeviceSession` — the one correlator

Plural byte sources in; frames out to either a standing subscription or the
single outstanding request, which times out. **A standing subscription consumes
its frame before any request sees it**, so a sensor frame cannot answer a query.

Three callers today — a vendor session per kit and this library's own
`HeartRateReader` — and a fourth vendor adds a caller, not a copy. The reasoning
is worth keeping, because the duplication this replaced was invisible while it
lived in one module: two subsystems had grown the same mechanism independently
and, more to the point, they had **diverged** — one had a timeout and the other
could hang for ever on a device that accepts a subscription and then says
nothing. *Count divergences, not instances*: two copies that merely duplicate can
wait; two that disagree are a defect whose shape is already known.

Four axes the shared type has to keep open, each of which a real caller uses:

- **Source.** Some callers read `connection.inbound`, some subscribe to a named
  characteristic, some feed *both* into one session. The session takes streams as
  arguments and never reaches for a connection.
- **Framing.** Injectable, identity by default (one notification, one message).
  **Byte-level throughout** — a `String` in the framer would destroy exactly the
  binary replies that matter, and the default is also what stops an unterminated
  reply being welded to the next.
- **Where the separation comes from.** One vendor's replies and sensor frames
  share a characteristic, so the fan-aside is load-bearing; another gets the same
  separation from the wire. Assume neither.
- **Multiplicity.** One outstanding request, and a second *supersedes* the first.

Two properties fell out of unification that neither original had, and both are
load-bearing now: the last source finishing fails the outstanding request at once
with `notConnected` and finishes every subscription; and a superseded
subscription's teardown must not act against the stream that replaced it (a
generation counter, in the caller). **Merging two mechanisms is not only
subtraction — the merged one reaches states neither original could.**

## Output: `ControlLoop`, `SafetyLimits`, `Actuator`

- **`ControlLoop`** — the coalescing sender. `setTarget` only stores; a tick task
  writes the newest value, at most one write per tick. No queue, so no lag
  accumulation.

  **The safety envelope lives inside it, not around it**: every level it commands
  has been through `SafetyLimits`, the hard stop latches here and is not
  rate-limited, and the sensor watchdog fades from here — engaged for exactly the
  life of a session, since a merely-connected loop has no sensor to lose. There
  is no API that emits a level which has not been through all of it. A layer
  *above* the sender is a layer you can route around; inside, you cannot, and it
  costs nothing.
  **`pulse(level, for:)`** is the one deliberate exception to tick timing, added
  when the bench showed felt rhythm stands or falls on pulse-*length* constancy:
  both edges of a tick-rendered pulse quantise independently onto the tick and
  then the connection-event grid, and the length collects every error. A pulse
  schedules its rise, hold and fall against absolute deadlines on the actuator's
  `writeGranularity` grid instead — same envelope, same guarded write path, same
  stop authority (a stop or a superseding pulse cancels it; while it runs, the
  tick keeps only the watchdog). Durations chosen as whole multiples of the
  granularity land both edges the same distance into their delivery slots, so
  the grid cancels out of the felt length.
- **`SafetyLimits`** — ceiling, rise and fall rates, input timeout, one pure
  `step`. The whole envelope is testable without a radio.
- **`Actuator`** — one method: set one vibrator to a level in 0…1 and say whether
  the bytes reached the link, plus one number: `writeGranularity`, the grid the
  device's command deliveries quantise to. A vendor kit conforms its session to
  it; this library never learns a wire protocol.

Three rules the tests exist to hold:

- **The loop's unit of work is a function, not a tick.** `tick(dt:)` is internal
  and the timer task is its only other caller, so every test asserts behaviour —
  ramp, latch, retry, watchdog — with no sleeping, no flakiness, no injected
  clock. The watchdog accumulates `dt` and never reads a clock at all.
- **Don't advance the model of the device on a write that did not land.** With
  `.drop`, ramp state moves only on success, or the next successful write jumps
  by everything dropped in between — the difference between a ramp limit and a
  suggestion.
- **One termination path.** Operator stop, distress, sensor loss and link loss all
  surface as a `StopReason` on the status stream, so a caller handles every one
  identically and idempotency comes free.

### Back-pressure, settled with the loop

Setpoints are written `.drop`: the next tick supersedes them, so queueing would
only accumulate stale commands, and a dropped write leaves the level where it was
for the next tick to re-offer. Zeros — the tail of a fade, and the hard stop —
are written `.wait`, because a dropped stop is not acceptable in the way a
dropped setpoint is. Coalescing lives in `ControlLoop`, not in the transport;
`DeviceConnection.write(_:ifBusy:)` keeps only the policy flag.

### Where stop authority ends

Every stop is a zero through the one `Actuator` method, so **the stop authority
of everything above reaches exactly as far as that method does**. A device whose
firmware drives its own motor from its own sensor is outside it: it answers `OK`
to a stop and carries on, and it outlives the central. At least one such mode
exists on real hardware and persists across a disconnect.

Two things follow, and both are architecture rather than documentation:

- **An acknowledgement is not an effect.** A reply confirms receipt, never state.
- **The useful question is not "does our stop work" but "is there a state in
  which nothing we can send matters".** Where such a state exists, the mitigation
  is operational (power-cycle before a session), and the *vendor kit* owns
  naming it. This library owns admitting that it loses.

## Input

Light actors over a connection. `HeartRateReader` (standard BLE HR profile — any
strap, so it stays here) is the only one; a vendor's high-rate stream is a kit's.
Multiple logical streams can share one connection via extra notify subscriptions,
and when two ride one characteristic the session demuxes them by parse.

The rule the split settled, and the one that decides the next such case without
another discussion: **standard GATT profiles belong to `DeviceCore`, vendor
profiles to a kit.**

## Latency

- The floor is the BLE **connection interval**, measured rather than estimated:
  **30 ms** on every actuator tested, with macOS as central, read off `LE
  Enhanced Connection Complete` with no later `Connection Update` in the capture.
  macOS asks for 10–30 ms and gets the top of its range, so this is a line-wide
  floor, not a per-model quirk. An **acknowledged** write costs two intervals,
  ~60 ms, confirmed in the ATT trace.
- Nothing in software beats any of that, so the budget is spent not adding to it:
  no runtime, no IPC hop, write-without-response where offered, reads off the hot
  path. Sustained unacknowledged write rates of 81–331 Hz have been measured
  against real devices, against ~16.5 Hz acknowledged — a factor of four to
  sixteen in hand over the 50 ms control tick.
- The wire evidence lives with the devices it was taken from, in the **LovenseKit**
  repo (`captures/`).

## Robustness

- **Radio input never traps** — every BLE-facing parser guards lengths and skips
  malformed frames.
- **Reference implementations are guides, not ground truth** — decode paths are
  validated against real hardware bytes before being trusted, and a decode path
  no owned device exercises is not carried.

## Concurrency

- **One serial context per non-thread-safe resource.** CoreBluetooth lives on a
  dedicated queue, bridged to `async`/`await` per request and to `AsyncStream`
  for ongoing notifications. Sessions and readers are actors.
- **Streams are single-consumer** — demux at the owner, never per caller.
- **Whoever owns the tasks should own all of them.** A callback handed back
  synchronously pushes a `Task` into every caller; `DeviceSession`'s termination
  hook is `async` and runs on the session's own task for exactly that reason.
- **Non-Sendable BLE types cross actors only as fresh values — or `sending`.**
- **Dropping is a legitimate end, and the `deinit` sits on the smallest owner.**
  A `Task` handle does not cancel on drop and an `AsyncStream` continuation
  does not finish on drop — its consumer suspends for ever — so whatever
  *stores* one releases it in its own `deinit` (ruled 2026-09-10; the family
  form is PWB ARCHITECTURE.md principle 9). On an actor that owner is not the
  actor: its `deinit` is nonisolated and may not touch non-Sendable state.
  `DeviceSession` therefore keeps each standing subscription in a class that
  finishes its stream as it dies, and cancels its pumps — `Task` is Sendable —
  from the actor's own `deinit`. `stop()` stays the explicit end; a session
  dropped without it ends the same way, silently, as `ControlLoop` already does.
  `BleConnection` finishes its `inbound`, `state` and `subscribe` streams the
  same way, for the one path that reaches it unfinished: the transport dropped
  with the link up.

## Open questions

- Whether an **iOS** central negotiates shorter than macOS's 30 ms. The macOS
  side is settled; this is what is left of that question.
- Whether to keep the **write-with-response fallback** in `BleConnection`. A
  trade-off with numbers rather than taste: ~16 Hz acknowledged against 81–331 Hz
  unacknowledged, so it must never be the default — but real devices advertise
  `Write` alongside `Write Without Response`, and at least one vendor's own app
  takes the acknowledged path, so it is resilience rather than dead code.
- **Stop authority as a whole** — how far a library that cannot reach a
  self-driving firmware mode should go in *claiming* a check it has not made. See
  ROADMAP.md.
- Reconnection / background behaviour on iPadOS (state restoration) — deferred.
