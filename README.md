# DeviceCore

Vendor-neutral BLE device I/O for macOS and iOS, in Swift 6: one library for both
directions — sensor **input** (notify streams) and actuator **output** (setpoints
through a safety envelope) — over one CoreBluetooth transport.

It names no manufacturer. Protocol knowledge lives in a vendor kit above it
(`LovenseKit`, `PolarKit`); what this library knows is bytes, connections,
correlation, standard GATT profiles, and the one method a control loop drives an
actuator through.

## What is in it

| | |
| --- | --- |
| `Transport` / `DeviceConnection` | the abstract byte surface: scan, connect, inbound stream, write with a back-pressure policy, GATT read, extra notify subscriptions |
| `BleTransport` / `BleConnection` | the one CoreBluetooth implementation, identical on macOS and iOS |
| `ScanFilter` / `EndpointResolver` | device shape; `NotifyEndpointResolver` for a notify-only sensor, `FixedEndpointResolver` for a control-point pair |
| `DeviceSession` | request/response correlation and demux in `Data` — byte sources in, frames out to a standing subscription or the single outstanding request, which times out |
| `ControlLoop` / `SafetyLimits` | a coalescing tick sender with the safety envelope, hard-stop latch and sensor watchdog *inside* it |
| `Actuator` | the output seam: one method, conformed by a vendor kit's session |
| `HeartRateCodec` / `HeartRateReader` | standard BLE heart rate (`0x180D`/`0x2A37`) — any strap, so it belongs to no vendor |

## Requirements

Swift 6.0, macOS 13+ / iOS 16+. No dependencies beyond Foundation and
CoreBluetooth.

## Use

```swift
.package(url: "https://github.com/PhysiologyWorkbench/DeviceCore", from: "0.1.0")
```

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

## Build and test

```sh
swift build
swift test        # 37 tests, no hardware required
```

The tests are parser- and mechanism-level and run without a radio. Transport and
handshake behaviour is validated by the per-vendor hardware CLIs, which live in
the kits rather than here.

## Safety

`ControlLoop` drives a device through the single `Actuator` method, and every
stop it performs — operator, distress, watchdog, link loss — is a zero through
that method. **Its authority ends there.** A device whose firmware drives its own
motor from its own sensor will acknowledge a stop and keep running, and will
outlive the central; no software in this library can reach it. Vendor kits
document which of their devices have such a mode. Anything closing a loop on a
human should read `Actuator`'s doc comment before relying on a stop.

## Status

Used in production by the Physiology Workbench. Hardware-validated against BLE
actuators and a chest strap over the whole 2026-07 development period; the safety
envelope has been exercised on real radios, not only against fakes.

## Licence

Not yet stated — the repository is pre-publication.
