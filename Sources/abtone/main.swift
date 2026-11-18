// abtone — Spike S2 test sender. Stands in for the future iOS extension so the Mac receiver,
// jitter buffer, mixing, and AirPods route changes can be verified before the iOS entitlement exists.
//
//   swift run abtone                         # browse for any receiver, send a 440/660 Hz tone
//   swift run abtone --file song.m4a         # stream an audio file (decoded to 48 kHz stereo)
//   swift run abtone --host 192.168.1.20 --port 50555 --loss 0.02 --jitter-ms 20 --seconds 60

import AVFAudio
import AudioBridgeApple
import AudioBridgeCore
import Foundation
import Network

func argument(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if CommandLine.arguments.contains("--help") {
    print("""
    usage: abtone [--name RECEIVER | --host HOST --port PORT] [--file PATH] [--seconds N]
                  [--packet-ms 5] [--loss 0.0-1.0] [--jitter-ms MS] [--gain 0.2]
    """)
    exit(0)
}

let sampleRate = 48_000.0
let channels = 2
let packetMs = argument("--packet-ms").flatMap(Double.init) ?? 5
let packetFrames = Int(sampleRate * packetMs / 1000)
let lossRate = argument("--loss").flatMap(Double.init) ?? 0
let jitterMs = argument("--jitter-ms").flatMap(Double.init) ?? 0
let duration = argument("--seconds").flatMap(Double.init)
let gain = Float(argument("--gain").flatMap(Double.init) ?? 0.2)
precondition(packetFrames >= 1 && packetFrames <= AudioPacketHeader.maxFramesPerPacket, "packet too large")

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

// MARK: Sources

/// Interleaved stereo Float samples at 48 kHz, looped.
func loadFile(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let inFormat = file.processingFormat
    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw NSError(domain: "abtone", code: 1)
    }
    try file.read(into: inBuffer)
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
        throw NSError(domain: "abtone", code: 2)
    }
    if inFormat.channelCount == 1 { converter.channelMap = [0, 0] }
    let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * sampleRate / inFormat.sampleRate) + 4096
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
        throw NSError(domain: "abtone", code: 3)
    }
    var supplied = false
    var conversionError: NSError?
    _ = converter.convert(to: outBuffer, error: &conversionError) { _, status in
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return inBuffer
    }
    if let conversionError { throw conversionError }
    let n = Int(outBuffer.frameLength)
    guard n > 0, let ch = outBuffer.floatChannelData else { throw NSError(domain: "abtone", code: 4) }
    var interleaved = [Float](repeating: 0, count: n * 2)
    for i in 0..<n {
        interleaved[2 * i] = ch[0][i]
        interleaved[2 * i + 1] = ch[1][i]
    }
    log("loaded \(path): \(String(format: "%.1f", Double(n) / sampleRate)) s")
    return interleaved
}

let fileSamples: [Float]? = try argument("--file").map(loadFile)

func fillPacket(_ dst: UnsafeMutablePointer<Float>, startFrame: UInt64) {
    if let fileSamples {
        let total = fileSamples.count / 2
        for i in 0..<packetFrames {
            let f = Int((startFrame + UInt64(i)) % UInt64(total))
            dst[2 * i] = fileSamples[2 * f] * (gain / 0.2)
            dst[2 * i + 1] = fileSamples[2 * f + 1] * (gain / 0.2)
        }
    } else {
        // Left 440 Hz, right 660 Hz, so channel order is audible.
        for i in 0..<packetFrames {
            let t = Double(startFrame + UInt64(i)) / sampleRate
            dst[2 * i] = gain * Float(sin(2 * .pi * 440 * t))
            dst[2 * i + 1] = gain * Float(sin(2 * .pi * 660 * t))
        }
    }
}

// MARK: Streaming

final class Streamer: @unchecked Sendable {
    let sender: BridgeSender
    let sessionID = UInt32.random(in: 1...UInt32.max)
    var sequence: UInt32 = 0
    var nextSampleTime: UInt64 = 0
    var startNanos: UInt64 = 0
    var sent = 0, skipped = 0
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioPacketHeader.maxFramesPerPacket * 2)
    var timer: DispatchSourceTimer?

    init(sender: BridgeSender) { self.sender = sender }

    func start() {
        startNanos = HostClock.nowNanos()
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: sender.queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = HostClock.nowNanos()
        let elapsed = Double(now - startNanos) / 1e9
        if let duration, elapsed >= duration {
            log("done: sent \(sent) packets, simulated loss \(skipped)")
            exit(0)
        }
        let dueFrame = UInt64(elapsed * sampleRate)
        // After a long stall (e.g. machine sleep), jump ahead instead of bursting; the receiver resyncs.
        if dueFrame > nextSampleTime + UInt64(sampleRate / 4) {
            nextSampleTime = dueFrame
        }
        while nextSampleTime <= dueFrame {
            fillPacket(scratch, startFrame: nextSampleTime)
            let header = AudioPacketHeader(
                channels: UInt8(channels),
                sampleRate: UInt32(sampleRate),
                sessionID: sessionID,
                sequence: sequence,
                frameCount: UInt16(packetFrames),
                sampleTime: nextSampleTime,
                hostTimeNanos: HostClock.nowNanos()
            )
            let bytes = AudioPacketCodec.encode(header: header, samples: scratch)
            sequence &+= 1
            nextSampleTime += UInt64(packetFrames)
            if lossRate > 0, Double.random(in: 0..<1) < lossRate {
                skipped += 1
                continue
            }
            sent += 1
            if jitterMs > 0 {
                let delay = Int(Double.random(in: 0...jitterMs) * 1000)
                sender.queue.asyncAfter(deadline: .now() + .microseconds(delay)) { [sender] in sender.send(bytes) }
            } else {
                sender.send(bytes)
            }
        }
    }
}

var streamer: Streamer?
var browser: NWBrowser?

func begin(_ endpoint: NWEndpoint) {
    log("sending \(Int(sampleRate)) Hz stereo Int16, \(packetFrames) frames/packet to \(endpoint)")
    let sender = BridgeSender(endpoint: endpoint)
    sender.onEvent = { log($0) }
    let s = Streamer(sender: sender)
    streamer = s
    sender.start { s.start() }
}

if let host = argument("--host"), let port = argument("--port").flatMap(UInt16.init).flatMap({ NWEndpoint.Port(rawValue: $0) }) {
    begin(.hostPort(host: NWEndpoint.Host(host), port: port))
} else {
    let name = argument("--name")
    log("browsing for \(BridgeService.type)\(name.map { " named \"\($0)\"" } ?? "") …")
    browser = BridgeSender.browse(named: name, timeout: 10) { endpoint in
        guard let endpoint else {
            log("no receiver found (is abrecv running? is Local Network access allowed?)")
            exit(1)
        }
        DispatchQueue.main.async { begin(endpoint) }
    }
}

dispatchMain()
