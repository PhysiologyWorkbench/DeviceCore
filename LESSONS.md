# Lessons learned — DeviceCore

Running log of high-level lessons from building this library. Newest first. Each
entry is dated and kept terse — "what I wish I'd known starting", not a step log.

Entries here are this repo's slice of a log that was kept for the whole
Physiology Workbench family before it split into separate repositories, so a
dated heading may appear in a sibling repo too, carrying that repo's bullets.
Where a lesson was learned against a particular device, the claim is kept and
the vendor detail dropped — it lives in the kit that owns the device.

## 2026-09-10 — The `deinit` goes on the smallest owner, not the actor

`DeviceSession` stored continuations and pump tasks with no `deinit`, so a
session dropped without `stop()` left every subscriber suspended for ever — the
hang `HeartRateReader.readings()` and `LovenseSession.depth()` inherited, and
that the family's stream rule cannot see because neither drives a task. The
obvious fix, an actor `deinit` finishing `standing`, does not compile: the deinit
is nonisolated and the entries were not Sendable. Making the entry a class with
its own `deinit` dissolved the constraint instead of paying it — the array dies
with the actor and each entry finishes its stream. Where an actor holds a
handle whose drop is silent, give the handle an owner small enough to have a
plain `deinit`.

## 2026-08-02 — A seam with one conformer, and where a safety constraint has to be written

The vendor kits were carved out into their own modules; this library came out of
it naming no manufacturer at all. The three things worth keeping.

- **A protocol with one conformer is a naming convention, not a seam.** `Codec`
  was designed as *the* vendor seam and looked right for a year. Then a second
  vendor arrived and bypassed it entirely — its codecs are enums over a binary
  control point, sharing nothing with a `;`-terminated ASCII one but the word
  "codec". The real seam is the one the *core* needs, not the one a vendor offers,
  and it turned out to be a single method: set a vibrator to a level, say whether
  the bytes landed. **Look for the seam from the consuming side.** A seam derived
  from what the first implementation happens to do will be bypassed by the second.
- **A safety constraint has to be stated where the authority is, not where the
  danger is.** The firmware mode in which a device drives its own motor and
  ignores a zero is a vendor fact, and it moved to the kit that owns the type
  which cannot express it. But the thing that *loses* against it is `ControlLoop`,
  which stayed. So `Actuator`'s doc comment says the quiet part in this library's
  own words: the stop authority of everything above reaches exactly as far as
  this one method does. Splitting a module splits its documentation too, and a
  warning attached only to the vendor half becomes invisible to the half that
  needs it.
- **Making a test unable to reach the real thing made it a better test.**
  `ControlLoopTests` had been building a real vendor session over a real
  catalogue to exercise the safety envelope, so every assertion read as a wire
  string. Against a fake `Actuator` it asserts on levels, and the catalogued
  scaling it used to drag along is tested once, where it lives. (One trap on the
  way: raw `Double` levels are not comparable — `0.4 + 0.2 != 0.6` — so the fake
  records the discrete step, which is what the assertions meant all along.)

## 2026-08-02 (later still) — Unifying the two mechanisms, and what only appeared once they were one

One `DeviceSession` in `Data`, with both vendor sessions and `HeartRateReader` on
it. The entry below is the analysis that booked the work; this is what the work
itself taught.

- **Fix the test double before the code, not alongside it.** The acceptance test —
  a device that accepts the subscription and then says nothing — could not be
  written at all until `FakeConnection.subscribe` served live channels instead of
  an immediately-finished stream. Doing that as its own first commit meant the
  refactor was afterwards provable rather than argued. A fake that degenerates on
  the path under test converts a hang into a pass, which is the worst direction
  for a test double to be wrong in.
- **A callback the mechanism hands back synchronously pushes a `Task` into every
  caller.** `subscribe`'s termination hook started as `@Sendable () -> Void`, and
  the one caller needing it immediately wrapped `Task { await self.… }` to get
  back into its actor — reintroducing, in the caller, exactly the thing the step
  was removing. Making the hook `async` and running it on the session's own task
  moved that where it belongs. **Whoever owns the tasks should own all of them.**
- **Matching and parsing are one act.** `select: (Data) -> T?` rather than a
  `Bool` predicate means a frame is parsed once, and the caller's demux rule *is*
  its parse: one kit's two high-rate measurements separate purely because each
  parse rejects the other's type byte, with no routing table anywhere.
- **Unification introduces its own races.** Giving a vendor's sensor stream the
  shared type's supersede rule, rather than its old one, created a case neither
  copy had: a superseded stream terminates, and its teardown would have sent a
  stream-off command against the stream that replaced it. A generation counter
  fixes it. Merging two mechanisms is not only subtraction — the merged one has
  states neither original could reach.
- **The boundary catches the tests too.** Nothing in this library's sources
  reached into a vendor, but one of its *tests* did: `HeartRateReaderTests` had
  borrowed a vendor type's constant as a convenient name for `0x2A37`. Harmless in
  one module, a dependency in two — and test targets are where this kind of
  borrowing accumulates unremarked, because a test naming a real device reads as
  realism rather than as coupling. Compiling the boundary is the only thing that
  finds it.

## 2026-08-02 (later) — Two subsystems grew the same mechanism; only a module boundary showed it

Planning the repo split meant deciding where `DeviceSession` goes, which meant
asking what in it is actually vendor-neutral. The answer was a ~43-line private
reply correlator — and the high-rate sensor reader turned out to have grown its
own, independently, for the same job.

- **A single module hides duplication that a module boundary makes obvious.**
  Both mechanisms sat here for weeks. Nothing was wrong with either, no test
  failed, and no review would have flagged them: they are in different files,
  named differently, and each reads as the natural thing to write. It took drawing
  a line between them — which repo does this belong to? — to notice they answer
  the same question. **Splitting a package is a duplication detector**, and that is
  worth something even before the split happens.
- **There are two shared shapes, not one.** *Correlation*: write, then await the
  first inbound message matching a predicate. *Demux*: route one inbound stream to
  several consumers, so that a sensor frame cannot satisfy a query. Both
  subsystems had both.
- **The divergence is already behavioural, not cosmetic.** One had a timeout; the
  other had none anywhere — it threw only if the control stream *finished*, so a
  device that accepts a subscription and never answers left the call awaiting for
  ever. That asymmetry is invisible while the two live apart, and it is exactly the
  class of thing one shared mechanism fixes for free. Note also that one vendor
  needs the sensor-frame fan-aside because replies and frames share one
  characteristic, while another gets that separation from the wire — a unified
  correlator must not assume the clean case.
- **"Wait for the third caller" is a rule about tidiness, and this was not
  tidiness.** The first conclusion here was the orthodox one: two instances is
  where a pattern becomes *visible*, not where it becomes *known*. The owner
  overruled it within the hour, and was right to — the deciding fact is in the
  bullet above. Two copies that merely duplicate can wait; two copies that
  *disagree*, one of them able to hang, are a defect whose shape is already known.
  The rule of thumb that survives: **count divergences, not instances.**
- **Having decided to unify, go looking for the degenerate caller.**
  `HeartRateReader` became worth including — not because it duplicates anything
  (it has neither shape: no write, no reply, one characteristic, one consumer) but
  because a mechanism drawn from two rich callers fits those two. A third caller
  that uses almost none of it is the cheapest test of whether the abstraction is a
  shape or a coincidence. It also turned out to duplicate *itself* — two `readings`
  bodies differing only in where the stream comes from, which is one of the axes
  the shared type needs anyway.
- **A boundary about to be drawn is the last cheap moment to fix what it will
  hide.** Unifying these was a refactor then and a cross-repo negotiation after
  the split, so the same work would have got an order of magnitude more expensive
  on a date already in the calendar.
- **Nothing tested either reader.** Neither had a single test, in a suite of 83
  green ones — all of them codec-level or `DeviceSession`-level. And
  `FakeConnection.subscribe` returned an immediately-finished stream, which is
  precisely the state that makes the missing timeout throw instead of hang: the
  fake could not have exhibited the bug even if a test had looked. A green suite
  says what it covers, and a fake that degenerates on the untested path says
  nothing at all.

## 2026-07-31 — An instrument that never saturates is measuring itself

Bench session measuring the radio the control loop has to live on: sustained
write rate, acknowledged round trip, connection interval.

- **More samples cannot fix the wrong instrument.** The write-cadence proxy timed
  how long each write waited for the link, on the theory that a saturated buffer
  makes that wait the connection interval. At 60 writes the median was 0.2 ms; at
  300 it was still 0.2 ms, because CoreBluetooth's buffer absorbs the burst and
  almost no write ever meets back-pressure. The instinct — raise the count — would
  have burned the session. The fix was a different quantity: acknowledged writes,
  which cannot complete faster than a real round trip.
- **Report the number that survives the instrument failing.** Sustained write rate
  was always valid, needs no saturation, and is the number the design actually
  turns on (can the 50 ms tick get through? yes, four to sixteen times over). It
  was sitting in the same loop the whole time, uncomputed.
- **An inference with a factor-of-two ambiguity is worth two minutes of capture.**
  A 60 ms acknowledged round trip is either 2 × 30 ms or 1 × 60 ms, and which one
  it is *is* the latency floor. `LE Enhanced Connection Complete` says 30 ms
  outright. Guessing would have been right, and would still have been guessing.
- **The tap is not free.** With PacketLogger running, one device dropped from 81 to
  62 Hz sustained and its acknowledged round trip went from two intervals to
  three; another was unmoved. Take timing without the tap and wire facts with it,
  and never put both in the same table row.
- **An absence in one capture is not an absence in the device.** An earlier capture
  showed no PHY-update and no data-length-change, and that was written up as a
  property of the device. It has both. The capture simply did not contain the
  events.

## 2026-07-31 — "It stops when you let go" is a hypothesis, not a safety property

Bench session answering the link-loss safety question the closed loop was blocked
on, and then a stray observation half an hour later inverting the answer.

- **Stage the physics, don't stage the logistics.** "Carry the device out of
  range" is unrunnable in a flat, and a fridge only attenuates. What out-of-range
  *does* to a peripheral is stop its connection events without a terminate — and
  `sudo pkill -9 bluetoothd` does exactly that, in two seconds, at the keyboard.
  The capture proves it: no `Disconnect` was sent. Distance was never the variable;
  it was only ever a way of producing one.
- **An acknowledgement is not an effect.** A device in a firmware self-drive mode
  answers `OK` to a stop command and carries on. Every stop in this library is
  that command. A reply had been treated as confirmation of state throughout; it
  never was.
- **The dangerous state is the one no software can leave.** The link-loss result
  was reassuring on all three paths — a clean terminate, a `kill -9` on the
  process, and a supervision timeout where the device is told nothing — and then
  irrelevant, because a mode exists in which the firmware owns the motor and
  outlives the central entirely. The useful question is not "does our stop work"
  but "is there a state in which nothing we can send matters".
- **Verify a claim before recording it, especially a flattering one.** A
  mid-session report of "it ran with no command sent" was written up against the
  wrong mode. A controlled A/B twenty minutes later moved it to the right one. The
  finding survived, the attribution did not.

## 2026-07-30 — Closed loop: put the envelope inside the sender

`ControlLoop` + `SafetyLimits`, with the app's feedback section above them.

- **A safety layer above the sender is a layer you can route around; inside it,
  you cannot.** The first sketch had a limiter wrapping `ControlLoop`. Making the
  limits, the latch and the watchdog *state of the loop* removed the question
  entirely: there is no API that emits a level which has not been through
  `SafetyLimits`. Costs nothing, and the limiter stays a pure struct that tests
  without a radio.
- **Make the loop's unit of work a function, not a tick.** `tick(dt:)` is
  internal and the timer task is its only other caller. Every test then asserts
  behaviour — ramp, latch, retry, watchdog — with no sleeping, no flakiness and
  no injected clock. The watchdog counts elapsed time by accumulating `dt` for
  the same reason; it never reads a clock at all.
- **Don't advance your model of the device on a write you didn't land.** With
  `.drop`, the ramp state must only move when the write succeeded, or the next
  successful write jumps by everything that was dropped in between. One line
  (`level` updated after the send, not before), and it is the difference between
  a ramp limit and a suggestion.
- **The first test of an old, hardware-proven type still finds things.**
  `DeviceSession` had run on real devices for weeks. Its first unit test failed
  immediately: the query-timeout task used `try?`, so a *cancelled* sleep fell
  through and failed whichever waiter was registered by then — the next query's.
  Invisible on hardware because the race needs two queries close together.
- **A test double that answers instantly is not modelling a radio.** The fake
  connection replied inside `write`, so the reply beat the waiter registration
  and the test timed out. A real notification cannot arrive before the local
  write returns. Give the double the round trip; the fidelity is the point.
- **One termination path beats four correct ones.** Operator stop, distress,
  sensor loss and link loss all publish a `StopReason` on the loop's status
  stream, and the caller has a single `terminate`. Idempotency comes free
  (disarming stops the intervention, which stops the loop, which publishes again —
  only the first reason sticks) and the UI has one banner rather than four.

## 2026-07-24 — Regular streams: one stream, one consumer

Two high-rate measurements plus heart rate, all three live on a single
`BleConnection`.

- **An `AsyncStream` is single-consumer — demux at the owner, not per caller.**
  When two measurements arrive interleaved on one data characteristic, exactly one
  task consumes the shared stream and routes by the frame-type byte to
  per-measurement continuations. Applies to any shared inbound: the moment two
  logical streams ride one characteristic, the reader must own a demux loop.
- **Non-Sendable BLE types cross actors only as fresh values — or `sending`.**
  Passing a `CBUUID` parameter into an actor method and on to a nonisolated
  `subscribe` trips region-isolation ("sending 'self'-isolated value"); the
  existing code only compiled because each call site built the UUID fresh in the
  same expression. A `sending` parameter states the contract explicitly and
  keeps the call sites natural.

## 2026-07-22 — Adding a GATT read needs the characteristic cached, not just the resolver's match

- **The endpoint resolver only ever was binding one service's characteristics.**
  Adding `read(characteristic:)` needed `BleConnection` to cache *every* discovered
  characteristic by UUID as they are found. The resolver match and the read cache
  are separate concerns now.
- **Read waiters need their own FIFO-per-characteristic map**, mirroring the
  existing `responseWaiters` pattern for write-with-response, and must be
  failed on disconnect the same way (silent hangs otherwise, since
  `didUpdateValueFor` only resumes a continuation if one is queued for that UUID).

## 2026-07-22 — One transport for input and output; standard HR is trivial

`BleTransport` unified to serve both actuators and notify-only sensors, then a
heart-rate reader added on top (standard HR service `0x180D`/`0x2A37`).

- **Standard BLE Heart Rate is a handful of bytes**, worth reusing rather than
  reinventing. Named by the profile, not the vendor, so any strap works.
  Unit-testable in full against synthesised frames; only the stream needs
  hardware. This is also the rule that later decided the module boundary:
  **standard GATT profiles belong here, vendor profiles to a kit.**
- **A device not setting an optional flag is not a device without the hardware.**
  One strap does not set the HR-frame contact-supported flag, so `contact` parses
  as `nil` even though it can sense contact. Parse the flag, report the absence,
  and let the kit that owns the device explain it.
