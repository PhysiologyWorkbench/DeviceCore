import Foundation

/// One heart-rate reading from the standard BLE Heart Rate Measurement
/// characteristic (`0x2A37`). Neutral: named by the reading, not the vendor, so
/// any HR strap produces one. `contact` is nil when the sensor does not report
/// skin-contact support.
public struct HeartRate: Sendable, Equatable {
    public let bpm: Int
    public let rrIntervalsMs: [Int]
    public let contact: Bool?
    public init(bpm: Int, rrIntervalsMs: [Int], contact: Bool?) {
        self.bpm = bpm
        self.rrIntervalsMs = rrIntervalsMs
        self.contact = contact
    }
}
