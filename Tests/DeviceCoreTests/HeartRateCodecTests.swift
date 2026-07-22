import Testing
import Foundation
@testable import DeviceCore

@Suite struct HeartRateCodecTests {
    private func parse(_ bytes: [UInt8]) -> HeartRate {
        HeartRateCodec.parse(Data(bytes))
    }

    /// 1024-unit RR value → ms, using the codec's rounding.
    private func rrMs(_ raw: Int) -> Int { Int((Double(raw) / 1024.0 * 1000.0).rounded()) }

    @Test func uint8HrNoExtras() {
        // flags 0x00: uint8 HR, no contact support, no energy, no RR.
        let hr = parse([0x00, 72])
        #expect(hr.bpm == 72)
        #expect(hr.rrIntervalsMs.isEmpty)
        #expect(hr.contact == nil)
    }

    @Test func uint16Hr() {
        // flags 0x01: uint16 LE HR = 300.
        let hr = parse([0x01, 0x2C, 0x01])
        #expect(hr.bpm == 300)
        #expect(hr.rrIntervalsMs.isEmpty)
    }

    @Test func contactSupportedDetectedAndNot() {
        // bit2 support, bits1-2 == 0b11 → detected.
        #expect(parse([0x06, 60]).contact == true)
        // bit2 support set, contact bit clear → not detected.
        #expect(parse([0x04, 60]).contact == false)
        // no support bit → nil regardless of the detected bit.
        #expect(parse([0x02, 60]).contact == nil)
    }

    @Test func singleAndMultipleRrIntervals() {
        // flags 0x10: uint8 HR, RR present. One RR of 1024 → 1000 ms.
        let one = parse([0x10, 65, 0x00, 0x04])
        #expect(one.rrIntervalsMs == [rrMs(1024)])
        #expect(one.rrIntervalsMs == [1000])

        // Two RR values: 1024 and 512.
        let two = parse([0x10, 65, 0x00, 0x04, 0x00, 0x02])
        #expect(two.rrIntervalsMs == [1000, rrMs(512)])
    }

    @Test func energyPresentSkippedBeforeRr() {
        // flags 0x18: uint8 HR, energy present (2 bytes), RR present.
        let hr = parse([0x18, 70, 0xFF, 0x00, 0x00, 0x04])
        #expect(hr.bpm == 70)
        #expect(hr.rrIntervalsMs == [1000])
    }

    @Test func uint16HrWithRr() {
        // flags 0x11: uint16 HR = 258, then one RR = 512.
        let hr = parse([0x11, 0x02, 0x01, 0x00, 0x02])
        #expect(hr.bpm == 258)
        #expect(hr.rrIntervalsMs == [rrMs(512)])
    }
}
