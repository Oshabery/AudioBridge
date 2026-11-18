import Synchronization

/// Bounded single-producer / single-consumer ring buffer of interleaved Float frames.
///
/// - The producer (network queue) calls `write`, `writeSilence`, `requestDiscardAll`.
/// - The consumer (Core Audio realtime render thread) calls `read`, `skip`, `applyPendingDiscard`.
///
/// Consumer-side methods never allocate, lock, or log, so they are safe on a realtime thread.
/// Indices are monotonically increasing frame counters (Int is 64-bit; overflow is not a practical concern).
public final class SPSCAudioRingBuffer: @unchecked Sendable {
    public let channels: Int
    public let capacityFrames: Int

    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let discardEpoch = Atomic<Int>(0)
    private let discardMark = Atomic<Int>(0)
    private var consumerSeenDiscardEpoch = 0  // consumer-only

    /// Capacity is rounded up to a power of two.
    public init(minimumCapacityFrames: Int, channels: Int) {
        precondition(minimumCapacityFrames > 0 && channels > 0)
        var capacity = 1
        while capacity < minimumCapacityFrames { capacity <<= 1 }
        self.capacityFrames = capacity
        self.channels = channels
        self.mask = capacity - 1
        self.storage = .allocate(capacity: capacity * channels)
        self.storage.initialize(repeating: 0, count: capacity * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// Frames currently readable. Exact on the consumer thread, a lower bound elsewhere.
    public var availableFrames: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        return Swift.max(0, w - r)
    }

    // MARK: Producer

    /// Writes up to `frames` frames; returns the number written (less than `frames` on overflow).
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, frames: Int) -> Int {
        let n = reserve(frames)
        guard n > 0 else { return 0 }
        let w = writeIndex.load(ordering: .relaxed)
        forEachSegment(start: w, frames: n) { dst, srcOffsetFrames, count in
            (storage + dst).update(from: source + srcOffsetFrames * channels, count: count * channels)
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Writes `frames` frames of silence (used to fill gaps from lost packets).
    @discardableResult
    public func writeSilence(frames: Int) -> Int {
        let n = reserve(frames)
        guard n > 0 else { return 0 }
        let w = writeIndex.load(ordering: .relaxed)
        forEachSegment(start: w, frames: n) { dst, _, count in
            (storage + dst).update(repeating: 0, count: count * channels)
        }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Asks the consumer to drop everything written so far (e.g. a new stream session started).
    /// Frames written after this call are kept.
    public func requestDiscardAll() {
        discardMark.store(writeIndex.load(ordering: .relaxed), ordering: .relaxed)
        _ = discardEpoch.wrappingAdd(1, ordering: .releasing)
    }

    private func reserve(_ frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let free = capacityFrames - (w - r)
        return Swift.max(0, Swift.min(frames, free))
    }

    // MARK: Consumer (realtime safe)

    /// Applies a pending `requestDiscardAll`. Returns the number of frames discarded (0 if none pending).
    public func applyPendingDiscard() -> Int {
        let epoch = discardEpoch.load(ordering: .acquiring)
        guard epoch != consumerSeenDiscardEpoch else { return 0 }
        consumerSeenDiscardEpoch = epoch
        let mark = discardMark.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .relaxed)
        guard mark > r else { return 0 }
        readIndex.store(mark, ordering: .releasing)
        return mark - r
    }

    /// Reads up to `frames` frames into `destination`; returns the number read.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = Swift.max(0, Swift.min(frames, w - r))
        guard n > 0 else { return 0 }
        forEachSegment(start: r, frames: n) { src, dstOffsetFrames, count in
            (destination + dstOffsetFrames * channels).update(from: storage + src, count: count * channels)
        }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    /// Discards up to `frames` frames; returns the number discarded.
    @discardableResult
    public func skip(frames: Int) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = Swift.max(0, Swift.min(frames, w - r))
        guard n > 0 else { return 0 }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    // MARK: Helpers

    /// Calls `body(storageSampleOffset, linearFrameOffset, frameCount)` for the 1–2 contiguous segments.
    @inline(__always)
    private func forEachSegment(start: Int, frames: Int, _ body: (Int, Int, Int) -> Void) {
        let startSlot = start & mask
        let first = Swift.min(frames, capacityFrames - startSlot)
        body(startSlot * channels, 0, first)
        if first < frames {
            body(0, first, frames - first)
        }
    }
}
