import AVFAudio
import Synchronization
import AudioBridgeCore
import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Plays one fixed-format PCM stream through AVAudioEngine to the system's *default* output device,
/// so it mixes with all other audio on that device (built-in speakers, AirPods, …).
///
/// Threads:
/// - `ingest` runs on the network queue (single producer).
/// - The AVAudioSourceNode render block runs on the Core Audio realtime thread (single consumer);
///   it never allocates, locks, or logs.
/// - Engine (re)construction runs on `controlQueue`.
public final class StreamPlayer: @unchecked Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let stats: StreamStats
    public var onEvent: (@Sendable (String) -> Void)?

    private let ring: SPSCAudioRingBuffer
    private var sequencer: StreamSequencer           // network queue only
    private let decodeScratch: UnsafeMutablePointer<Float>   // network queue only
    private let renderState: RenderState
    private let sourceNode: AVAudioSourceNode
    private let controlQueue = DispatchQueue(label: "audiobridge.player.control")
    private var engine: AVAudioEngine?               // controlQueue only
    private var configObserver: NSObjectProtocol?    // controlQueue only
    private var rebuildPending = false               // controlQueue only
    #if os(macOS)
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    #endif

    public init(sampleRate: Double, channels: Int, targetLatencyMs: Double = 60, stats: StreamStats = StreamStats()) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw NSError(domain: "AudioBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported format \(sampleRate) Hz × \(channels)"])
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.stats = stats
        let ring = SPSCAudioRingBuffer(minimumCapacityFrames: Int(sampleRate), channels: channels)  // ~1 s
        self.ring = ring
        self.sequencer = StreamSequencer(maxGapFrames: Int(sampleRate / 2))                        // bridge ≤ 0.5 s
        self.decodeScratch = .allocate(capacity: AudioPacketHeader.maxFramesPerPacket * AudioPacketHeader.maxChannels)
        let policy = PlayoutPolicy.milliseconds(target: targetLatencyMs, sampleRate: sampleRate)
        let state = RenderState(policy: policy, channels: channels, maxFrames: 8192)
        self.renderState = state
        self.sourceNode = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList -> OSStatus in
            state.render(ring: ring, stats: stats, isSilence: isSilence, frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
    }

    deinit {
        decodeScratch.deallocate()
    }

    // MARK: Lifecycle

    public func start() throws {
        var thrown: Error?
        controlQueue.sync {
            do { try buildEngine() } catch { thrown = error }
            #if os(macOS)
            installDefaultDeviceListener()
            #endif
        }
        if let thrown { throw thrown }
    }

    public func stop() {
        controlQueue.sync {
            #if os(macOS)
            removeDefaultDeviceListener()
            #endif
            tearDownEngine()
        }
    }

    /// Output presentation latency of the current device, in seconds (0 if not running).
    public var outputLatency: TimeInterval {
        controlQueue.sync { engine?.outputNode.presentationLatency ?? 0 }
    }

    // MARK: Network side

    /// Ingests one validated datagram whose format matches this player. Call from a single queue.
    public func ingest(header h: AudioPacketHeader, datagram raw: UnsafeRawBufferPointer) {
        _ = stats.packetsReceived.wrappingAdd(1, ordering: .relaxed)
        let transit = Int(truncatingIfNeeded: HostClock.nowNanos() &- h.hostTimeNanos)
        stats.lastTransitNanos.store(transit, ordering: .relaxed)
        if transit > stats.maxTransitNanos.load(ordering: .relaxed) {
            stats.maxTransitNanos.store(transit, ordering: .relaxed)
        }

        switch sequencer.accept(h) {
        case .drop:
            _ = stats.packetsDropped.wrappingAdd(1, ordering: .relaxed)
            return
        case .reset:
            _ = stats.streamResets.wrappingAdd(1, ordering: .relaxed)
            ring.requestDiscardAll()
        case .write(let silence):
            if silence > 0 {
                _ = stats.framesConcealed.wrappingAdd(silence, ordering: .relaxed)
                let written = ring.writeSilence(frames: silence)
                if written < silence { _ = stats.framesOverflowed.wrappingAdd(silence - written, ordering: .relaxed) }
            }
        }
        AudioPacketCodec.decodePayload(raw, header: h, into: decodeScratch)
        let frames = Int(h.frameCount)
        let written = ring.write(decodeScratch, frames: frames)
        if written < frames { _ = stats.framesOverflowed.wrappingAdd(frames - written, ordering: .relaxed) }
    }

    // MARK: Engine (controlQueue)

    private func buildEngine() throws {
        let engine = AVAudioEngine()   // binds to the current default output device
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: sourceNode.outputFormat(forBus: 0))
        engine.prepare()
        try engine.start()
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.scheduleRebuild(reason: "engine configuration changed")
        }
        onEvent?("engine started (output latency \(Int(engine.outputNode.presentationLatency * 1000)) ms)")
    }

    private func tearDownEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.stop()
            engine.detach(sourceNode)
        }
        engine = nil
    }

    /// Recreates the engine so it binds to the (possibly new) default output, e.g. after AirPods connect.
    /// Debounced because a device switch can fire several notifications.
    private func scheduleRebuild(reason: String) {
        controlQueue.async { [weak self] in
            guard let self, !self.rebuildPending, self.engine != nil else { return }
            self.rebuildPending = true
            self.controlQueue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self else { return }
                self.rebuildPending = false
                guard self.engine != nil else { return }
                self.onEvent?("rebuilding engine: \(reason)")
                self.tearDownEngine()
                self.renderState.requestReset()
                do { try self.buildEngine() } catch { self.onEvent?("engine restart failed: \(error)") }
            }
        }
    }

    #if os(macOS)
    private static func defaultOutputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func installDefaultDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRebuild(reason: "default output device changed")
        }
        var address = Self.defaultOutputAddress()
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        if status == noErr { defaultDeviceListener = block } else { onEvent?("default-device listener failed: \(status)") }
    }

    private func removeDefaultDeviceListener() {
        guard let block = defaultDeviceListener else { return }
        var address = Self.defaultOutputAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        defaultDeviceListener = nil
    }
    #endif
}

/// State touched only by the realtime render thread (plus one atomic reset flag).
private final class RenderState: @unchecked Sendable {
    private var controller: PlayoutController
    private let channels: Int
    private let maxFrames: Int
    private let scratch: UnsafeMutablePointer<Float>
    private let resetRequested = Atomic<Bool>(false)

    init(policy: PlayoutPolicy, channels: Int, maxFrames: Int) {
        self.controller = PlayoutController(policy: policy)
        self.channels = channels
        self.maxFrames = maxFrames
        self.scratch = .allocate(capacity: maxFrames * channels)
        self.scratch.initialize(repeating: 0, count: maxFrames * channels)
    }

    deinit { scratch.deallocate() }

    func requestReset() { resetRequested.store(true, ordering: .releasing) }

    func render(
        ring: SPSCAudioRingBuffer,
        stats: StreamStats,
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: Int,
        bufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let out = UnsafeMutableAudioBufferListPointer(bufferList)
        let n = Swift.min(frameCount, maxFrames)

        if ring.applyPendingDiscard() > 0 || resetRequested.exchange(false, ordering: .acquiring) {
            controller.reset()
        }

        let plan = controller.plan(available: ring.availableFrames, requested: n)
        if plan.skipBefore > 0 { ring.skip(frames: plan.skipBefore) }
        var produced = plan.readFrames > 0 ? ring.read(into: scratch, frames: plan.readFrames) : 0
        if plan.repeatLastFrame, produced > 0, produced < n {
            (scratch + produced * channels).update(from: scratch + (produced - 1) * channels, count: channels)
            produced += 1
        }
        if produced < n {
            (scratch + produced * channels).update(repeating: 0, count: (n - produced) * channels)
        }

        // Deinterleave into the engine's non-interleaved Float32 buffers.
        let outChannels = Swift.min(out.count, channels)
        for ch in 0..<out.count {
            guard let data = out[ch].mData else { continue }
            let dst = data.assumingMemoryBound(to: Float.self)
            if ch < outChannels {
                for i in 0..<n { dst[i] = scratch[i * channels + ch] }
            } else {
                dst.update(repeating: 0, count: n)
            }
            if frameCount > n { (dst + n).update(repeating: 0, count: frameCount - n) }
        }
        isSilence.pointee = ObjCBool(produced == 0)

        stats.lastFillFrames.store(ring.availableFrames, ordering: .relaxed)
        if plan.underrun { _ = stats.underruns.wrappingAdd(1, ordering: .relaxed) }
        if plan.resynced { _ = stats.resyncs.wrappingAdd(1, ordering: .relaxed) }
        switch plan.adjustment {
        case .none: break
        case .droppedFrame: _ = stats.driftDrops.wrappingAdd(1, ordering: .relaxed)
        case .repeatedFrame: _ = stats.driftRepeats.wrappingAdd(1, ordering: .relaxed)
        }
    }
}
