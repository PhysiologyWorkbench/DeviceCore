import Testing
import Foundation
@testable import DeviceCore

@Suite struct PmdCodecTests {
    /// A common PMD data header: type byte, 8-byte LE timestamp, frame-type byte.
    private func frame(type: UInt8, timestamp: UInt64, frameType: UInt8, content: [UInt8]) -> Data {
        var bytes: [UInt8] = [type]
        for i in 0..<8 { bytes.append(UInt8((timestamp >> (8 * i)) & 0xFF)) }
        bytes.append(frameType)
        bytes.append(contentsOf: content)
        return Data(bytes)
    }

    @Test func measurementTypeDemuxKey() {
        #expect(PmdCodec.measurementType(of: frame(type: 0x00, timestamp: 1, frameType: 0x00, content: [])) == .ecg)
        #expect(PmdCodec.measurementType(of: frame(type: 0x02, timestamp: 1, frameType: 0x01, content: [])) == .acc)
        // The two high header bits are flags, not part of the type.
        #expect(PmdCodec.measurementType(of: Data([0x82])) == .acc)
        // Unknown measurement, and empty data, are nobody's frames.
        #expect(PmdCodec.measurementType(of: Data([0x05])) == nil)
        #expect(PmdCodec.measurementType(of: Data()) == nil)
    }

    // MARK: Control point

    @Test func startAndStopCommandBytes() {
        let settings = PmdCodec.setting(.sampleRate, 130) + PmdCodec.setting(.resolution, 14)
        #expect(settings == [0x00, 0x01, 0x82, 0x00, 0x01, 0x01, 0x0E, 0x00])
        #expect([UInt8](PmdCodec.startCommand(.ecg, settings: settings))
                == [0x02, 0x00, 0x00, 0x01, 0x82, 0x00, 0x01, 0x01, 0x0E, 0x00])
        #expect([UInt8](PmdCodec.stopCommand(.acc)) == [0x03, 0x02])
    }

    @Test func controlResponseSuccessAndError() {
        let ok = PmdCodec.parseControlResponse(Data([0xF0, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x82, 0x00]))!
        #expect(ok.opCode == 0x02)
        #expect(ok.measurementType == 0x00)
        #expect(ok.isSuccess)
        #expect(ok.parameters == [0x00, 0x01, 0x82, 0x00])

        let rejected = PmdCodec.parseControlResponse(Data([0xF0, 0x02, 0x02, 0x08]))!
        #expect(rejected.errorCode == 0x08)   // invalid sample rate
        #expect(!rejected.isSuccess)

        // Not a control-point response (feature list / data frame first bytes).
        #expect(PmdCodec.parseControlResponse(Data([0x0F, 0x00])) == nil)
        #expect(PmdCodec.parseControlResponse(Data([0x00])) == nil)
    }

    @Test func factorFromStartResponse() {
        // A sampleRate setting then a factor of 1.0 (0x3F800000 LE).
        let params: [UInt8] = [0x00, 0x01, 0x34, 0x00, 0x05, 0x01, 0x00, 0x00, 0x80, 0x3F]
        #expect(PmdCodec.factor(fromStartResponse: params) == 1.0)
        #expect(PmdCodec.factor(fromStartResponse: [0x00, 0x01, 0x34, 0x00]) == nil)
    }

    // MARK: ECG

    @Test func ecgDecodesSigned24BitMicrovolts() {
        // +100 µV (64 00 00) and -100 µV (9C FF FF), uncompressed type 0.
        let data = frame(type: 0, timestamp: 1000, frameType: 0x00,
                         content: [0x64, 0x00, 0x00, 0x9C, 0xFF, 0xFF])
        let ecg = PmdCodec.parseEcg(data, sampleRate: 130)!
        #expect(ecg.samplesMicrovolts == [100, -100])
        #expect(ecg.timestampNs == 1000)
        #expect(ecg.sampleRate == 130)
    }

    @Test func ecgRejectsCompressedFrame() {
        let data = frame(type: 0, timestamp: 0, frameType: 0x80, content: [0x00, 0x00, 0x00])
        #expect(PmdCodec.parseEcg(data, sampleRate: 130) == nil)
    }

    // MARK: ACC

    @Test func accAppliesFactorScaling() {
        // One uncompressed sample (1000, -2000, 500); factor 2.0 doubles each axis.
        let content: [UInt8] = [0xE8, 0x03, 0x30, 0xF8, 0xF4, 0x01]
        let data = frame(type: 2, timestamp: 0, frameType: 0x01, content: content)
        let acc = PmdCodec.parseAcc(data, sampleRate: 200, factor: 2.0)!
        #expect(acc.samples == [SIMD3(2000, -4000, 1000)])
    }

    @Test func accRejectsCompressedFrame() {
        // Delta-compressed frames (frame-type bit 0x80) are not produced by the H10
        // and are not decoded; see the note in PmdCodec.parseAcc.
        let data = frame(type: 2, timestamp: 0, frameType: 0x81, content: [0xE8, 0x03, 0x30, 0xF8, 0xF4, 0x01])
        #expect(PmdCodec.parseAcc(data, sampleRate: 200, factor: 1.0) == nil)
    }

    @Test func accDecodesUncompressedFrame() {
        // Frame type 1 (the Polar H10's format): consecutive 16-bit signed LE x,y,z.
        let content: [UInt8] = [0xE8, 0x03, 0x30, 0xF8, 0xF4, 0x01,   // (1000, -2000, 500)
                                0xE9, 0x03, 0x2F, 0xF8, 0xF6, 0x01]   // (1001, -2001, 502)
        let data = frame(type: 2, timestamp: 3000, frameType: 0x01, content: content)
        let acc = PmdCodec.parseAcc(data, sampleRate: 200, factor: 1.0)!
        #expect(acc.samples == [SIMD3(1000, -2000, 500), SIMD3(1001, -2001, 502)])
        #expect(acc.timestampNs == 3000)
    }
}
