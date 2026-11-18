import XCTest
@testable import AudioBridgeCore

final class AudioPacketTests: XCTestCase {
    private func header(frames: UInt16 = 4, channels: UInt8 = 2, sampleTime: UInt64 = 0, session: UInt32 = 7) -> AudioPacketHeader {
        AudioPacketHeader(channels: channels, sampleRate: 48_000, sessionID: session, sequence: 3,
                          frameCount: frames, sampleTime: sampleTime, hostTimeNanos: 0x0102_0304_0506_0708)
    }

    func testRoundTrip() throws {
        let h = header()
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, 2, -2]   // includes out-of-range values
        let bytes = samples.withUnsafeBufferPointer { AudioPacketCodec.encode(header: h, samples: $0.baseAddress!) }
        XCTAssertEqual(bytes.count, AudioPacketHeader.size + 16)

        let decoded = try bytes.withUnsafeBytes { try AudioPacketCodec.decodeHeader($0) }
        XCTAssertEqual(decoded, h)

        var out = [Float](repeating: .nan, count: 8)
        bytes.withUnsafeBytes { raw in
            out.withUnsafeMutableBufferPointer { AudioPacketCodec.decodePayload(raw, header: decoded, into: $0.baseAddress!) }
        }
        let expected: [Float] = [0, 0.5, -0.5, 1, -1, 0.25, 1, -1]
        for (a, b) in zip(out, expected) { XCTAssertEqual(a, b, accuracy: 1.0 / 16384) }
    }

    func testHeaderIsBigEndian() {
        let h = header()
        let bytes = [Float](repeating: 0, count: 8).withUnsafeBufferPointer { AudioPacketCodec.encode(header: h, samples: $0.baseAddress!) }
        XCTAssertEqual(Array(bytes[0..<4]), [0x41, 0x42, 0x41, 0x31])
        XCTAssertEqual(Array(bytes[32..<40]), [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testRejectsMalformed() {
        let good = [Float](repeating: 0, count: 8).withUnsafeBufferPointer { AudioPacketCodec.encode(header: header(), samples: $0.baseAddress!) }

        func decode(_ b: [UInt8]) -> AudioPacketError? {
            do { _ = try b.withUnsafeBytes { try AudioPacketCodec.decodeHeader($0) }; return nil }
            catch { return error as? AudioPacketError }
        }
        XCTAssertNil(decode(good))
        XCTAssertEqual(decode(Array(good.prefix(10))), .tooShort)
        var b = good; b[0] = 0; XCTAssertEqual(decode(b), .badMagic)
        b = good; b[4] = 9; XCTAssertEqual(decode(b), .unsupportedVersion(9))
        b = good; b[5] = 9; XCTAssertEqual(decode(b), .unsupportedEncoding(9))
        b = good; b[6] = 0; XCTAssertEqual(decode(b), .badChannelCount(0))
        b = good; b[8] = 0xFF; XCTAssertNotNil(decode(b))  // absurd sample rate
        b = good; b[20] = 0; b[21] = 0; XCTAssertEqual(decode(b), .badFrameCount(0))
        XCTAssertEqual(decode(good + [0]), .payloadSizeMismatch(expected: 16, actual: 17))
    }

    func testFloatToInt16HandlesNonFinite() {
        XCTAssertEqual(AudioPacketCodec.floatToInt16(.nan), 0)
        XCTAssertEqual(AudioPacketCodec.floatToInt16(.infinity), 0)
        XCTAssertEqual(AudioPacketCodec.floatToInt16(1), 32767)
        XCTAssertEqual(AudioPacketCodec.floatToInt16(-1), -32767)
    }
}

final class RingBufferTests: XCTestCase {
    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(SPSCAudioRingBuffer(minimumCapacityFrames: 5, channels: 2).capacityFrames, 8)
        XCTAssertEqual(SPSCAudioRingBuffer(minimumCapacityFrames: 8, channels: 1).capacityFrames, 8)
    }

    func testWrapAroundPreservesOrder() {
        let ring = SPSCAudioRingBuffer(minimumCapacityFrames: 8, channels: 2)
        var out = [Float](repeating: 0, count: 16)
        var counter: Float = 0
        var expected: Float = 0
        for _ in 0..<20 {   // many passes over the 8-frame buffer
            let src: [Float] = (0..<10).map { _ in counter += 1; return counter }  // 5 frames
            XCTAssertEqual(src.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 5) }, 5)
            XCTAssertEqual(ring.availableFrames, 5)
            let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 8) }
            XCTAssertEqual(n, 5)
            for i in 0..<10 { expected += 1; XCTAssertEqual(out[i], expected) }
        }
    }

    func testOverflowWritesOnlyFreeSpace() {
        let ring = SPSCAudioRingBuffer(minimumCapacityFrames: 4, channels: 1)
        let src: [Float] = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(src.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 6) }, 4)
        XCTAssertEqual(ring.writeSilence(frames: 1), 0)
        var out = [Float](repeating: 0, count: 6)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 6) }, 4)
        XCTAssertEqual(Array(out.prefix(4)), [1, 2, 3, 4])
    }

    func testUnderflowReadsWhatIsAvailable() {
        let ring = SPSCAudioRingBuffer(minimumCapacityFrames: 8, channels: 1)
        var out = [Float](repeating: 9, count: 4)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 4) }, 0)
        XCTAssertEqual(ring.writeSilence(frames: 2), 2)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 4) }, 2)
        XCTAssertEqual(Array(out.prefix(2)), [0, 0])
    }

    func testSkip() {
        let ring = SPSCAudioRingBuffer(minimumCapacityFrames: 8, channels: 1)
        let src: [Float] = [1, 2, 3, 4]
        src.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, frames: 4) }
        XCTAssertEqual(ring.skip(frames: 3), 3)
        XCTAssertEqual(ring.skip(frames: 3), 1)
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testDiscardKeepsFramesWrittenAfterRequest() {
        let ring = SPSCAudioRingBuffer(minimumCapacityFrames: 16, channels: 1)
        let old: [Float] = [1, 2, 3]
        let new: [Float] = [7, 8]
        old.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, frames: 3) }
        ring.requestDiscardAll()
        new.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, frames: 2) }
        XCTAssertEqual(ring.applyPendingDiscard(), 3)
        XCTAssertEqual(ring.applyPendingDiscard(), 0)   // applied once
        var out = [Float](repeating: 0, count: 4)
        XCTAssertEqual(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 4) }, 2)
        XCTAssertEqual(Array(out.prefix(2)), [7, 8])
    }

    func testConcurrentProducerConsumerKeepsOrder() {
        let ring = SPSCAudioRingBuffer(minimumCapacityFrames: 256, channels: 1)
        let total = 200_000
        let producer = Thread {
            var next: Float = 0
            var chunk = [Float](repeating: 0, count: 37)
            var sent = 0
            while sent < total {
                let n = min(37, total - sent)
                for i in 0..<n { chunk[i] = next + Float(i) }
                let w = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: n) }
                next += Float(w)
                sent += w
            }
        }
        producer.start()
        var received = 0
        var expected: Float = 0
        var out = [Float](repeating: 0, count: 64)
        var ok = true
        let deadline = Date().addingTimeInterval(20)
        while received < total && Date() < deadline {
            let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, frames: 64) }
            for i in 0..<n where out[i] != expected + Float(i) { ok = false }
            expected += Float(n)
            received += n
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(received, total)
    }
}

final class StreamSequencerTests: XCTestCase {
    private func h(_ t: UInt64, frames: UInt16 = 240, session: UInt32 = 1, rate: UInt32 = 48_000, ch: UInt8 = 2) -> AudioPacketHeader {
        AudioPacketHeader(channels: ch, sampleRate: rate, sessionID: session, sequence: 0, frameCount: frames, sampleTime: t, hostTimeNanos: 0)
    }

    func testSequentialPackets() {
        var s = StreamSequencer(maxGapFrames: 24_000)
        XCTAssertEqual(s.accept(h(0)), .reset)
        XCTAssertEqual(s.accept(h(240)), .write(silenceBefore: 0))
        XCTAssertEqual(s.accept(h(480)), .write(silenceBefore: 0))
    }

    func testLossInsertsSilence() {
        var s = StreamSequencer(maxGapFrames: 24_000)
        _ = s.accept(h(0))
        XCTAssertEqual(s.accept(h(720)), .write(silenceBefore: 480))
    }

    func testLateAndDuplicatePacketsDropped() {
        var s = StreamSequencer(maxGapFrames: 24_000)
        _ = s.accept(h(0))
        _ = s.accept(h(480))       // 240 lost → concealed
        XCTAssertEqual(s.accept(h(240)), .drop)  // arrives late
        XCTAssertEqual(s.accept(h(480)), .drop)  // duplicate
        XCTAssertEqual(s.accept(h(720)), .write(silenceBefore: 0))
    }

    func testHugeGapResets() {
        var s = StreamSequencer(maxGapFrames: 1000)
        _ = s.accept(h(0))
        XCTAssertEqual(s.accept(h(240 + 1001)), .reset)
        XCTAssertEqual(s.accept(h(240 + 1001 + 240)), .write(silenceBefore: 0))
    }

    func testNewSessionOrFormatResets() {
        var s = StreamSequencer(maxGapFrames: 24_000)
        _ = s.accept(h(0))
        XCTAssertEqual(s.accept(h(0, session: 2)), .reset)
        XCTAssertEqual(s.accept(h(240, session: 2, rate: 44_100)), .reset)
        XCTAssertEqual(s.accept(h(480, session: 2, rate: 44_100, ch: 1)), .reset)
        s.forget()
        XCTAssertEqual(s.accept(h(720, session: 2, rate: 44_100, ch: 1)), .reset)
    }
}

final class PlayoutControllerTests: XCTestCase {
    private let policy = PlayoutPolicy(targetFrames: 1000, driftBandFrames: 100, resyncAboveFrames: 5000, smoothing: 1.0)

    func testBuffersUntilTarget() {
        var c = PlayoutController(policy: policy)
        let p = c.plan(available: 999, requested: 256)
        XCTAssertEqual(p.readFrames, 0)
        XCTAssertEqual(c.state, .buffering)
        let q = c.plan(available: 1000, requested: 256)
        XCTAssertEqual(q.readFrames, 256)
        XCTAssertEqual(c.state, .playing)
    }

    func testUnderrunPlaysRemainderThenRebuffers() {
        var c = PlayoutController(policy: policy)
        _ = c.plan(available: 1000, requested: 256)
        let p = c.plan(available: 100, requested: 256)
        XCTAssertTrue(p.underrun)
        XCTAssertEqual(p.readFrames, 100)
        XCTAssertEqual(c.state, .buffering)
        XCTAssertEqual(c.plan(available: 500, requested: 256).readFrames, 0)
    }

    func testDropsFrameWhenTooFull() {
        var c = PlayoutController(policy: policy)
        let p = c.plan(available: 1200, requested: 256)
        XCTAssertEqual(p.adjustment, .droppedFrame)
        XCTAssertEqual(p.skipBefore, 1)
        XCTAssertEqual(p.readFrames, 256)
    }

    func testRepeatsFrameWhenTooEmpty() {
        var c = PlayoutController(policy: policy)
        _ = c.plan(available: 1000, requested: 256)
        let p = c.plan(available: 800, requested: 256)
        XCTAssertEqual(p.adjustment, .repeatedFrame)
        XCTAssertEqual(p.readFrames, 255)
        XCTAssertTrue(p.repeatLastFrame)
        XCTAssertEqual(p.producedFrames, 256)
    }

    func testNoAdjustmentInsideBand() {
        var c = PlayoutController(policy: policy)
        _ = c.plan(available: 1000, requested: 256)
        let p = c.plan(available: 1050, requested: 256)
        XCTAssertEqual(p.adjustment, .none)
        XCTAssertEqual(p.skipBefore, 0)
    }

    func testResyncTrimsToTarget() {
        var c = PlayoutController(policy: policy)
        _ = c.plan(available: 1000, requested: 256)
        let p = c.plan(available: 9000, requested: 256)
        XCTAssertTrue(p.resynced)
        XCTAssertEqual(p.skipBefore, 8000)
        XCTAssertEqual(p.readFrames, 256)
        XCTAssertEqual(p.adjustment, .none)
    }

    func testMillisecondPolicy() {
        let p = PlayoutPolicy.milliseconds(target: 60, driftBand: 10, resyncAbove: 250, sampleRate: 48_000)
        XCTAssertEqual(p.targetFrames, 2880)
        XCTAssertEqual(p.driftBandFrames, 480)
        XCTAssertEqual(p.resyncAboveFrames, 12_000)
    }

    /// Simulates a sender clock 300 ppm fast: the fill level must stay bounded near target.
    func testDriftCompensationKeepsFillBounded() {
        let rate = 48_000.0
        var c = PlayoutController(policy: .milliseconds(target: 60, sampleRate: rate))
        var fill = 0.0
        let callback = 512
        let producedPerCallback = Double(callback) * 1.0003
        var minFill = Double.infinity, maxFill = 0.0
        for i in 0..<(60 * 94) {   // ~60 s of callbacks
            fill += producedPerCallback
            let p = c.plan(available: Int(fill), requested: callback)
            fill -= Double(p.skipBefore + p.readFrames)
            if i > 94 * 5 { minFill = min(minFill, fill); maxFill = max(maxFill, fill) }
        }
        XCTAssertGreaterThan(minFill, 2880 - 1500)
        XCTAssertLessThan(maxFill, 2880 + 1500)
    }
}
