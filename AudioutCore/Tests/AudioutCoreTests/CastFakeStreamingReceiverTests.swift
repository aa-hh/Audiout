// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

import CastFakeReceiver
import CastSender
import Foundation
import Network
import Testing

/// The Cast Streaming spike over loopback: `CastMirrorSpikeRun` against
/// `FakeCastReceiver` (control) plus `FakeCastStreamingReceiver` (UDP).
/// Proves the OFFER/ANSWER exchange, the first-SR-before-RTP rule, NACK
/// retransmission, and that the SR mapping puts each frame at pts + target
/// delay. macOS 15 gate per test, as in `CastFakeReceiverLoopTests`.
@Suite struct CastFakeStreamingReceiverTests {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.withLock { stored = value } }
        var value: Value? { lock.withLock { stored } }
    }

    private struct Outcome {
        var result: Result<CastStreamingSession.Stats, Error>
        var lines: [String]
        var firstFramePts: UInt64?
    }

    /// Runs the whole spike against both fakes and returns once it finishes.
    @available(macOS 15, *)
    private func runSpike(
        streaming: FakeCastStreamingReceiver, holdSeconds: Double, targetDelayMs: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Outcome {
        let fake = FakeCastReceiver()
        fake.streaming = streaming
        defer { fake.stop(); streaming.stop() }
        let endpoint = Box<NWEndpoint>()
        let port = Box<UInt16>()
        fake.start { if case .success(let value) = $0 { endpoint.set(value) } }
        streaming.start { if case .success(let value) = $0 { port.set(value) } }
        SuiteWait.untilOnRunLoop("both fakes bound", timeout: 10, sourceLocation: sourceLocation) {
            endpoint.value != nil && port.value != nil
        }
        let target = try #require(endpoint.value, sourceLocation: sourceLocation)

        let lines = Lines()
        let run = CastMirrorSpikeRun(
            options: .init(endpoint: target, targetDelayMs: targetDelayMs, holdSeconds: holdSeconds,
                           probeSamples: [Float](repeating: 1, count: 4_800)),
            log: { lines.append($0) })
        let result = Box<Result<CastStreamingSession.Stats, Error>>()
        run.run { result.set($0) }
        SuiteWait.untilOnRunLoop("the run to finish", timeout: holdSeconds + 15, sourceLocation: sourceLocation) {
            result.value != nil
        }
        let outcome = try #require(result.value, sourceLocation: sourceLocation)
        return Outcome(result: outcome, lines: lines.all, firstFramePts: run.firstFramePtsNanos)
    }

    // Turns red if the OFFER goes unanswered, RTP leaves before the first
    // Sender Report, frames stop decrypting to Opus-sized packets, or the SR's
    // RTP position stops tracking pts so the median frame plays more than
    // 15 ms away from pts + 300 ms, or any frame more than 50 ms away.
    @Test func offerIsAnsweredAndFramesPlayOutAtTargetDelay() throws {
        guard #available(macOS 15, *) else { return }
        let streaming = FakeCastStreamingReceiver()
        let outcome = try runSpike(streaming: streaming, holdSeconds: 2, targetDelayMs: 300)
        _ = try outcome.result.get()
        #expect(outcome.lines.contains { $0.contains("answer_json=") })
        #expect(outcome.lines.contains { $0.contains("probe index=1 ") })
        #expect(streaming.senderReports.count >= 1)
        #expect(streaming.droppedBeforeFirstSR == 0)
        let frames = streaming.frames
        #expect(frames.count >= 150)
        let t0 = try #require(outcome.firstFramePts)
        var lateBy: [Double] = []
        for frame in frames {
            #expect(!frame.bytes.isEmpty && frame.bytes.count <= 1_276)
            let pts = Int64(t0) + Int64(frame.frameID) * 10_000_000
            let lateByMs = Double(Int64(frame.estimatedPlayoutNanos) - pts) / 1e6
            #expect(abs(lateByMs - 300) <= 50, "frame \(frame.frameID) plays \(lateByMs) ms after its pts")
            lateBy.append(lateByMs)
        }
        // The median absorbs the loopback and dispatch delay on single Sender Reports.
        let median = lateBy.sorted()[lateBy.count / 2]
        #expect(abs(median - 300) <= 15, "median frame plays \(median) ms after its pts")
    }

    // Turns red if the sender stops resending a NACKed frame, so a dropped
    // packet leaves a permanent hole below the receiver's checkpoint.
    @Test func nackedPacketsAreRetransmitted() throws {
        guard #available(macOS 15, *) else { return }
        let streaming = FakeCastStreamingReceiver()
        streaming.dropEveryNthPacket = 7
        let outcome = try runSpike(streaming: streaming, holdSeconds: 2, targetDelayMs: 300)
        let stats = try outcome.result.get()
        #expect(stats.packetsResent >= 1)
        #expect(streaming.retransmitsSeen >= 1)
        let checkpoint = streaming.checkpointFrameID
        #expect(checkpoint >= 100)
        let received = Set(streaming.frames.map(\.frameID))
        #expect((0...max(checkpoint, 0)).allSatisfy(received.contains))
    }

    // Turns red if a Sender Report's RTP timestamp stops advancing in step
    // with its NTP time, which is the mapping every playout time rests on.
    @Test func senderReportMapsMonotonicTimeToSamplePosition() throws {
        guard #available(macOS 15, *) else { return }
        let streaming = FakeCastStreamingReceiver()
        _ = try runSpike(streaming: streaming, holdSeconds: 1.5, targetDelayMs: 300).result.get()
        let reports = streaming.senderReports
        try #require(reports.count >= 3)
        let first = reports[reports.count - 2]
        let second = reports[reports.count - 1]
        let ntpSeconds = Double(Int64(second.ntp >> 32) - Int64(first.ntp >> 32))
            + (Double(second.ntp & 0xFFFF_FFFF) - Double(first.ntp & 0xFFFF_FFFF)) / 4_294_967_296
        let rtpSeconds = Double(Int32(bitPattern: second.rtpTimestamp &- first.rtpTimestamp)) / 48_000
        #expect(ntpSeconds > 0.3)
        #expect(abs(rtpSeconds - ntpSeconds) <= 0.002)
    }

    // Turns red if the fake answers `ok` to an OFFER that holds no audio stream.
    @Test func rejectsAnOfferWithoutAudio() {
        guard #available(macOS 15, *) else { return }
        let offer: [String: Any] = [
            "type": "OFFER", "seqNum": 4,
            "offer": ["castMode": "mirroring",
                      "supportedStreams": [["index": 1, "type": "video_source", "ssrc": 9]]] as [String: Any],
        ]
        let answer = FakeCastStreamingReceiver().answer(for: offer)
        #expect(answer["result"] as? String == "error")
        #expect(answer["seqNum"] as? Int == 4)
    }
}
