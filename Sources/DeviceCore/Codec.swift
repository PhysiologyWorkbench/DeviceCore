import Foundation

// The vendor seam (ARCHITECTURE principle 4): `DeviceSession` speaks only this
// neutral vocabulary and the `Codec` protocol, never a specific vendor. A second
// vendor is another `Codec` conformance; nothing else changes.
//
// Framing is byte-level, not `String`-level. Two of the replies this seam has to
// carry are binary — the Touch-Sense sensor frame starts `AA 70`, and `GetCap`
// answers `CAP:` followed by raw bytes — so a UTF-8 decode in the framer destroys
// exactly the messages that matter. See MISSION2-INPUT.md §9.

/// A command to a toy, in the toy's own raw value range (scaling from 0…1 to the
/// feature range happens in `DeviceSession`, which owns the ranges). Cases mirror
/// the `Feature` kinds plus the query commands.
public enum DeviceCommand: Equatable, Sendable {
    /// `actuator` is the 1-based wire slot for a multi-actuator toy, or `nil` for
    /// the unnumbered form used when the toy has a single vibrator.
    case vibrate(actuator: Int?, level: Int)
    /// The binary vibrate form, `LVS:<byte>;` — one raw level byte, same 0…20
    /// range as `vibrate`. What the official iOS app uses for every change.
    case lvs(level: Int)
    case rotate(level: Int)
    /// Toggle the direction of rotation.
    case rotateChange
    case constrict(level: Int)
    case deviceType
    case battery
    /// Enable or disable the position stream.
    case setTouchMode(TouchMode)
    case touchMode
    /// The runtime actuator list — the only description of Mission 2's and Ferri's
    /// actuators that exists, the vendored config having no feature rows for either.
    case capabilities
}

/// The Touch-Sense modes `DeviceCore` is willing to send.
///
/// **Mode 5 is deliberately absent and must stay absent.** There the firmware
/// drives the motor from its own sensor: it ignores `Vibrate:0;` while answering
/// `OK;` to it, and it keeps running after the central has ceased to exist
/// (measured 2026-07-31 — LOVENSE.md, "`TouchMode:5` — the firmware owns the
/// motor"). Every stop in this library reduces to that command, so a toy in mode 5
/// cannot be stopped by software at all. Mode 3 gives the whole position stream
/// with none of it.
public enum TouchMode: Int, Sendable, CaseIterable {
    case off = 0
    case stream = 3
}

/// One 16-byte Touch-Sense frame.
///
/// ```
/// AA 70 00 0B 02 │ A₀ B₀ A₁ B₁ A₂ B₂ A₃ B₃ A₄ B₄ │ CK
///  0  1  2  3  4 │ 5 ........................ 14 │ 15
/// ```
///
/// Values are raw as sent; mapping to 0…1 and to millimetres belongs above this
/// layer. The trailing CRC-8 is not checked — it is only ever received, and the
/// commands we send are ASCII-framed.
public struct TouchFrame: Equatable, Sendable {
    /// The five `B` bytes in order: 0…100 in steps of 5, the position of the
    /// **lowest contact point** in millimetres from the tip minus 20.
    public let positions: [Int]

    /// Signed velocity: negative while the position is falling, magnitude in units
    /// of roughly 4 mm/s.
    ///
    /// This is **one measurement per frame, not five.** The five `A` bytes were
    /// identical in 96.6% of 2106 captured frames and held exactly two values in
    /// the rest — a direction change caught mid-frame — so pairing them with the
    /// five positions would invent structure that is not there. Where a frame
    /// holds two, the later one is kept: it is the velocity in force when the
    /// frame ends.
    public let velocity: Int

    static let magic: [UInt8] = [0xAA, 0x70]
    static let length = 16

    public init?(_ bytes: Data) {
        let b = Array(bytes)
        guard b.count == Self.length, b[0] == Self.magic[0], b[1] == Self.magic[1],
              Int(b[3]) + 5 == b.count else { return nil }
        positions = (0..<5).map { Int(b[6 + 2 * $0]) }
        let a = b[13]
        velocity = a & 0x80 != 0 ? -Int(a & 0x7F) : Int(a & 0x7F)
    }
}

/// The runtime actuator list from `GetCap;`: `"CAP:"` then a little-endian u32,
/// a count, that many ASCII feature letters, and `;`.
public struct Capabilities: Equatable, Sendable {
    /// Presumed a capability mask. 21 on Mission 2 and Ferri, 82 on Solace Pro —
    /// two values across three models is not enough to decode it.
    public let mask: UInt32
    /// `v` is vibrate; the Solace Pro thrusting stroker reports `t`, `b`, `c`,
    /// which are not yet identified.
    public let features: [Character]
}

/// A message from a toy, classified.
public enum DeviceReply: Equatable, Sendable {
    case deviceType(code: String, firmware: Int?, id: String)
    case battery(percent: Int)
    /// Raw, because a toy may report a mode this library will not send — 5 in
    /// particular, which no software stop can escape.
    case touchMode(raw: Int)
    case depth(TouchFrame)
    case capabilities(Capabilities)
    /// `unkown` — the firmware's own misspelling. No such command.
    case unsupported
    /// `ER` — the command exists and the arguments were wrong. This is what
    /// separates "no such command" from "right name, wrong shape".
    case badArguments
    /// Unsolicited, immediately before the toy drops the link itself.
    case poweringOff
    /// Anything else: acknowledgements, unrecognised replies.
    case status(String)
}

/// A vendor's wire protocol.
public protocol Codec: Sendable {
    /// Byte that terminates one message on the wire.
    var terminator: UInt8 { get }
    /// Renders a command to its on-the-wire bytes.
    func encode(_ command: DeviceCommand) -> Data
    /// Classifies one already-de-framed message.
    func parse(_ message: Data) -> DeviceReply
}

public extension Codec {
    /// Splits raw notification chunks into messages. Shared across vendors.
    ///
    /// **One notification is one message boundary**, so nothing is accumulated
    /// across chunks. BLE preserves notification boundaries and the negotiated MTU
    /// is 247 against replies of a few bytes, so a split reply is not a case that
    /// arises — whereas gluing two replies together is a case that *has* arisen: a
    /// `unkown,80` was once seen with no terminator, and an accumulate-until-`;`
    /// framer silently welds it to whatever comes next. A trailing piece with no
    /// terminator is therefore yielded as its own message rather than held.
    ///
    /// A chunk that is not entirely printable ASCII is a binary frame and passes
    /// through whole and undecoded.
    func frames(from stream: AsyncStream<Data>) -> AsyncStream<Data> {
        let terminator = self.terminator
        return AsyncStream { continuation in
            Task {
                for await chunk in stream where !chunk.isEmpty {
                    guard chunk.allSatisfy(Self.isTextByte) else {
                        continuation.yield(chunk)
                        continue
                    }
                    for piece in chunk.split(separator: terminator) {
                        continuation.yield(Data(piece))
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Printable ASCII, plus the whitespace a reply might legitimately carry.
    private static func isTextByte(_ b: UInt8) -> Bool {
        (0x20...0x7E).contains(b) || b == 0x0A || b == 0x0D || b == 0x09
    }
}
