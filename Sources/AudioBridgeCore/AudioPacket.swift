// Wire format for one datagram of audio (spike protocol "ABA1").
//
// Header: 40 bytes, big-endian.
//   0  magic        u32  0x41424131 ("ABA1")
//   4  version      u8   1
//   5  encoding     u8   1 = Int16 little-endian, interleaved
//   6  channels     u8   1...8
//   7  flags        u8   reserved (0)
//   8  sampleRate   u32  8_000...192_000
//  12  sessionID    u32  random per sender stream
//  16  sequence     u32  increments per packet (including packets the sender never sent)
//  20  frameCount   u16  1...maxFramesPerPacket
//  22  reserved     u16
//  24  sampleTime   u64  index of the first frame in this packet within the stream
//  32  hostTimeNs   u64  sender uptime clock when the packet was produced (only comparable on the same host)
// Payload: frameCount * channels * 2 bytes.
//
// Keep packets under a typical 1500-byte MTU: 48 kHz stereo Int16 at 5 ms = 240 frames = 960 bytes + 40.

public enum SampleEncoding: UInt8, Sendable {
    case int16LE = 1
}

public struct AudioPacketHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x4142_4131
    public static let currentVersion: UInt8 = 1
    public static let size = 40
    public static let maxFramesPerPacket = 1024
    public static let maxChannels = 8

    public var encoding: SampleEncoding
    public var channels: UInt8
    public var sampleRate: UInt32
    public var sessionID: UInt32
    public var sequence: UInt32
    public var frameCount: UInt16
    public var sampleTime: UInt64
    public var hostTimeNanos: UInt64

    public init(
        encoding: SampleEncoding = .int16LE,
        channels: UInt8,
        sampleRate: UInt32,
        sessionID: UInt32,
        sequence: UInt32,
        frameCount: UInt16,
        sampleTime: UInt64,
        hostTimeNanos: UInt64
    ) {
        self.encoding = encoding
        self.channels = channels
        self.sampleRate = sampleRate
        self.sessionID = sessionID
        self.sequence = sequence
        self.frameCount = frameCount
        self.sampleTime = sampleTime
        self.hostTimeNanos = hostTimeNanos
    }

    public var payloadByteCount: Int { Int(frameCount) * Int(channels) * 2 }
    public var sampleCount: Int { Int(frameCount) * Int(channels) }
}

public enum AudioPacketError: Error, Equatable, Sendable {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt8)
    case unsupportedEncoding(UInt8)
    case badChannelCount(UInt8)
    case badSampleRate(UInt32)
    case badFrameCount(UInt16)
    case payloadSizeMismatch(expected: Int, actual: Int)
}

public enum AudioPacketCodec {
    /// Encodes a header and interleaved Float samples (clamped to [-1, 1]) as an Int16 LE payload.
    /// `samples` must hold at least `header.sampleCount` values.
    public static func encode(header: AudioPacketHeader, samples: UnsafePointer<Float>) -> [UInt8] {
        let total = AudioPacketHeader.size + header.payloadByteCount
        var out = [UInt8](repeating: 0, count: total)
        out.withUnsafeMutableBytes { raw in
            writeHeader(header, into: raw)
            var offset = AudioPacketHeader.size
            for i in 0..<header.sampleCount {
                let v = floatToInt16(samples[i])
                let bits = UInt16(bitPattern: v)
                raw[offset] = UInt8(truncatingIfNeeded: bits)
                raw[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                offset += 2
            }
        }
        return out
    }

    public static func writeHeader(_ h: AudioPacketHeader, into raw: UnsafeMutableRawBufferPointer) {
        precondition(raw.count >= AudioPacketHeader.size)
        putBE32(AudioPacketHeader.magic, raw, 0)
        raw[4] = AudioPacketHeader.currentVersion
        raw[5] = h.encoding.rawValue
        raw[6] = h.channels
        raw[7] = 0
        putBE32(h.sampleRate, raw, 8)
        putBE32(h.sessionID, raw, 12)
        putBE32(h.sequence, raw, 16)
        putBE16(h.frameCount, raw, 20)
        putBE16(0, raw, 22)
        putBE64(h.sampleTime, raw, 24)
        putBE64(h.hostTimeNanos, raw, 32)
    }

    /// Parses and validates the header, including that the payload length matches exactly.
    public static func decodeHeader(_ raw: UnsafeRawBufferPointer) throws -> AudioPacketHeader {
        guard raw.count >= AudioPacketHeader.size else { throw AudioPacketError.tooShort }
        guard getBE32(raw, 0) == AudioPacketHeader.magic else { throw AudioPacketError.badMagic }
        guard raw[4] == AudioPacketHeader.currentVersion else { throw AudioPacketError.unsupportedVersion(raw[4]) }
        guard let encoding = SampleEncoding(rawValue: raw[5]) else { throw AudioPacketError.unsupportedEncoding(raw[5]) }
        let channels = raw[6]
        guard channels >= 1, Int(channels) <= AudioPacketHeader.maxChannels else {
            throw AudioPacketError.badChannelCount(channels)
        }
        let rate = getBE32(raw, 8)
        guard (8_000...192_000).contains(rate) else { throw AudioPacketError.badSampleRate(rate) }
        let frames = getBE16(raw, 20)
        guard frames >= 1, Int(frames) <= AudioPacketHeader.maxFramesPerPacket else {
            throw AudioPacketError.badFrameCount(frames)
        }
        let header = AudioPacketHeader(
            encoding: encoding,
            channels: channels,
            sampleRate: rate,
            sessionID: getBE32(raw, 12),
            sequence: getBE32(raw, 16),
            frameCount: frames,
            sampleTime: getBE64(raw, 24),
            hostTimeNanos: getBE64(raw, 32)
        )
        let actual = raw.count - AudioPacketHeader.size
        guard actual == header.payloadByteCount else {
            throw AudioPacketError.payloadSizeMismatch(expected: header.payloadByteCount, actual: actual)
        }
        return header
    }

    /// Converts the Int16 LE payload of a validated packet to Float samples in [-1, 1).
    /// `destination` must have room for `header.sampleCount` values.
    public static func decodePayload(
        _ raw: UnsafeRawBufferPointer,
        header: AudioPacketHeader,
        into destination: UnsafeMutablePointer<Float>
    ) {
        var offset = AudioPacketHeader.size
        for i in 0..<header.sampleCount {
            let bits = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
            destination[i] = Float(Int16(bitPattern: bits)) / 32768.0
            offset += 2
        }
    }

    @inline(__always)
    public static func floatToInt16(_ x: Float) -> Int16 {
        guard x.isFinite else { return 0 }
        let clamped = Swift.max(-1.0, Swift.min(1.0, x))
        return Int16((clamped * 32767.0).rounded())
    }

    // MARK: Byte helpers

    @inline(__always) static func putBE16(_ v: UInt16, _ r: UnsafeMutableRawBufferPointer, _ o: Int) {
        r[o] = UInt8(truncatingIfNeeded: v >> 8)
        r[o + 1] = UInt8(truncatingIfNeeded: v)
    }

    @inline(__always) static func putBE32(_ v: UInt32, _ r: UnsafeMutableRawBufferPointer, _ o: Int) {
        for i in 0..<4 { r[o + i] = UInt8(truncatingIfNeeded: v >> UInt32(24 - 8 * i)) }
    }

    @inline(__always) static func putBE64(_ v: UInt64, _ r: UnsafeMutableRawBufferPointer, _ o: Int) {
        for i in 0..<8 { r[o + i] = UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * i)) }
    }

    @inline(__always) static func getBE16(_ r: UnsafeRawBufferPointer, _ o: Int) -> UInt16 {
        (UInt16(r[o]) << 8) | UInt16(r[o + 1])
    }

    @inline(__always) static func getBE32(_ r: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(r[o + i]) }
        return v
    }

    @inline(__always) static func getBE64(_ r: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(r[o + i]) }
        return v
    }
}
