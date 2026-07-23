import Foundation

/// One heart-rate reading from the standard BLE Heart Rate Measurement
/// characteristic (`0x2A37`). Neutral: named by the reading, not the vendor, so
/// any HR strap produces one. `contact` is nil when the sensor does not report
/// skin-contact support.
public struct HeartRate: Sendable, Equatable {
    public let bpm: Int
    /// RR intervals in milliseconds, unrounded — the raw 1/1024 s units carried as
    /// fractional ms so ~0.5 ms quantisation doesn't ride on downstream HRV.
    public let rrIntervalsMs: [Double]
    public let contact: Bool?
    public init(bpm: Int, rrIntervalsMs: [Double], contact: Bool?) {
        self.bpm = bpm
        self.rrIntervalsMs = rrIntervalsMs
        self.contact = contact
    }
}
