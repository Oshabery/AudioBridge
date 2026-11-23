// abrecv — Spike S2 receiver. Advertises _audiobridge._udp and plays the stream on the Mac's
// default output device, mixed with everything else the Mac is playing.
//
//   swift run abrecv [--name "My Mac"] [--port 50555] [--target-ms 60]

import AudioBridgeApple
import Foundation

func argument(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if CommandLine.arguments.contains("--help") {
    print("usage: abrecv [--name NAME] [--port PORT] [--target-ms MS]")
    exit(0)
}

let name = argument("--name") ?? Host.current().localizedName ?? "AudioBridge Mac"
let port = argument("--port").flatMap(UInt16.init)
let targetMs = argument("--target-ms").flatMap(Double.init) ?? 60

func log(_ message: String) {
    let t = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    print("[\(t)] \(message)")
    fflush(stdout)
}

let pipeline = ReceiverPipeline(serviceName: name, port: port, targetLatencyMs: targetMs)
pipeline.onEvent = { log($0) }
do {
    try pipeline.start()
} catch {
    log("failed to start: \(error)")
    exit(1)
}
log("target jitter buffer \(Int(targetMs)) ms. Ctrl-C to quit.")

var previous = pipeline.stats.snapshot()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    let s = pipeline.stats.snapshot()
    defer { previous = s }
    guard let fmt = pipeline.status() else { return }
    let pps = s.packetsReceived - previous.packetsReceived
    let fillMs = Double(s.lastFillFrames) / fmt.sampleRate * 1000
    let outMs = fmt.outputLatency * 1000
    let transitMs = Double(s.lastTransitNanos) / 1e6
    let maxTransitMs = Double(s.maxTransitNanos) / 1e6
    log(String(
        format: "streams %d | pkts/s %d | buffer %.1f ms | device %.1f ms | transit(same-host) %.2f/%.2f ms | lost %d fr | late %d | underrun %d | resync %d | drift -%d/+%d | overflow %d fr | bad %d",
        fmt.activeStreams, pps, fillMs, outMs, transitMs, maxTransitMs,
        s.framesConcealed - previous.framesConcealed,
        s.packetsDropped - previous.packetsDropped,
        s.underruns - previous.underruns,
        s.resyncs - previous.resyncs,
        s.driftDrops - previous.driftDrops,
        s.driftRepeats - previous.driftRepeats,
        s.framesOverflowed - previous.framesOverflowed,
        s.packetsMalformed - previous.packetsMalformed
    ))
}
timer.resume()

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigint.setEventHandler {
    log("stopping")
    pipeline.stop()
    exit(0)
}
sigint.resume()

dispatchMain()
