# CLAUDE.md — DeviceCore

## What this is

The vendor-neutral BLE device I/O core for the Physiology Workbench family:
one library serving both directions — actuator **output** (setpoints through a
safety envelope) and sensor **input** (notify streams) — over one CoreBluetooth
transport.

**It names no manufacturer, anywhere, comments included.** That is not tidiness:
it is the property that lets a vendor kit be added, replaced or dropped without
touching this repo. If a change to this library needs the name of a device
maker, the change belongs in a kit.

This repository is public; the vendor kits above it, the apps above them and
the **PWB** repository this file refers to for the system-wide record and the
work queue are not yet. A reader here sees those references before the things
they point at.

## Constraints

- **macOS and iOS are both hard requirements.** iPadOS later. Everything here
  compiles for both; `BleTransport` is identical on the two.
- **Latency budget: a few hundred ms end to end**, of which the BLE connection
  interval (measured 30 ms on the devices tested) is the floor. The design rule
  is not "be fast" but "add as little as possible on top of the radio".
- Swift 6 language mode, strict concurrency. Actors, no locks.

## Layout

```
Sources/DeviceCore/
  Transport.swift      — the abstract vocabulary: Transport, DeviceConnection,
                         ScanFilter, EndpointResolver (+ Notify/Fixed resolvers),
                         BusyPolicy, TransportError
  BleTransport.swift   — the one CoreBluetooth implementation (BleTransport,
                         BleConnection), device-neutral
  DeviceSession.swift  — the shared correlator/demux, in `Data`
  ControlLoop.swift    — the coalescing tick sender, safety envelope inside it,
                         and the `Actuator` output seam
  SafetyLimits.swift   — ceiling, rise/fall rates, input timeout; pure `step`
  HeartRate*.swift     — standard GATT heart rate (0x180D / 0x2A37)
  Battery.swift        — standard GATT battery level (0x180F / 0x2A19)
  DeviceInformation.swift — standard GATT Device Information (0x180A) as
                         identity claims (PWB design/unit-identity.md)
  DeviceType.swift     — the device-type DB's vocabulary and record shapes;
                         the records live in the kits (PWB
                         design/device-type-db-v0.md)
  PhysicalUnit.swift   — one physical unit as a record names it: identity,
                         claims, host bindings
Sources/BenchKit/      — the second product (2026-09-09, PWB
                         design/bench-host-toolbox.md R46): the bench substrate the
                         vendor kits' bench targets build on. BenchTool /
                         BenchCatalogue / BenchToolRunner (the tool seam and
                         the provenance frame), RunRecord / JSONValue /
                         RunRecordStore (one directory per run UUID,
                         git-diffable JSON, schemaVersion from day one),
                         HostUnit, and the generic wire layer — WireRadio
                         (LiveWireRadio over CoreBluetooth; tests script
                         one), WireModels, WireTools (`wire.scan`,
                         `wire.survey`, `wire.notify`). No app or shared
                         library imports it — arch rule
                         `benchKitStaysOutOfAppsAndLibraries`.
Tests/DeviceCoreTests/, Tests/BenchKitTests/
```

`swift build` / `swift test` from the repo root. Green baseline: **92 tests**
(62 DeviceCore + 30 BenchKit). CI runs the same two commands on `macos-15`, plus
an iOS-simulator build, since `swift test` never exercises iOS.

## Dependencies

**None.** This is a leaf: Foundation and CoreBluetooth only.

Its dependents — LovenseKit, PolarKit, SatisfyerKit and the PWB app — reference it as
`.package(path: "../DeviceCore")` **pre-publication only**. At publication that
becomes `.package(url: "https://github.com/PhysiologyWorkbench/DeviceCore", from:
"0.1.0")` and the sibling checkout stops being load-bearing. The switch is
step **C2** of the repo split; each dependent's manifest carries a `PROVISIONAL`
comment at the line, naming the URL it becomes.

Sibling repos, all directly under the same parent: `DeviceCore`, `LovenseKit`,
`PolarKit`, `SatisfyerKit`, `PhysioKit`, `Hdf5Store`, `SwiftLSL`, `PWB`. The
directory names are load-bearing — SwiftPM derives a path dependency's package
identity from the directory basename, not from the manifest's `name:`.

## The seams, and what each is for

`DeviceCore` offers four, and only four:

1. **`Transport` / `DeviceConnection`** — bytes. Scan, connect, an inbound
   `AsyncStream<Data>`, write with a `BusyPolicy`, GATT read, extra notify
   subscriptions.
2. **`ScanFilter` + `EndpointResolver`** — device shape. A scan matches on any of
   a name prefix, a service UUID, or a manufacturer company id.
   `NotifyEndpointResolver` binds rx alone (a notify-only sensor);
   `FixedEndpointResolver` binds an explicit control-point pair; a resolver may
   bind tx alone (a write-only device), and then readiness is completed
   characteristic discovery rather than notify confirmation. A kit may add its
   own resolver — that is the seam working. Resist adding resolver shapes here
   until a real device demands one.
3. **`DeviceSession`** — correlation and demux (below).
4. **`Actuator`** — one method, the entire output surface (below).

There was a fifth, `Codec`, meant as *the* vendor seam. It had exactly one
conformer for its whole life, and the second vendor bypassed it entirely — its
codecs are plain enums over a binary control point, sharing nothing with a
`;`-terminated ASCII one but the word "codec". It was dissolved into the kit that
used it. **Do not reintroduce it.** The seam that works is the one the *core*
needs, not the one a vendor offers.

## `DeviceSession` — one mechanism, three callers

`DeviceSession` is the vendor-neutral request/response correlator and demux, in
`Data`: plural byte sources in, frames out to either a standing subscription or
the single outstanding request (which times out). **A standing subscription
consumes its frame before any request sees it**, so a sensor frame can never
answer a query.

Its callers, by name:

- **`LovenseSession`** (LovenseKit) — replies and binary sensor frames share one
  rx characteristic, so the fan-aside is load-bearing there;
- **`PolarPmdSession`** (PolarKit) — feeds *both* its control point and its data
  characteristic into one session, and gets its ECG/ACC separation from each
  parse rejecting the other's type byte;
- **`HeartRateReader`** (here) — the degenerate caller: no write, no reply, one
  characteristic, one consumer. It is on the shared type deliberately, as the
  cheapest guard against a mechanism shaped too tightly around the two rich ones.

**A further vendor adds a caller, not a second copy.** This is written down
because the duplication it replaced was invisible for weeks: two subsystems in
one module had independently grown the same correlator, and they did not merely
duplicate — they *disagreed*, one of them able to hang for ever on a device that
accepts a subscription and then says nothing.

Design notes that are easy to undo by accident:

- **Framing is byte-level throughout.** A caller may pass its own splitter, but
  what it splits is `Data`. Some replies on real devices are binary; a `String`
  in the framer would destroy exactly the messages that matter.
- `select` returns `T?`, not `Bool` — matching and parsing are one act, so no
  frame is parsed twice.
- `subscribe`'s termination hook is `async` and runs on the session's own task,
  so a caller never spawns a `Task` to re-enter its own actor.
- When the last source finishes, the outstanding request fails at once with
  `TransportError.notConnected` and every subscription finishes.

## Stop authority — the constraint that governs this library

`ControlLoop` reaches its device through **one method**:

```swift
public protocol Actuator: Sendable {
    @discardableResult
    func setVibration(_ ordinal: Int, _ level: Double, ifBusy: BusyPolicy) async throws -> Bool
}
```

Every stop in this library — operator stop, distress fade, sensor watchdog, link
loss, hard-stop latch — is a zero through that method. **So the stop authority of
everything above reaches exactly as far as that method does, and no further.**

A device whose firmware drives its own motor from its own sensor cannot be
stopped by this library at all: it will acknowledge the command and keep running,
and it survives the central ceasing to exist. Such modes are real, not
hypothetical — one vendor's `TouchMode:5` is exactly this, and it persists across
a disconnect. Which modes exist, how to read one back and what a caller must do
about it is the vendor kit's business; **that this library loses against them is
DeviceCore's business, and must stay written here.** A warning attached only to
the vendor half becomes invisible to the half that needs it.

The mitigation available today is operational, not architectural: power-cycle a
device before a session.

## Rules this repo enforces

- **Standard GATT profiles belong here; vendor profiles belong to a kit.** That
  is why `HeartRateCodec`/`HeartRateReader` (0x180D/0x2A37 — any strap) live
  here while the strap's own high-rate service does not.
- **Radio input never traps.** Every BLE-facing parser guards lengths and skips
  malformed frames rather than indexing.
- **The safety envelope lives *inside* the sender.** `SafetyLimits`, the
  hard-stop latch and the sensor watchdog are state of `ControlLoop`; there is no
  API that emits a level which has not been through them.
- **Streams are single-consumer** — demux at the owner, never per caller.
- **One serial context per non-thread-safe resource.** CoreBluetooth lives on its
  own queue, bridged to `async`/`await` per request and to `AsyncStream` for
  notifications.
- **Test doubles must model the round trip.** A fake that replies inside `write`,
  or serves an immediately-finished subscribe stream, converts a hang into a pass
  — which is the worst direction for a double to be wrong in.

## Hardware truth

Unit tests cover parsers against synthesised frames; only a real radio validates
transport and handshakes. This repo has **no hardware CLI of its own** — the
per-vendor harnesses live in the kits (`lovense-harness`, `polar-harness`), which
is where a device to point them at also lives. Budget one hardware round-trip per
new binary stream.

## The family board

The owner-blocked queue for the whole family lives in **PWB** (private), at
`../PWB/.devtool/features/` — one kanban-markdown card per task (YAML
frontmatter, rendered by the LachyFS.kanban-markdown extension in VSCodium).
Labels say who is blocked — `owner-bench`, `owner-decision`, `agent`, `gated` —
and which repo owns the work.

**One board, not one per repo, because the bottleneck is one person.** The
board answers "where does the owner stand", and that question does not
decompose per repo; this repo has no NOW.md of its own.

Work done from here updates the cards there:

- **Move the card with the work.** Status changes travel in the same
  commit-sized unit as the change they describe; a card that closes moves to
  `done/` with `completedAt` set. A board updated in a later sweep is a board
  that reports yesterday.
- **A card is an index entry, never a copy.** The detail belongs in this repo's
  records — ARCHITECTURE.md, LESSONS.md, the source — and the card names the
  goal, points at that place, and gives the next command. ROADMAP.md gives
  broad directions only, never detail. Copying detail into a card creates a
  second source of truth that drifts from the first.
- **Ask before adding a card.** New work appearing mid-task is normal and worth
  capturing, but what belongs on the owner's queue is the owner's judgement,
  not the agent's.

## Design record

`ARCHITECTURE.md` — the seams and why they are where they are.
`ROADMAP.md` — broad directions only; the detail is on the board.
`LESSONS.md` — dated lessons; skim before work that resembles past work.
The system-wide picture (apps, pipeline, recording, research programmes) is in
the **PWB** repo's ARCHITECTURE.md, not yet public.

## The architecture gate

Family-wide architecture rules run as a pre-push hook in every repo. After
any structural change here — imports added, public types added, isolation
attributes changed — run
`swift test --package-path ../PWB/tools/arch/ArchRules`; fix or get a ruling,
never bypass silently. Setup and detail: `../PWB/TOOLING.md`.
