import Foundation

/// The Lovense wire protocol: ASCII commands terminated by `;`, e.g.
/// `Vibrate:5;`, `Vibrate2:10;`, `Rotate:15;`, `Air:Level:2;`, `Battery;`,
/// `DeviceType;`. The only `Codec` today; a second vendor is another conformance.
///
/// Two replies are **not** ASCII: the Touch-Sense sensor frame (`AA 70 …`) and
/// `GetCap;` (`CAP:` then raw bytes), which is why `parse` takes `Data`.
public struct LovenseCodec: Codec {
    public init() {}

    public let terminator: UInt8 = 0x3B   // ';'

    public func encode(_ command: DeviceCommand) -> Data {
        // `LVS:` is the one command that cannot be written as text: its level is a
        // raw byte, not decimal digits.
        if case let .lvs(level) = command {
            var bytes = Data("LVS:".utf8)
            bytes.append(UInt8(clamping: level))
            bytes.append(terminator)
            return bytes
        }
        let s: String
        switch command {
        case let .vibrate(actuator, level):
            s = actuator.map { "Vibrate\($0):\(level);" } ?? "Vibrate:\(level);"
        case let .rotate(level):        s = "Rotate:\(level);"
        case .rotateChange:             s = "RotateChange;"
        case let .constrict(level):     s = "Air:Level:\(level);"
        case .deviceType:               s = "DeviceType;"
        case .battery:                  s = "Battery;"
        case let .setTouchMode(mode):   s = "TouchMode:\(mode.rawValue);"
        case .touchMode:                s = "TouchMode;"
        case .capabilities:             s = "GetCap;"
        case .lvs:                      preconditionFailure("handled above")
        }
        return Data(s.utf8)
    }

    public func parse(_ message: Data) -> DeviceReply {
        if let frame = TouchFrame(message) { return .depth(frame) }
        if let capabilities = Self.capabilities(message) { return .capabilities(capabilities) }

        let text = String(decoding: message, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A reply may carry the request tag after a comma (`Battery,1;` → `100,1;`),
        // and every model tested echoes it. Nothing here sends tagged commands, so
        // the tag is stripped rather than correlated.
        let body = text.split(separator: ",").first.map(String.init) ?? text

        // Three rejection classes, not one, and the distinction is the whole value
        // of a probe: `ER` says the command exists and the arguments were wrong.
        // (The third, silence, is not a reply and cannot appear here.)
        if body == "unkown" { return .unsupported }
        if body == "ER" { return .badArguments }
        if body == "POWEROFF" { return .poweringOff }
        if let mode = Self.touchMode(body) { return .touchMode(raw: mode) }
        if let identity = Self.deviceType(text) { return identity }
        if let percent = Self.batteryPercent(text) { return .battery(percent: percent) }
        return .status(text)
    }

    /// `CODE:FF:ID` — a short letter code, a firmware version, an id.
    ///
    /// Colon-bearing replies are common (`AI:null`, `TouchMode:3`, `Adjust:0,0`,
    /// `Light:1`, `AutoSwith:1:1`, `info:CA:A:2`, `TV:40,80,100`, `TL:1`), so the
    /// shape has to be checked rather than assumed. Three fields, and a leading
    /// token that is short, alphabetic and capitalised: that admits `CA:32:…`,
    /// `P:243:…` and the emulator's `Lush:02:…`, and excludes `info:CA:A:2` on the
    /// lower-case initial and `AutoSwith:1:1` on the length.
    private static func deviceType(_ text: String) -> DeviceReply? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              let code = parts.first, (1...4).contains(code.count),
              code.allSatisfy(\.isLetter), code.first?.isUppercase == true
        else { return nil }
        return .deviceType(code: code,
                           firmware: Int(parts[1]),
                           id: parts[2...].joined(separator: ":"))
    }

    /// `TouchMode:<n>`, the reply to both the query and the setter.
    private static func touchMode(_ body: String) -> Int? {
        guard body.hasPrefix("TouchMode:") else { return nil }
        return Int(body.dropFirst("TouchMode:".count))
    }

    /// A battery reply is a bare 1–3 digit number, optionally preceded by a status
    /// letter (`s98`, seen while the toy is running — confirmed at the wire, not a
    /// framing artefact) and optionally followed by the request tag (`s98,1`). The
    /// shape is matched whole so that `Light:1` is not read as a 1% battery.
    private static func batteryPercent(_ text: String) -> Int? {
        guard let match = text.wholeMatch(of: /[A-Za-z]?(\d{1,3})(?:,\d+)?/) else { return nil }
        return Int(match.1)
    }

    /// `"CAP:"` `<u32 little-endian>` `<count>` `<count ASCII letters>`. The
    /// terminator is already stripped by the framer — except when the command was
    /// tagged, where the firmware emits a *doubled* one.
    private static func capabilities(_ message: Data) -> Capabilities? {
        let prefix = Data("CAP:".utf8)
        guard message.count >= prefix.count + 5, message.starts(with: prefix) else { return nil }
        let body = Array(message.dropFirst(prefix.count))
        let mask = body[0..<4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let count = Int(body[4])
        guard body.count >= 5 + count else { return nil }
        return Capabilities(mask: mask,
                            features: body[5..<(5 + count)].map { Character(UnicodeScalar($0)) })
    }
}
