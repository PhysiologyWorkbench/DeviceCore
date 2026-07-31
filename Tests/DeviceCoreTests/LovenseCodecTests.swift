import Testing
import Foundation
@testable import DeviceCore

@Suite struct LovenseCodecTests {
    let codec = LovenseCodec()

    private func wire(_ c: DeviceCommand) -> String { String(decoding: codec.encode(c), as: UTF8.self) }
    private func parse(_ s: String) -> DeviceReply { codec.parse(Data(s.utf8)) }
    private func parse(hex: String) -> DeviceReply { codec.parse(Data(hex: hex)) }

    // MARK: Encoding

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
        #expect(wire(.touchMode) == "TouchMode;")
        #expect(wire(.capabilities) == "GetCap;")
    }

    /// `LVS:` carries a raw level byte, which no `String` path can express — the
    /// reason `encode` returns `Data`.
    @Test func encodesLvsAsRawByte() {
        #expect(codec.encode(.lvs(level: 10)) == Data([0x4C, 0x56, 0x53, 0x3A, 0x0A, 0x3B]))
        #expect(codec.encode(.lvs(level: 0)) == Data([0x4C, 0x56, 0x53, 0x3A, 0x00, 0x3B]))
    }

    @Test func encodesOnlyTheTouchModesThatCanBeStopped() {
        #expect(wire(.setTouchMode(.off)) == "TouchMode:0;")
        #expect(wire(.setTouchMode(.stream)) == "TouchMode:3;")
        // Mode 5 hands the motor to the firmware, which then ignores every stop
        // this library can send. It must remain inexpressible.
        #expect(TouchMode.allCases.map(\.rawValue) == [0, 3])
    }

    // MARK: Parsing — identity and battery

    @Test func parsesDeviceType() {
        #expect(parse("P:243:1234567890AB") == .deviceType(code: "P", firmware: 243, id: "1234567890AB"))
        #expect(parse("CA:32:BC8D7E1C581A") == .deviceType(code: "CA", firmware: 32, id: "BC8D7E1C581A"))
        // The emulator returns the full name rather than the short code (see ARCHITECTURE).
        #expect(parse("Lush:02:ABCDEF") == .deviceType(code: "Lush", firmware: 2, id: "ABCDEF"))
    }

    @Test func parsesDeviceTypeNonNumericFirmware() {
        #expect(parse("EI:FW:xx") == .deviceType(code: "EI", firmware: nil, id: "xx"))
    }

    /// The standing assumption that `DeviceType;` replies are the only colon-bearing
    /// messages is false several times over. Every string here was captured from a
    /// real toy on 2026-07-30/31 and must not be read as an identity.
    @Test func doesNotMistakeOtherColonRepliesForIdentity() {
        for reply in ["AI:null", "Adjust:0,0,1", "Light:1,1", "AutoSwith:1:1,1",
                      "info:CA:A:2,1", "TV:40,80,100", "TL:1", "TV:40,80,100,1"] {
            if case .deviceType = parse(reply) { Issue.record("\(reply) parsed as an identity") }
        }
    }

    @Test func parsesBattery() {
        #expect(parse("89") == .battery(percent: 89))
        #expect(parse("100,1") == .battery(percent: 100))   // request tag echoed back
        #expect(parse("s89") == .battery(percent: 89))      // status letter while running
        // Both at once. Confirmed at the wire as one notification, `73 39 38 2C 31 3B`.
        #expect(parse("s97,1") == .battery(percent: 97))
    }

    // MARK: Parsing — the three rejection classes

    @Test func distinguishesTheRejectionClasses() {
        #expect(parse("unkown") == .unsupported)      // the firmware's own misspelling
        #expect(parse("unkown,80") == .unsupported)
        #expect(parse("ER") == .badArguments)         // exists, wrong arguments
        #expect(parse("POWEROFF") == .poweringOff)
        #expect(parse("OK") == .status("OK"))
        #expect(parse("OK,2") == .status("OK,2"))
    }

    @Test func parsesTouchModeIncludingModesWeWillNotSend() {
        #expect(parse("TouchMode:0,1") == .touchMode(raw: 0))
        #expect(parse("TouchMode:3,1") == .touchMode(raw: 3))
        #expect(parse("TouchMode:3,10") == .touchMode(raw: 3))
        #expect(parse("TouchMode:2,1") == .touchMode(raw: 2))
        // Reported truthfully so a session can detect it and clear it.
        #expect(parse("TouchMode:5,1") == .touchMode(raw: 5))
    }

    // MARK: Parsing — the binary replies

    /// `GetCap;` answers `CAP:` then raw bytes, so a text-only reply path loses the
    /// actuator list. Both captured forms: tagged (with the firmware's doubled
    /// terminator) and untagged.
    @Test func parsesCapabilities() {
        #expect(parse(hex: "4341503a1500000001763b")
                == .capabilities(Capabilities(mask: 21, features: ["v"])))
        #expect(parse(hex: "4341503a1500000001762c313b3b")
                == .capabilities(Capabilities(mask: 21, features: ["v"])))
    }

    @Test func decodesASensorFrame() {
        // pos [45, 50, 50, 50, 50], A all 0x14 — rising at 20 units.
        guard case let .depth(frame) = parse(hex: "aa70000b02142d14321432143214325f") else {
            Issue.record("not decoded as a sensor frame"); return
        }
        #expect(frame.positions == [45, 50, 50, 50, 50])
        #expect(frame.velocity == 20)
    }

    @Test func velocityCarriesItsSign() {
        // A all 0x9e — bit 7 set, magnitude 30, the position falling.
        guard case let .depth(frame) = parse(hex: "aa70000b029e469e469e419e3c9e37e6") else {
            Issue.record("not decoded as a sensor frame"); return
        }
        #expect(frame.positions == [70, 70, 65, 60, 55])
        #expect(frame.velocity == -30)
    }

    /// A frame catching a direction change mid-way holds two `A` values. The later
    /// one is the velocity in force when the frame ends.
    @Test func aTransitionFrameKeepsTheLaterVelocity() {
        // A = [0x14, 0x14, 0x94, 0x94, 0x94]: rising, then falling at 20.
        guard case let .depth(frame) = parse(hex: "aa70000b0214141414940f940f940a0d") else {
            Issue.record("not decoded as a sensor frame"); return
        }
        #expect(frame.positions == [20, 20, 15, 15, 10])
        #expect(frame.velocity == -20)
    }

    @Test func rejectsWhatIsNotASensorFrame() {
        #expect(TouchFrame(Data(hex: "aa70000b02142d1432143214321432")) == nil)   // 15 bytes
        #expect(TouchFrame(Data(hex: "4341503a1500000001763b")) == nil)           // GetCap
        // The length field disagreeing with the length is how a different frame
        // shape would announce itself; it is not a frame we understand.
        #expect(TouchFrame(Data(hex: "aa70000c02142d14321432143214325f")) == nil)
    }

    /// Every frame here was captured from a Mission 2 on 2026-07-30/31, chosen to
    /// span the position range and both directions, and includes frames that catch
    /// a direction change mid-frame. The invariants are the ones LOVENSE.md states.
    @Test func realFramesAllSatisfyTheDocumentedInvariants() {
        for hex in Self.capturedFrames {
            guard case let .depth(frame) = parse(hex: hex) else {
                Issue.record("\(hex) did not decode"); continue
            }
            #expect(frame.positions.count == 5)
            for position in frame.positions {
                #expect((0...100).contains(position))
                #expect(position.isMultiple(of: 5))
            }
            #expect((-100...100).contains(frame.velocity))
            #expect(abs(frame.velocity).isMultiple(of: 10))
        }
    }

    // MARK: Framing

    @Test func splitsAsciiRepliesOnTheTerminator() async {
        let out = await frames(["Vibrate:5;Battery;"])
        #expect(out.map(text) == ["Vibrate:5", "Battery"])
    }

    /// `GetCap;`'s tagged reply carries two terminators. The empty message between
    /// them is not a reply.
    @Test func doubledTerminatorYieldsOneMessage() async {
        let out = await frames(["CAP:v,1;;"])
        #expect(out.map(text) == ["CAP:v,1"])
    }

    /// The framer must not weld an unterminated reply to the next one. Observed on
    /// 2026-07-30: `unkown,80` arrived without its `;` and the following reply
    /// landed on top of it. Accumulating until `;` glues them; treating a
    /// notification as a message boundary does not.
    @Test func anUnterminatedReplyIsNotGluedToTheNext() async {
        let out = await frames(["unkown,80", "TV:40,80,100;"])
        #expect(out.map(text) == ["unkown,80", "TV:40,80,100"])
        #expect(codec.parse(out[0]) == .unsupported)
    }

    /// A UTF-8 decode in the framer would destroy the sensor frame, which is the
    /// whole reason the seam moved to `Data`.
    @Test func aBinaryFrameSurvivesBetweenTwoReplies() async {
        let frame = Data(hex: "aa70000b02142d14321432143214325f")
        let out = await frames([Data("OK;".utf8), frame, Data("OK;".utf8)])
        #expect(out.count == 3)
        #expect(out[1] == frame)
        if case .depth = codec.parse(out[1]) {} else { Issue.record("frame not decoded") }
    }

    // MARK: Helpers

    private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    private func frames(_ chunks: [String]) async -> [Data] {
        await frames(chunks.map { Data($0.utf8) })
    }

    private func frames(_ chunks: [Data]) async -> [Data] {
        let source = AsyncStream<Data> { c in
            chunks.forEach { c.yield($0) }
            c.finish()
        }
        var out: [Data] = []
        for await f in codec.frames(from: source) { out.append(f) }
        return out
    }

    /// Captured Mission 2 sensor frames, from `captures/lvs-c15/probe/`.
    static let capturedFrames = [
        "aa70000b0200000000000000231e285f", "aa70000b02000f000f000f000f000f2e",
        "aa70000b020037003c003c003c1441e7", "aa70000b02005f005f005f005f005f53",
        "aa70000b0200640064006400640064ea", "aa70000b020a280a2d0a2d0a2d142d82",
        "aa70000b020a648a460a508a378a3212", "aa70000b02140f141414141419141903",
        "aa70000b0214141414940f940f940a0d", "aa70000b021419141e141e142314289c",
        "aa70000b02142d14321432143214325f", "aa70000b02143214321432143c143c57",
        "aa70000b021446144b14501450145000", "aa70000b02145514559450944b944bbc",
        "aa70000b02145a94559450944b944636", "aa70000b021e141e141e191e1e1e1e5a",
        "aa70000b021e231e231e281e281e2dbb", "aa70000b021e231e2d1e321e32283c47",
        "aa70000b021e289e239e239e141e19fe", "aa70000b021e3c1e411e461e4b1e4b33",
        "aa70000b021e551e551e5a1e5a1e5ac2", "aa70000b021e5a1e5a9e559e559e50bc",
        "aa70000b021e641e641e649e009e005b", "aa70000b021e641e641e649e559e55ea",
        "aa70000b021e641e641e649e5f9e5a7e", "aa70000b021e641e649e5f9e5f1e64d4",
        "aa70000b02805a805a80558055805554", "aa70000b02805f800080008000005fbf",
        "aa70000b028a328a288a058a008a0066", "aa70000b0294009400141e14231423e8",
        "aa70000b02940a940a940a940a1414fe", "aa70000b029e009e009e009e001e050f",
        "aa70000b029e059e051e0a1e141e1e45", "aa70000b029e059e059e051e0a1e0f2a",
        "aa70000b029e0a9e059e059e059e05f1", "aa70000b029e0f9e0f9e0a9e0a9e0add",
        "aa70000b029e199e199e149e149e147b", "aa70000b029e289e289e239e239e2384",
        "aa70000b029e469e469e419e3c9e37e6", "aa70000b029e4b9e4b9e4b9e469e41b0",
        "aa70000b02a84ba84ba84ba846a84609", "aa70000b02bc46bc46bc3cbc323c37eb",
    ]
}

extension Data {
    /// Test-only: the capture logs record frames as hex.
    init(hex: String) {
        self = stride(from: 0, to: hex.count, by: 2).reduce(into: Data()) { data, offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            data.append(UInt8(hex[start..<end], radix: 16) ?? 0)
        }
    }
}
