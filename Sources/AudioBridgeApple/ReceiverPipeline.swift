import AudioBridgeCore
import Foundation

/// Glues BridgeReceiver → StreamPlayer and recreates the player when the stream format changes.
/// Shared by the `abrecv` CLI and (later) the macOS app.
public final class ReceiverPipeline: @unchecked Sendable {
    public let receiver: BridgeReceiver
    public let stats = StreamStats()
    public let targetLatencyMs: Double
    public var onEvent: (@Sendable (String) -> Void)? {
        didSet { receiver.onEvent = onEvent }
    }

    private var player: StreamPlayer?   // receiver.queue only

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
            player?.stop()
            player = nil
        }
    }

    /// Current format and device latency, for display. Safe from any thread (hops to the receiver queue).
    public func currentFormat() -> (sampleRate: Double, channels: Int, outputLatency: TimeInterval)? {
        receiver.queue.sync {
            guard let player else { return nil }
            return (player.sampleRate, player.channels, player.outputLatency)
        }
    }

    private func handle(_ data: Data) {
        data.withUnsafeBytes { raw in
            let header: AudioPacketHeader
            do {
                header = try AudioPacketCodec.decodeHeader(raw)
            } catch {
                _ = stats.packetsMalformed.wrappingAdd(1, ordering: .relaxed)
                return
            }
            let rate = Double(header.sampleRate)
            let channels = Int(header.channels)
            if player == nil || player?.sampleRate != rate || player?.channels != channels {
                player?.stop()
                player = nil
                do {
                    let p = try StreamPlayer(sampleRate: rate, channels: channels, targetLatencyMs: targetLatencyMs, stats: stats)
                    p.onEvent = onEvent
                    try p.start()
                    player = p
                    onEvent?("stream format: \(header.sampleRate) Hz, \(channels) ch, Int16")
                } catch {
                    onEvent?("could not start playback: \(error)")
                    return
                }
            }
            player?.ingest(header: header, datagram: raw)
        }
    }
}
