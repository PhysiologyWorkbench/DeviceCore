# Roadmap — DeviceCore

Broad directions, not a work queue. The queue itself lives on the family's
board, which is not public yet; what this library already does, and why, is in
ARCHITECTURE.md. Nothing here is a commitment to a date or an order.

## Where the stop authority principle actually ends

Our [ARCHITECTURE](ARCHITECTURE.md#where-stop-authority-ends) aims
to make sure all the actuators are stopped in the case of emergencies
or other unexpected events.  However, in practice some actuators do
not allow full control, due to their firmware design.

Currently, every stop action in this library eventually calls
`Actuator.setVibration(…, 0)`.
The library has no other means to stop the actuators.
Hence, its stop authority ends where that call's effects end.
When the firmware drives its own motor from its own sensor and
merely acknowledges the call and carries on,
the library's stop is not a stop.

The direction is to map exactly the state space per vendor and device —
which settings survive a disconnect, which can be read,
which can be set at all —
before the library asserts anything on connect,
followed by extending the same question across hosts,
once a rig spans more than one host.

A device whose firmware guarantees stop-on-disconnect would settle
this issue from the side of the device.
Our goal is to explore how this principle can be implemented with
(custom) device firmware.

## Device knowledge as data

We aim to represent devices as data, not as code.
`DeviceTypeCatalog` and `PhysicalUnit` are the first step of moving what is
known about a device — how it identifies itself, what it can do, what was
measured on it — out of code and into data records.
That knowledge should grow into a shared catalogue the family's members read
from and write to, rather than a table each kit carries alone.

## More devices behind the same seams

While everything here currently assumes BLE,
the seams were cut so that need not stay true.
A phone's own haptics and sensors, or a wired development board, are
actuators and sensors too; the direction is to bring such devices in as further
`Transport` and `Actuator` conformers, and to find out whether the four seams
hold or where they need widening.

## The bench grows around the measurement

`BenchKit` began with the run record. The next layers are the tools that
produce records, the radio primitives every vendor bench repeats, and —
further out — a bench that borrows an app's live connections instead of
opening its own, so that a measurement can be taken on a rig that is already
running.

## Stopping as a family pattern

The hard-stop latch in `ControlLoop` is the primitive; how an operator reaches
it from any application, on any host, with the device not necessarily in the
foreground, is a pattern the applications share and this library should make
easy to adopt correctly.

## iOS as a first-class central

The numbers this library stands on were measured with a macOS central.
Measuring an iOS one — connection interval, reconnection, background behaviour
— is what the first iOS application will do.
