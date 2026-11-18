/// Decides what to do with each incoming packet based on its session and sample position.
/// Runs on the network (producer) side; pure value logic so it is unit-testable.
public struct StreamSequencer: Sendable {
    public enum Decision: Equatable, Sendable {
        /// New session, format change, or a gap too large to bridge: discard buffered audio, then write this packet.
        case reset
        /// Write `silenceBefore` frames of silence (lost packets), then this packet.
        case write(silenceBefore: Int)
        /// Packet is late, duplicated, or overlaps audio already written: ignore it.
        case drop
    }

    public let maxGapFrames: Int
    public private(set) var sessionID: UInt32?
    public private(set) var sampleRate: UInt32 = 0
    public private(set) var channels: UInt8 = 0
    public private(set) var nextSampleTime: UInt64 = 0

    public init(maxGapFrames: Int) {
        precondition(maxGapFrames >= 0)
        self.maxGapFrames = maxGapFrames
    }

    public mutating func accept(_ h: AudioPacketHeader) -> Decision {
        let end = h.sampleTime &+ UInt64(h.frameCount)
        guard let current = sessionID, current == h.sessionID,
              sampleRate == h.sampleRate, channels == h.channels
        else {
            sessionID = h.sessionID
            sampleRate = h.sampleRate
            channels = h.channels
            nextSampleTime = end
            return .reset
        }
        if h.sampleTime < nextSampleTime {
            return .drop
        }
        let gap = h.sampleTime - nextSampleTime
        if gap > UInt64(maxGapFrames) {
            nextSampleTime = end
            return .reset
        }
        nextSampleTime = end
        return .write(silenceBefore: Int(gap))
    }

    public mutating func forget() {
        sessionID = nil
    }
}
