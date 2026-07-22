import Foundation
import CoreBluetooth

/// The Polar H10's standard-BLE Heart Rate profile — the input-side profile seam,
/// mirroring `Lovense.swift`. Scoped to the standard HR service (`0x180D` /
/// `0x2A37`); the filter matches any `Polar …` strap, so this doubles as the
/// generic HR profile until a second strap needs its own.
public enum PolarH10 {
    public static var heartRateService: CBUUID { CBUUID(string: "180D") }
    public static var heartRateMeasurement: CBUUID { CBUUID(string: "2A37") }

    /// Standard GATT Battery Service — a plain read, not a Lovense-style serial
    /// query. `discoverServices(nil)` finds it alongside the HR service; the
    /// endpoint resolver never binds it, so reading it goes through
    /// `DeviceConnection.read(characteristic:)` instead.
    public static var batteryLevel: CBUUID { CBUUID(string: "2A19") }

    public static var scanFilter: ScanFilter {
        ScanFilter(namePrefixes: ["Polar"], serviceUUIDs: [heartRateService])
    }

    public static var endpointResolver: EndpointResolver {
        NotifyEndpointResolver(service: heartRateService, rx: heartRateMeasurement)
    }

    /// Battery Level's value is a single `uint8` percentage (0…100).
    public static func parseBatteryLevel(_ data: Data) -> Int? {
        data.first.map(Int.init)
    }

    // Deferred: PMD (Polar Measurement Data) carries the high-rate ACC/ECG streams
    // on service FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8 (control point …C81, data
    // …C82) and needs a control-point handshake + multi-frame binary decode —
    // unlike this notify-only HR path. Add as a separate profile/reader when needed.
}
