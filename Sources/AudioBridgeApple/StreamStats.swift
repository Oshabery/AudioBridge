import Dispatch
import Synchronization

/// Lock-free counters shared between the network queue, the render thread, and the UI/logging.
public final class StreamStats: Sendable {
    public let packetsReceived = Atomic<Int>(0)
    public let packetsDropped = Atomic<Int>(0)        // late / duplicate
    public let packetsMalformed = Atomic<Int>(0)
    public let framesConcealed = Atomic<Int>(0)       // silence inserted for lost packets
    public let framesOverflowed = Atomic<Int>(0)      // ring full on write
    public let streamResets = Atomic<Int>(0)
    public let underruns = Atomic<Int>(0)
    public let resyncs = Atomic<Int>(0)
    public let driftDrops = Atomic<Int>(0)
    public let driftRepeats = Atomic<Int>(0)
    public let lastFillFrames = Atomic<Int>(0)
    /// now - packet.hostTime at arrival. Only meaningful when sender and receiver run on the same Mac.
    public let lastTransitNanos = Atomic<Int>(0)
    public let maxTransitNanos = Atomic<Int>(0)

    public init() {}

    public struct Snapshot: Sendable, Equatable {
        public var packetsReceived = 0, packetsDropped = 0, packetsMalformed = 0
        public var framesConcealed = 0, framesOverflowed = 0, streamResets = 0
        public var underruns = 0, resyncs = 0, driftDrops = 0, driftRepeats = 0
        public var lastFillFrames = 0, lastTransitNanos = 0, maxTransitNanos = 0
    }

    public func snapshot() -> Snapshot {
        var s = Snapshot()
        s.packetsReceived = packetsReceived.load(ordering: .relaxed)
        s.packetsDropped = packetsDropped.load(ordering: .relaxed)
        s.packetsMalformed = packetsMalformed.load(ordering: .relaxed)
        s.framesConcealed = framesConcealed.load(ordering: .relaxed)
        s.framesOverflowed = framesOverflowed.load(ordering: .relaxed)
        s.streamResets = streamResets.load(ordering: .relaxed)
        s.underruns = underruns.load(ordering: .relaxed)
        s.resyncs = resyncs.load(ordering: .relaxed)
        s.driftDrops = driftDrops.load(ordering: .relaxed)
        s.driftRepeats = driftRepeats.load(ordering: .relaxed)
        s.lastFillFrames = lastFillFrames.load(ordering: .relaxed)
        s.lastTransitNanos = lastTransitNanos.load(ordering: .relaxed)
        s.maxTransitNanos = maxTransitNanos.exchange(0, ordering: .relaxed)
        return s
    }
}

public enum HostClock {
    /// Monotonic uptime in nanoseconds (same base on sender and receiver only within one machine).
    @inline(__always)
    public static func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
