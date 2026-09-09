import Foundation

/// The standard BLE Device Information Service (`0x180A`): the mapping from
/// its string characteristics to the claim keys of PWB
/// `design/unit-identity.md`. Neutral like `HeartRate` — any GATT client
/// that has read the characteristics can turn them into claims; nothing
/// here touches CoreBluetooth.
public enum DeviceInformationService {
    /// The service UUID as CoreBluetooth prints it.
    public static let uuid = "180A"

    /// The claim key for one DIS characteristic, by UUID as CoreBluetooth
    /// prints it; nil for characteristics that are no identity claim
    /// (`2A23` system ID and the rest of the service).
    public static func claimKey(forCharacteristic uuid: String) -> String? {
        switch uuid.uppercased() {
        case "2A24": "dis.model"
        case "2A25": "dis.serial"
        case "2A26": "dis.firmware"
        case "2A27": "dis.hardware"
        case "2A29": "dis.manufacturer"
        default: nil
        }
    }

    /// The claim value for a read characteristic: the string verbatim when
    /// the bytes are UTF-8, lowercase hex otherwise (SatisfyerKit's
    /// fallback, per the key table).
    public static func claimValue(_ data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? data.map { String(format: "%02x", $0) }.joined()
    }
}
