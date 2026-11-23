import AudioBridgeCore
import Foundation

/// Glues BridgeReceiver → one StreamPlayer per sender stream (keyed by sessionID).
/// Every player plays to the Mac's default output, so all senders and the Mac's own audio
/// are mixed by the OS and reach the same device (e.g. AirPods).
/// Shared by the `abrecv` CLI and (later) the macOS app.
public final class ReceiverPipeline: @unchecked Sendable {
    public let receiver: BridgeReceiver
    public let stats = StreamStats()   // aggregate over all streams
    public let targetLatencyMs: Double
    public var onEvent: (@Sendable (String) -> Void)? {
        didSet { receiver.onEvent = onEvent }
    }

    private struct Entry {
        let player: StreamPlayer
        var lastSeenNanos: UInt64
    }

    private var players: [UInt32: Entry] = [:]   // receiver.queue only
    private var lastPruneNanos: UInt64 = 0      // receiver.queue only
    private static let streamIdleNanos: UInt64 = 3_000_000_000

    public init(serviceName: String, port: UInt16? = nil, targetLatencyMs: Double = 60) {
        self.receiver = BridgeReceiver(serviceName: serviceName, port: port)
        self.targetLatencyMs = targetLatencyMs
        receiver.onDatagram = { [weak self] data in self?.handle(data) }
    }

    public func start() throws {
        try receiver.start()
    }

    public func stop() {
        receiver.stop()
        receiver.queue.sync {
            players.values.forEach { $0.player.stop() }
            players.removeAll()
        }
    }

    public struct Status: Sendable {
        public var activeStreams: Int
        public var sampleRate: Double
        public var outputLatency: TimeInterval
    }

    /// For display. Safe from any thread (hops to the receiver queue).
    public func status() -> Status? {
        receiver.queue.sync {
            pruneIdleStreams(now: HostClock.nowNanos())
            guard let first = players.values.first?.player else { return nil }
            return Status(activeStreams: players.count, sampleRate: first.sampleRate, outputLatency: first.outputLatency)
        }
    }

    private func pruneIdleStreams(now: UInt64) {
        for (id, entry) in players where now &- entry.lastSeenNanos > Self.streamIdleNanos {
            entry.player.stop()
            players[id] = nil
            onEvent?("stream \(String(id, radix: 16)) ended (\(players.count) active)")
        }
    }

    private func handle(_ data: Data) {
        let now = HostClock.nowNanos()
        if now &- lastPruneNanos > 1_000_000_000 {
            lastPruneNanos = now
            pruneIdleStreams(now: now)
        }
        data.withUnsafeBytes { raw in
            let header: AudioPacketHeader
            do {
                header = try AudioPacketCodec.decodeHeader(raw)
            } catch {
                _ = stats.packetsMalformed.wrappingAdd(1, ordering: .relaxed)
                return
            }
            let id = header.sessionID
            let rate = Double(header.sampleRate)
            let channels = Int(header.channels)
            if let existing = players[id], existing.player.sampleRate == rate, existing.player.channels == channels {
                players[id]?.lastSeenNanos = now
            } else {
                players[id]?.player.stop()
                players[id] = nil
                do {
                    let p = try StreamPlayer(sampleRate: rate, channels: channels, targetLatencyMs: targetLatencyMs, stats: stats)
                    p.onEvent = onEvent
                    try p.start()
                    players[id] = Entry(player: p, lastSeenNanos: now)
                    onEvent?("stream \(String(id, radix: 16)) started: \(header.sampleRate) Hz, \(channels) ch (\(players.count) active)")
                } catch {
                    onEvent?("could not start playback: \(error)")
                    return
                }
            }
            players[id]?.player.ingest(header: header, datagram: raw)
        }
    }
}
