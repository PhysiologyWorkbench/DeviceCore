# Architecture — DeviceCore

The vendor-neutral device I/O layer under the Physiology Workbench apps: one
CoreBluetooth transport serving sensor input and actuator output, with the safety
envelope for closed-loop actuation built into the sender rather than wrapped
around it.
Where it sits among the family's repositories is in the README;
this document is the durable design of **this library** —
its seams and why they are where they are.

The system-wide picture (the app streaming substrate, the pipeline, recording,
the research programmes the whole thing serves) is currently in the family's **PWB**
repository, which is not yet public.
More features land here as they mature.

The principles below are restated there in their system-wide form.
There is some deliberate overlap, as a separate library
has to carry the reasoning independently.

Companion documents here: `CLAUDE.md` (working notes), `LESSONS.md` (dated
lessons — the stories behind the rules below), `ROADMAP.md` (broad directions).
The types named below are the main ones; the code is the reference for the rest.

## Where this sits

```
┌───────────────────────────────────────────────┐
│ Apps  (SwiftUI, macOS + iOS)                  │
├───────────────────────────────────────────────┤
│ Vendor kits — one module per manufacturer:    │
│ wire protocol, device profile, catalogue      │
├───────────────────────────────────────────────┤
│ DeviceCore                     │ BenchKit     │
│   Transport / EndpointResolver │  bench tool  │
│   DeviceSession                │  seam, run   │
│   ControlLoop + SafetyLimits   │  records,    │
│   Actuator                     │  wire tools  │
│   standard GATT, device data   │              │
├────────────────────────────────┴──────────────┤
│ CoreBluetooth                                 │
└───────────────────────────────────────────────┘
```

Arrows point down only. A kit depends on `DeviceCore`; `DeviceCore` depends on
no kit and names none, so adding a vendor adds a module and touches nothing
here. `BenchKit` depends on `DeviceCore`; only the kits' bench executables
depend on `BenchKit`.

## Principles this library enforces

The family keeps nine principles in its system-wide record; these four are the
ones this library owns.

1. **Be resilient to unknown devices.** Identify endpoints by GATT properties
   where feasible, not only by hardcoded UUIDs; configuration enriches, it does
   not gate. Radio input never traps.
2. **Add as little latency as possible over the radio.** The connection
   interval is the floor; software's job is to not add to it.
3. **Multi-vendor via narrow seams, and a vendor is a module.** A vendor's
   protocol logic is a library *above* the seams, never a conformance inside
   this one. This is a correction: a `Codec` protocol designed as the vendor
   seam was plausible for some weeks, had one conformer for its whole life,
   and the second vendor bypassed it. **Look for the seam from the consuming
   side** — a seam derived from what the first implementation happens to do
   will be bypassed by the second (LESSONS 2026-08-02).
4. **Safety is architecture, not garnish.** For closed-loop actuation on a
   human, the hard stop, fail-safe on connection loss, bounds and ramp limits
   are components of the sender, designed with the control loop rather than
   wrapped around it.

## The four seams

**`Transport` / `DeviceConnection` — bytes.** Scan, connect, an inbound byte
stream, a write with a busy policy, GATT reads and extra notify subscriptions.
One CoreBluetooth implementation, identical on macOS and iOS; it takes a scan
filter and an endpoint resolver, never a catalogue.

**`ScanFilter` + `EndpointResolver` — device shape.** A scan matches on name
prefix, advertised service or manufacturer id, coarsely; narrowing on a
payload is a kit's job. The resolver is the input/output pivot: it binds rx
alone for a notify-only sensor, a tx/rx pair for a control point, or tx alone
for a write-only device, and readiness follows the binding. A kit whose
devices need more brings its own resolver — that is the seam working. New
resolver shapes are added here only when a real device demands one.

**`DeviceSession` — the one correlator.** Plural byte sources in; frames out
to either a standing subscription or the single outstanding request, which
times out. A standing subscription consumes its frame before any request sees
it, so a sensor frame cannot answer a query. Framing is injectable and
byte-level — a `String` anywhere in it would destroy exactly the binary
replies that matter — and matching and parsing are one act, so a frame is
parsed once. The session owns no connection; when its last source finishes,
the request fails and every subscription ends.

Three callers today: a vendor session per kit and this library's own
`HeartRateReader`, the degenerate caller with one source and no request ever.
**A fourth vendor adds a caller, not a copy.** The duplication this replaced
had *diverged* — one copy could hang for ever on a device that accepts a
subscription and then says nothing (LESSONS 2026-08-02).

**`Actuator` — one method.** Set one vibrator to a level in 0…1 and say
whether the bytes reached the link, plus the grid the device's deliveries
quantise to. A vendor kit conforms its session; this library never learns a
wire protocol.

## The sender and the envelope

`ControlLoop` is the coalescing sender: a setpoint only stores, and a tick
writes the newest value, at most one write per tick — no queue, no lag
accumulation. **The safety envelope lives inside it, not around it**: every
level it commands has been through `SafetyLimits` (ceiling, rise and fall
rates, input timeout; one pure function, testable without a radio), the hard
stop latches here and is not rate-limited, and the sensor watchdog fades from
here. There is no API that emits a level which has not been through all of
it. A layer *above* the sender can be routed around; inside, it cannot.

Two consequences shape it. Setpoints are written drop-on-busy, since the next
tick supersedes them; zeros are written wait, since a dropped stop is not
acceptable the way a dropped setpoint is. And the model of the device advances
only on a write that landed — otherwise the ramp limit becomes a suggestion.
Every end — operator stop, distress, sensor loss, link loss — surfaces as one
stop reason on one stream, so a caller handles them all identically.

### Where stop authority ends

Every stop is a zero through the one `Actuator` method, so **the stop
authority of everything above reaches exactly as far as that method does**. A
device whose firmware drives its own motor from its own sensor is outside it:
it answers `OK` to a stop and carries on, and it outlives the central. At
least one such mode exists on real hardware and persists across a disconnect.

Two things follow, and both are architecture rather than documentation:

- **An acknowledgement is not an effect.** A reply confirms receipt, never
  state.
- **The useful question is not "does our stop work" but "is there a state in
  which nothing we can send matters".** Where such a state exists, the
  mitigation is operational (power-cycle before a session), and the *vendor
  kit* owns naming it. This library owns admitting that it loses.

## Standard profiles and device data

**Standard GATT profiles belong to `DeviceCore`, vendor profiles to a kit.**
That is the rule that decides the next case without another discussion: heart
rate, battery level and device information live here; a vendor's high-rate
stream does not.

The same rule for data: **vocabulary here, records in the kits.** The device
model is split into type and instance. `DeviceType` says what a *model* is and
can do — a fingerprint over the advertisement and capabilities in a controlled
vocabulary — as compiled-in records a kit supplies and an app concatenates.
`PhysicalUnit` is one *unit* as a registry names it: an opaque id, the claims
the device asserted, host-relative bindings. The wire supplies evidence, never
the key; that is why device information is a service here and not in a kit.

## `BenchKit` — the frame around a measurement

Bench tools measure a real device over a real radio and return a verdict. What
they share, and what this library is, is the provenance frame: a tool seam a
kit fills, a runner that owns everything around a run — arguments, run UUID,
commit table, host, timestamps, captures — and a typed run record, one
directory per run, git-diffable JSON with a schema version from day one. A tool
verdicts on the *device*; a throw means the *run* broke, and the record says
which. BenchKit's own `wire` tools scan, survey and subscribe in wire terms
only, with no vendor knowledge.

## Latency

The floor is the BLE connection interval, measured rather than estimated: 30 ms
on every actuator tested with macOS as central, and an acknowledged write
costs two of them. The budget is spent not adding to it: no runtime, no IPC
hop, write-without-response where offered, one command in flight, reads off
the hot path. Unacknowledged write rates of 81–331 Hz have been measured
against ~16.5 Hz acknowledged, against a 50 ms control tick.

## Concurrency and robustness

- **One serial context per non-thread-safe resource.** CoreBluetooth lives on
  a dedicated queue, bridged to `async`/`await` per request and to
  `AsyncStream` for notifications. Everything above is an actor; no locks.
- **Streams are single-consumer** — demux at the owner, never per caller.
- **Dropping is a legitimate end.** A task handle does not cancel on drop and
  a stream continuation does not finish on drop, so whatever stores one
  releases it in its own `deinit`. Stopping stays the explicit end; a session
  dropped without it ends the same way, silently.
- **Reference implementations are guides, not ground truth** — decode paths
  are validated against real hardware bytes, and a path no owned device
  exercises is not carried.
- **Test doubles model the round trip.** A fake that replies inside `write`,
  or serves an immediately-finished subscribe stream, converts a hang into a
  pass.

## Open questions

Stop authority as a whole — how far a library that cannot reach a
self-driving firmware mode should go in *claiming* a check it has not made;
whether the write-with-response fallback in the transport stays, no device
having yet required it; whether an iOS central negotiates shorter than macOS's
30 ms, and how it reconnects and behaves in the background. ROADMAP.md gives
the directions these sit in.
