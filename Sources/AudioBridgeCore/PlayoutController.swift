/// Playout (jitter-buffer) policy executed once per render callback on the realtime thread.
///
/// - Starts in `.buffering` and outputs silence until `targetFrames` are queued.
/// - On underrun, plays what it has, pads with silence, and re-buffers.
/// - Compensates slow clock drift between sender and receiver by dropping or repeating a single
///   frame per callback when the smoothed fill level leaves `target ± driftBand`.
///   (Simple and allocation-free; an adaptive resampler can replace this later.)
/// - Hard-resyncs to `target` when the queue grows past `resyncAboveFrames` (e.g. after a stall burst).
public struct PlayoutPolicy: Equatable, Sendable {
    public var targetFrames: Int
    public var driftBandFrames: Int
    public var resyncAboveFrames: Int
    public var smoothing: Double

    public init(targetFrames: Int, driftBandFrames: Int, resyncAboveFrames: Int, smoothing: Double = 0.02) {
        precondition(targetFrames > 0 && driftBandFrames >= 0 && resyncAboveFrames > targetFrames)
        precondition(smoothing > 0 && smoothing <= 1)
        self.targetFrames = targetFrames
        self.driftBandFrames = driftBandFrames
        self.resyncAboveFrames = resyncAboveFrames
        self.smoothing = smoothing
    }

    public static func milliseconds(
        target: Double,
        driftBand: Double = 10,
        resyncAbove: Double = 250,
        sampleRate: Double
    ) -> PlayoutPolicy {
        let f = { (ms: Double) in Int((ms * sampleRate / 1000).rounded()) }
        return PlayoutPolicy(
            targetFrames: Swift.max(1, f(target)),
            driftBandFrames: f(driftBand),
            resyncAboveFrames: Swift.max(f(target) + 1, f(resyncAbove))
        )
    }
}

public struct RenderPlan: Equatable, Sendable {
    public enum Adjustment: Equatable, Sendable { case none, droppedFrame, repeatedFrame }

    /// Frames to discard from the ring before reading.
    public var skipBefore = 0
    /// Frames to read from the ring.
    public var readFrames = 0
    /// After reading, duplicate the last frame read once (drift compensation).
    public var repeatLastFrame = false
    /// The ring ran dry this callback.
    public var underrun = false
    /// The queue exceeded the resync threshold and was trimmed.
    public var resynced = false
    public var adjustment: Adjustment = .none

    public init() {}
    /// Frames that will be produced from audio data; the remainder of the request is silence.
    public var producedFrames: Int { readFrames + (repeatLastFrame ? 1 : 0) }
}

public struct PlayoutController: Sendable {
    public enum State: Equatable, Sendable { case buffering, playing }

    public let policy: PlayoutPolicy
    public private(set) var state: State = .buffering
    public private(set) var smoothedFill: Double = 0

    public init(policy: PlayoutPolicy) {
        self.policy = policy
    }

    public mutating func reset() {
        state = .buffering
        smoothedFill = 0
    }

    public mutating func plan(available: Int, requested: Int) -> RenderPlan {
        var plan = RenderPlan()
        guard requested > 0 else { return plan }
        var avail = Swift.max(0, available)

        if state == .buffering {
            guard avail >= policy.targetFrames, avail >= requested else { return plan }
            state = .playing
            smoothedFill = Double(avail)
        }

        if avail > policy.resyncAboveFrames {
            plan.skipBefore = avail - policy.targetFrames
            avail = policy.targetFrames
            plan.resynced = true
            smoothedFill = Double(avail)
        }

        if avail < requested {
            plan.readFrames = avail
            plan.underrun = true
            state = .buffering
            smoothedFill = 0
            return plan
        }

        smoothedFill += (Double(avail) - smoothedFill) * policy.smoothing
        let deviation = smoothedFill - Double(policy.targetFrames)
        let band = Double(policy.driftBandFrames)

        if deviation > band, avail - 1 >= requested {
            plan.skipBefore += 1
            plan.adjustment = .droppedFrame
            plan.readFrames = requested
        } else if deviation < -band, requested > 1 {
            plan.readFrames = requested - 1
            plan.repeatLastFrame = true
            plan.adjustment = .repeatedFrame
        } else {
            plan.readFrames = requested
        }
        return plan
    }
}
