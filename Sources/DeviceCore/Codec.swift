import Foundation

// The vendor seam (ARCHITECTURE principle 4): `DeviceSession` speaks only this
// neutral vocabulary and the `Codec` protocol, never a specific vendor. A second
// vendor is another `Codec` conformance; nothing else changes.

/// A command to a toy, in the toy's own raw value range (scaling from 0…1 to the
/// feature range happens in `DeviceSession`, which owns the ranges). Cases mirror
/// the `Feature` kinds plus the two query commands.
public enum DeviceCommand: Equatable, Sendable {
    /// `actuator` is the 1-based wire slot for a multi-actuator toy, or `nil` for
    /// the unnumbered form used when the toy has a single vibrator.
    case vibrate(actuator: Int?, level: Int)
    case rotate(level: Int)
    /// Toggle the direction of rotation.
    case rotateChange
    case constrict(level: Int)
    case deviceType
    case battery
}

/// A message from a toy, classified. `deviceType` carries the identity handshake
/// (`CODE:FF:ID`); `battery` a 0…100 percentage; `status` anything else
/// (unsolicited events, unrecognised replies).
public enum DeviceReply: Equatable, Sendable {
    case deviceType(code: String, firmware: Int?, id: String)
    case battery(percent: Int)
    case status(String)
}

/// A vendor's wire protocol. Framing is shared here (the default `frames`); only
/// the terminator and the command/reply mapping are vendor-specific, so a
/// conformance is three small members.
public protocol Codec: Sendable {
    /// Byte that terminates one message on the wire.
    var terminator: Character { get }
    /// Renders a command to its on-the-wire bytes.
    func encode(_ command: DeviceCommand) -> Data
    /// Classifies one already-de-framed message.
    func parse(_ frame: String) -> DeviceReply
}

public extension Codec {
    /// Splits raw notification chunks into `terminator`-delimited messages,
    /// trimming whitespace and dropping empties. Shared across vendors.
    func frames(from stream: AsyncStream<Data>) -> AsyncStream<String> {
        let terminator = self.terminator
        return AsyncStream { continuation in
            Task {
                var buffer = ""
                for await chunk in stream {
                    buffer += String(decoding: chunk, as: UTF8.self)
                    while let end = buffer.firstIndex(of: terminator) {
                        let msg = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !msg.isEmpty { continuation.yield(msg) }
                        buffer = String(buffer[buffer.index(after: end)...])
                    }
                }
                continuation.finish()
            }
        }
    }
}
