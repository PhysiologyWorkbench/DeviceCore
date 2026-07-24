import Foundation

/// One measurement type on the PMD (Polar Measurement Data) service. Only the two
/// streams this codec decodes are listed; the wire uses the full type table.
public enum PmdMeasurement: UInt8, Sendable {
    case ecg = 0
    case acc = 2
}

/// A settings field in a PMD control-point TLV (`[type][count][count×value]`,
/// little-endian). Only the fields used to start ECG/ACC (and read back the ACC
/// scaling `factor`) are listed. `byteWidth` is the per-value size on the wire.
public enum PmdSettingType: UInt8, Sendable {
    case sampleRate = 0
    case resolution = 1
    case range = 2
    case channels = 4
    case factor = 5

    var byteWidth: Int {
        switch self {
        case .sampleRate, .resolution, .range: return 2
        case .channels: return 1
        case .factor: return 4
        }
    }
}

/// A parsed PMD control-point response (`0xF0` frame): the echoed request opcode,
/// the measurement type, the status, and any settings payload.
public struct PmdControlResponse: Sendable, Equatable {
    public let opCode: UInt8
    public let measurementType: UInt8
    public let errorCode: UInt8
    public let parameters: [UInt8]
    public var isSuccess: Bool { errorCode == 0 }
}

/// One ECG frame: signed microvolt samples, the device timestamp of the *last*
/// sample (nanoseconds since 2000-01-01), and the configured sample rate. Per-sample
/// wall-clock reconstruction is a caller concern.
public struct PmdEcgFrame: Sendable, Equatable {
    public let samplesMicrovolts: [Int32]
    public let timestampNs: UInt64
    public let sampleRate: Double
}

/// One accelerometer frame: (x, y, z) samples in milli-g, the device timestamp of
/// the last sample, and the configured sample rate.
public struct PmdAccFrame: Sendable, Equatable {
    public let samples: [SIMD3<Int32>]
    public let timestampNs: UInt64
    public let sampleRate: Double
}

/// Decodes the PMD binary protocol: control-point command framing and responses,
/// the settings TLV, and the ECG/ACC data frames. Stateless and hardware-free —
/// this is the unit-test surface; the streaming path lives in `PmdReader`.
///
/// Ported from `polar-ble-sdk` (`BlePmdClient.swift`, `EcgData.swift`, `AccData.swift`,
/// `PmdSetting.swift`, `PmdControlPointResponse.swift`) under `/Users/pnr/Development/Polar`.
public enum PmdCodec {
    static let controlResponseCode: UInt8 = 0xF0
    private static let requestStart: UInt8 = 0x02
    private static let stop: UInt8 = 0x03
    private static let deltaFrameBit: UInt8 = 0x80

    // MARK: Control point

    /// A `REQUEST_MEASUREMENT_START` packet: `02 <type> <settings TLV>`.
    public static func startCommand(_ measurement: PmdMeasurement, settings: [UInt8]) -> Data {
        Data([requestStart, measurement.rawValue] + settings)
    }

    /// A `STOP_MEASUREMENT` packet: `03 <type>`.
    public static func stopCommand(_ measurement: PmdMeasurement) -> Data {
        Data([stop, measurement.rawValue])
    }

    /// One setting as its TLV triple (`[type][0x01][value LE]`), count fixed at one.
    public static func setting(_ type: PmdSettingType, _ value: UInt32) -> [UInt8] {
        var out: [UInt8] = [type.rawValue, 0x01]
        for i in 0..<type.byteWidth { out.append(UInt8((value >> (8 * i)) & 0xFF)) }
        return out
    }

    /// Parses a control-point response frame, or nil if it is not one.
    public static func parseControlResponse(_ data: Data) -> PmdControlResponse? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == controlResponseCode else { return nil }
        let parameters = bytes.count > 5 ? Array(bytes[5...]) : []
        return PmdControlResponse(opCode: bytes[1], measurementType: bytes[2],
                                  errorCode: bytes[3], parameters: parameters)
    }

    /// The ACC scaling `factor` from a start response's settings TLV (milli-g per
    /// LSB), or nil if absent.
    public static func factor(fromStartResponse parameters: [UInt8]) -> Float? {
        var i = 0
        while i + 2 <= parameters.count {
            guard let type = PmdSettingType(rawValue: parameters[i]) else { return nil }
            let count = Int(parameters[i + 1])
            i += 2
            let total = count * type.byteWidth
            guard i + total <= parameters.count else { return nil }
            if type == .factor, count >= 1 {
                let bits = UInt32(parameters[i]) | (UInt32(parameters[i + 1]) << 8)
                    | (UInt32(parameters[i + 2]) << 16) | (UInt32(parameters[i + 3]) << 24)
                return Float(bitPattern: bits)
            }
            i += total
        }
        return nil
    }

    // MARK: Data frames

    /// The measurement a data frame belongs to, from its header type byte — the
    /// demux key when several measurements stream on the shared data
    /// characteristic. Nil for anything that is not a known measurement's frame.
    public static func measurementType(of data: Data) -> PmdMeasurement? {
        data.first.flatMap { PmdMeasurement(rawValue: $0 & 0x3F) }
    }

    /// Decodes an ECG data frame (uncompressed type 0, 3-byte signed µV samples).
    /// Returns nil on a malformed or compressed frame.
    public static func parseEcg(_ data: Data, sampleRate: Double) -> PmdEcgFrame? {
        guard let header = header(data), header.type == PmdMeasurement.ecg.rawValue,
              !header.compressed, header.content.count % 3 == 0 else { return nil }
        var samples: [Int32] = []
        samples.reserveCapacity(header.content.count / 3)
        var i = 0
        while i + 3 <= header.content.count {
            samples.append(signed24(header.content[i], header.content[i + 1], header.content[i + 2]))
            i += 3
        }
        return PmdEcgFrame(samplesMicrovolts: samples, timestampNs: header.timestampNs, sampleRate: sampleRate)
    }

    /// Decodes an ACC data frame: the Polar H10's uncompressed frame type 1 —
    /// consecutive 16-bit signed LE x, y, z. `factor` (from the start response)
    /// scales to milli-g when the device reports one; the H10 reports none and its
    /// raw samples are already milli-g, so they pass through. Returns nil on a
    /// malformed frame.
    ///
    /// Delta-compressed ACC frames (frame-type bit `0x80`, the "Wolfi"
    /// reference-plus-packed-deltas format) are not produced by the H10 and are
    /// rejected here. To support a device that compresses ACC, port
    /// `parseDeltaFramesToSamples` from `polar-ble-sdk` (`BlePmdClient.swift`,
    /// `AccData.swift`) under `/Users/pnr/Development/Polar`.
    public static func parseAcc(_ data: Data, sampleRate: Double, factor: Float) -> PmdAccFrame? {
        guard let header = header(data), header.type == PmdMeasurement.acc.rawValue,
              !header.compressed, header.content.count % 6 == 0 else { return nil }
        var raw: [SIMD3<Int32>] = []
        raw.reserveCapacity(header.content.count / 6)
        var i = 0
        while i + 6 <= header.content.count {
            raw.append(SIMD3(signed(header.content, byteOffset: i, byteWidth: 2),
                             signed(header.content, byteOffset: i + 2, byteWidth: 2),
                             signed(header.content, byteOffset: i + 4, byteWidth: 2)))
            i += 6
        }
        guard factor != 1.0 else {
            return PmdAccFrame(samples: raw, timestampNs: header.timestampNs, sampleRate: sampleRate)
        }
        let samples = raw.map { SIMD3(Int32((Float($0.x) * factor).rounded()),
                                      Int32((Float($0.y) * factor).rounded()),
                                      Int32((Float($0.z) * factor).rounded())) }
        return PmdAccFrame(samples: samples, timestampNs: header.timestampNs, sampleRate: sampleRate)
    }

    // MARK: Frame internals

    private struct Header {
        let type: UInt8
        let timestampNs: UInt64
        let compressed: Bool
        let content: [UInt8]
    }

    /// The common PMD data header: type byte, 64-bit LE timestamp (ns since
    /// 2000-01-01, the last sample's time), frame-type byte, then the content.
    private static func header(_ data: Data) -> Header? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return nil }
        var ts: UInt64 = 0
        for i in 0..<8 { ts |= UInt64(bytes[1 + i]) << (8 * i) }
        return Header(type: bytes[0] & 0x3F, timestampNs: ts,
                      compressed: (bytes[9] & deltaFrameBit) != 0, content: Array(bytes[10...]))
    }

    /// A 24-bit signed little-endian sample sign-extended to `Int32`.
    private static func signed24(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Int32 {
        var v = UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16)
        if v & 0x80_0000 != 0 { v |= 0xFF00_0000 }
        return Int32(bitPattern: v)
    }

    /// A signed little-endian integer of `byteWidth` bytes, sign-extended to `Int32`.
    private static func signed(_ bytes: [UInt8], byteOffset: Int, byteWidth: Int) -> Int32 {
        var v: UInt32 = 0
        for i in 0..<byteWidth { v |= UInt32(bytes[byteOffset + i]) << (8 * i) }
        let signBit: UInt32 = 1 << (byteWidth * 8 - 1)
        if v & signBit != 0 { v |= ~UInt32(0) << (byteWidth * 8) }
        return Int32(bitPattern: v)
    }
}
