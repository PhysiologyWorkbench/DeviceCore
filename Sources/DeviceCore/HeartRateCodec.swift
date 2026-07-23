import Foundation

/// Parses the standard BLE Heart Rate Measurement characteristic (`0x2A37`).
/// Named by the profile, not the vendor — reusable for any HR strap. This is the
/// unit-test surface; the streaming path needs hardware. Layout per the GATT
/// spec (and `polar-ble-sdk`'s `BleHrClient`).
public enum HeartRateCodec {
    /// Returns nil for a frame too short to hold the flags byte and the heart-rate
    /// value it advertises — a truncated or empty radio notification is skipped,
    /// not trapped.
    public static func parse(_ data: Data) -> HeartRate? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let hrFormat16 = (flags & 0x01) != 0
        let contactSupported = (flags & 0x04) != 0
        let contactDetected = ((flags & 0x06) >> 1) == 0x03
        let energyPresent = (flags & 0x08) != 0
        let rrPresent = (flags & 0x10) != 0
        guard bytes.count >= (hrFormat16 ? 3 : 2) else { return nil }

        var offset: Int
        let bpm: Int
        if hrFormat16 {
            bpm = Int(bytes[1]) | (Int(bytes[2]) << 8)
            offset = 3
        } else {
            bpm = Int(bytes[1])
            offset = 2
        }
        if energyPresent { offset += 2 }

        var rr: [Int] = []
        if rrPresent {
            while offset + 1 < bytes.count {
                let raw = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
                rr.append(Int((Double(raw) / 1024.0 * 1000.0).rounded()))
                offset += 2
            }
        }

        return HeartRate(bpm: bpm,
                         rrIntervalsMs: rr,
                         contact: contactSupported ? contactDetected : nil)
    }
}
