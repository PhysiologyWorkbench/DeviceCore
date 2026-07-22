import Foundation

/// The Lovense wire protocol: ASCII commands terminated by `;`, e.g.
/// `Vibrate:5;`, `Vibrate2:10;`, `Rotate:15;`, `Air:Level:2;`, `Battery;`,
/// `DeviceType;`. The only `Codec` today; a second vendor is another conformance.
public struct LovenseCodec: Codec {
    public init() {}

    public let terminator: Character = ";"

    public func encode(_ command: DeviceCommand) -> Data {
        let s: String
        switch command {
        case let .vibrate(actuator, level):
            s = actuator.map { "Vibrate\($0):\(level);" } ?? "Vibrate:\(level);"
        case let .rotate(level):    s = "Rotate:\(level);"
        case .rotateChange:         s = "RotateChange;"
        case let .constrict(level): s = "Air:Level:\(level);"
        case .deviceType:           s = "DeviceType;"
        case .battery:              s = "Battery;"
        }
        return Data(s.utf8)
    }

    public func parse(_ frame: String) -> DeviceReply {
        // `DeviceType;` replies are the only colon-bearing messages: `CODE:FF:ID`.
        if frame.contains(":") {
            let parts = frame.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let firmware = parts.count > 1 ? Int(parts[1]) : nil
            let id = parts.count > 2 ? parts[2...].joined(separator: ":") : ""
            return .deviceType(code: parts[0], firmware: firmware, id: id)
        }
        if let percent = Self.batteryPercent(frame) {
            return .battery(percent: percent)
        }
        return .status(frame)
    }

    /// A battery reply is a bare number, sometimes prefixed by a status letter
    /// (e.g. `s89` while the toy is running). Take the trailing digits.
    private static func batteryPercent(_ frame: String) -> Int? {
        let digits = frame.drop { !$0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
