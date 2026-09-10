# DeviceCore

[![CI](https://github.com/PhysiologyWorkbench/DeviceCore/actions/workflows/ci.yml/badge.svg)](https://github.com/PhysiologyWorkbench/DeviceCore/actions/workflows/ci.yml)

Vendor-neutral Bluetooth Low Energy device I/O for macOS and iOS, in Swift 6:
one library for both directions — sensor **input** (notify streams) and actuator
**output** (setpoints through a safety envelope) — over one CoreBluetooth
transport. No dependencies beyond Foundation and CoreBluetooth.

> **Largely written by Claude.** Not thoroughly reviewed by a human and no
> independent security review. Caveat emptor. Not a medical device, and not
> intended for diagnosis or treatment.

## Where it sits

DeviceCore is the device layer of the **Physiology Workbench**, a family of
native Swift libraries and apps for reading physiological sensors and driving
actuators from what they read, in near real time, on Apple platforms. The
family is being published one repository at a time; this is the bottom of the
device side.

```
┌───────────────────────────────────────────────┐
│ Apps                                  (later) │
├───────────────────────────────────────────────┤
│ Vendor kits — one per manufacturer:   (later) │
│ wire protocol, device catalogue               │
├───────────────────────────────────────────────┤
│ DeviceCore                             (here) │
├───────────────────────────────────────────────┤
│ CoreBluetooth                                 │
└───────────────────────────────────────────────┘
```

Arrows point down only. A vendor kit depends on DeviceCore; DeviceCore depends
on no kit and **names no manufacturer**. What it knows is bytes, connections,
request/response correlation, the standard GATT profiles any device may serve,
and the one method a control loop drives an actuator through. Adding a vendor
adds a module above it and touches nothing here.

Beside it, already public, are the family's other libraries:
[PhysioKit](https://github.com/PhysiologyWorkbench/PhysioKit)
(physiological signal algorithms),
[MediaKit](https://github.com/PhysiologyWorkbench/MediaKit)
(the sensors the OS terminates itself — camera, microphone, audio),
[SwiftLSL](https://github.com/PhysiologyWorkbench/SwiftLSL)
(a Lab Streaming Layer inlet) and
[HDF5Kit](https://github.com/PhysiologyWorkbench/HDF5Kit)
(HDF5 for recording).
The vendor kits and the apps follow.

## What is in the package

Two libraries.
`DeviceCore` is the device I/O core.
`BenchKit` is the host-side substrate that hardware bench tools are built on.
`BenchKit` imports `DeviceCore`, never the other way round,
and no app or shared library imports `BenchKit`.

### `DeviceCore`

| | |
| --- | --- |
| `Transport` / `DeviceConnection` | the abstract byte surface: scan, connect, inbound stream, write with a back-pressure policy, GATT read, extra notify subscriptions |
| `BleTransport` / `BleConnection` | the one CoreBluetooth implementation, identical on macOS and iOS |
| `ScanFilter` / `EndpointResolver` | device shape: a scan matches on name prefix, service UUID or manufacturer id; `NotifyEndpointResolver` binds a notify-only sensor, `FixedEndpointResolver` a control-point pair |
| `DeviceSession` | request/response correlation and demux in `Data` — byte sources in, frames out to a standing subscription or the single outstanding request, which times out |
| `ControlLoop` / `SafetyLimits` | a coalescing tick sender with the safety envelope, hard-stop latch and sensor watchdog *inside* it |
| `Actuator` | the output seam: one method, conformed by a vendor kit's session |
| `HeartRateCodec` / `HeartRateReader` | standard BLE heart rate (`0x180D`/`0x2A37`) — any strap |
| `BatteryService` / `DeviceInformationService` | standard BLE battery level (`0x180F`) and Device Information (`0x180A`), as plain values and identity claims |
| `DeviceTypeRecord` / `DeviceTypeCatalog` | what a device *model* is and can do, as data, with the controlled vocabulary (`Modality`, `ActuatorKind`, `Provenance`); a kit supplies records, an app concatenates catalogues |
| `PhysicalUnit` | one physical unit as a record names it — identity, what the device asserted, how this host reached it — shared by the bench record and the device registry |

### `BenchKit`

Bench tools measure a real device over a real radio and return a verdict. What
they share — and what this library is — is the frame around the measurement, so
that a result can be cited later as *tool @ commit × run UUID*.

| | |
| --- | --- |
| `BenchTool` / `BenchCatalogue` | the tool seam: a name, a synopsis, declared arguments, one `run` returning a verdict; catalogues group tools under a noun |
| `BenchToolRunner` | argument validation before a run exists, then the provenance frame: run UUID, commit table, host unit, timestamps, captures collected from the run directory |
| `RunRecord` / `RunRecordStore` | the typed record and its store — one directory per run UUID, git-diffable JSON, `schemaVersion` refused rather than guessed |
| `WireRadio` / `LiveWireRadio` | what the wire tools ask of a radio, in wire terms only; the CoreBluetooth implementation, and a scripted one in the tests |
| `WireCatalogue` | the vendor-neutral wire tools every host has before any kit: `wire.scan`, `wire.survey`, `wire.notify`, over plain models (`AdvertisementEvent`, `GattSurvey`, `NotifyEvent`) |

## Requirements

Swift 6.0, macOS 13+ / iOS 16+.

## Use

```swift
.package(url: "https://github.com/PhysiologyWorkbench/DeviceCore", branch: "main")
```

No release is tagged yet, so pin `branch: "main"` until one is.

Reading a standard heart-rate strap, which needs no vendor kit:

```swift
let transport = BleTransport(
    scanFilter: ScanFilter(namePrefixes: ["…"], serviceUUIDs: [service]),
    resolver: NotifyEndpointResolver(service: service, rx: measurement))
try await transport.waitUntilPoweredOn()

var connection: DeviceConnection?
for await found in transport.scan() {
    connection = try await transport.connect(found.id, timeout: .seconds(10))
    break
}
guard let connection else { return }

for await reading in await HeartRateReader(connection: connection).readings() {
    print(reading.bpm, reading.rrIntervalsMs)
}
```

Driving an actuator needs a vendor kit: it knows the wire protocol, conforms
its session to `Actuator`, and hands that to `ControlLoop`.

## Build and test

```sh
swift build
swift test        # 92 tests (62 DeviceCore + 30 BenchKit), no hardware required
```

The tests are parser- and mechanism-level: the codecs against synthesised
frames, the correlator and the whole safety envelope against fakes that model
the round trip, the bench frame against a scripted radio. CI runs the same two
commands on macOS and adds an iOS-simulator build, since `swift test` never
exercises iOS.

## Safety

`ControlLoop` drives a device through the single `Actuator` method, and every
stop it performs — operator, distress, watchdog, link loss — is a zero through
that method. **Its authority ends there.** A device whose firmware drives its own
motor from its own sensor will acknowledge a stop and keep running, and will
outlive the central; no software in this library can reach it. Such modes exist
on real hardware, and a vendor kit documents which of its devices have one.
Anything closing a loop on a human should read `Actuator`'s doc comment before
relying on a stop.

## Status

Pre-release: no version is tagged and the public API still moves.

## Design record

- [ARCHITECTURE.md](ARCHITECTURE.md) — the seams and why they are where they are.
- [ROADMAP.md](ROADMAP.md) — broad directions.
- [LESSONS.md](LESSONS.md) — dated lessons, newest first.
- [CLAUDE.md](CLAUDE.md) — working notes for contributors, human or agent.

## Licence

MIT — see [LICENSE](LICENSE).
