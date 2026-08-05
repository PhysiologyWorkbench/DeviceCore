import Foundation
import CoreBluetooth

/// The standard GATT Battery Service (`0x180F`) and its Battery Level
/// characteristic (`0x2A19`) — a plain read, named by the profile rather than
/// any vendor, so every device serving it reads the same way.
public enum BatteryService {
    public static var service: CBUUID { CBUUID(string: "180F") }
    public static var level: CBUUID { CBUUID(string: "2A19") }

    /// Battery Level's value is a single `uint8` percentage (0…100).
    public static func parse(_ data: Data) -> Int? {
        data.first.map(Int.init)
    }
}
