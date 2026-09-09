import Foundation

/// What the `wire.*` tools ask of a radio, in wire terms only — no vendor
/// knowledge, no endpoint resolution. `LiveWireRadio` is the CoreBluetooth
/// implementation; tests script one.
public protocol WireRadio: Sendable {
    /// Every advertisement seen during the window, duplicates included —
    /// the advertising rate is part of what a scan measures.
    func advertisements(for duration: Duration) async throws -> [AdvertisementEvent]

    /// Find the target within the scan window, connect, walk the full GATT
    /// tree, and read every readable characteristic. Throws
    /// `WireError.deviceNotFound` when the window closes without a match.
    func survey(_ target: WireTarget, scanWindow: Duration) async throws -> GattSurvey

    /// Find and connect as `survey` does, enable notifications on the named
    /// characteristic (as CoreBluetooth prints its UUID — `2A37`, or the
    /// full 128-bit form), and log them for the duration.
    func notifications(from target: WireTarget, characteristic: String,
                       scanWindow: Duration, for duration: Duration) async throws -> [NotifyEvent]
}
