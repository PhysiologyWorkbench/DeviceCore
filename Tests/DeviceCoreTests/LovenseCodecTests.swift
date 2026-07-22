import Testing
import Foundation
@testable import DeviceCore

@Suite struct LovenseCodecTests {
    let codec = LovenseCodec()

    private func wire(_ c: DeviceCommand) -> String { String(decoding: codec.encode(c), as: UTF8.self) }

    @Test func encodesVibrate() {
        #expect(wire(.vibrate(actuator: nil, level: 5)) == "Vibrate:5;")
        #expect(wire(.vibrate(actuator: 2, level: 10)) == "Vibrate2:10;")
    }

    @Test func encodesRotateConstrictAndQueries() {
        #expect(wire(.rotate(level: 15)) == "Rotate:15;")
        #expect(wire(.rotateChange) == "RotateChange;")
        #expect(wire(.constrict(level: 2)) == "Air:Level:2;")
        #expect(wire(.deviceType) == "DeviceType;")
        #expect(wire(.battery) == "Battery;")
    }

    @Test func parsesDeviceType() {
        #expect(codec.parse("P:243:1234567890AB") == .deviceType(code: "P", firmware: 243, id: "1234567890AB"))
        // The emulator returns the full name rather than the short code (see ARCHITECTURE).
        #expect(codec.parse("Lush:02:ABCDEF") == .deviceType(code: "Lush", firmware: 2, id: "ABCDEF"))
    }

    @Test func parsesDeviceTypeNonNumericFirmware() {
        #expect(codec.parse("EI:FW:xx") == .deviceType(code: "EI", firmware: nil, id: "xx"))
    }

    @Test func parsesBattery() {
        #expect(codec.parse("89") == .battery(percent: 89))
        #expect(codec.parse("s89") == .battery(percent: 89))   // status-prefixed while running
    }

    @Test func parsesStatusPassthrough() {
        #expect(codec.parse("OK") == .status("OK"))
    }

    @Test func framesSplitOnTerminatorAcrossChunks() async {
        let source = AsyncStream<Data> { c in
            c.yield(Data("Vibr".utf8))
            c.yield(Data("ate:5;Batt".utf8))
            c.yield(Data("ery;  ;X".utf8))   // empty frame between the two ';' is dropped; "X" has no terminator
            c.finish()
        }
        var out: [String] = []
        for await f in codec.frames(from: source) { out.append(f) }
        #expect(out == ["Vibrate:5", "Battery"])
    }
}
