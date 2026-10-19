// What the 16-stream engine cap costs in ALAC encoding, measured headlessly.
//
// One permanent engine stream per AirPlay speaker (roadmap 056) buys gapless EQ
// edits at the price of one ALAC encode per STREAM instead of one per distinct
// EQ curve. This file puts a number on that price: 16 streams, 5 s of audio,
// every packet encoded for real, reported as a real-time factor (wall seconds /
// audio seconds) on the `ENCODE_BENCH` line below.
//
// Why the encoder really runs here: headless mode executes `airplay_write`
// inline on the calling thread, and once a master session holds a whole packet
// (352 frames at 44100/16/2) `airplay_write` drains it through `packets_send`
// -> `alac_encode` (sender/airplay.c). No session is attached, so nothing is
// sent anywhere — but the encode, the RTP packet build and the commit all
// happen, which is the whole cost this measures.
//
// SCOPE: BUILD + HEADLESS ONLY. No event loop, no sockets, no PTP.
//
// Nested under `SerializedEngineState` (migration cookbook §22): this file
// mutates `shims/outputs.c`'s process-global device/callback registry and the
// sender's static master-session list, which is only safe one-test-at-a-time
// now that swift-testing runs tests concurrently in one process.

import Foundation
import Testing
@testable import AirPlayEngine
import CAirPlayEngine

extension SerializedEngineState {

    @Suite struct MultiStreamEncodeLoadTests {

        private static let streamCount: UInt32 = 16
        private static let samplesPerPacket = 352   // AIRPLAY_SAMPLES_PER_PACKET
        private static let sampleRate = 44_100
        /// 5 s of audio, rounded down to whole packets.
        private static let packetCount = 626

        private func defaultQuality() -> media_quality {
            media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
        }

        init() {
            airplay_test_master_sessions_reset()
            outputs_dispatcher_reset()
            drainRegistry()
        }

        private func drainRegistry() {
            while let head = outputs_list() { outputs_device_remove(head) }
        }

        /// One packet of interleaved S16LE stereo from a linear congruential
        /// generator. Deterministic, but broadband: ALAC on silence or on a pure
        /// tone compresses to almost nothing and would time a workload no real
        /// music produces.
        private static func programMaterial() -> Data {
            var state: UInt32 = 0x1234_5678
            var bytes = [UInt8]()
            bytes.reserveCapacity(samplesPerPacket * 2 /* channels */ * 2 /* bytes */)
            for _ in 0..<(samplesPerPacket * 2) {
                state = state &* 1_664_525 &+ 1_013_904_223
                let sample = Int16(truncatingIfNeeded: state >> 16).littleEndian
                withUnsafeBytes(of: sample) { bytes.append(contentsOf: $0) }
            }
            return Data(bytes)
        }

        /// The player timestamp for packet `index`: one packet of audio time per
        /// step, which is the cadence a real capture feed writes at.
        private static func pts(forPacket index: Int) -> timespec {
            let nanos = Int64(index) * Int64(samplesPerPacket) * 1_000_000_000 / Int64(sampleRate)
            return timespec(tv_sec: Int(nanos / 1_000_000_000), tv_nsec: Int(nanos % 1_000_000_000))
        }

        /// 16 streams, 5 s of audio, every packet ALAC-encoded, must encode
        /// faster than it plays. The defect this turns red: a 16-stream cap (one
        /// permanent stream per speaker) leaves 16 whole-system encodes per tick
        /// falling behind real time, which would starve every receiver at once.
        @Test func sixteenStreamsEncodeFasterThanRealTime() async {
            var q = defaultQuality()
            var sessions: [UnsafeMutableRawPointer] = []
            for streamId in 1...Self.streamCount {
                guard let ams = airplay_test_master_session_make(streamId, &q, false) else {
                    Issue.record("master session for stream \(streamId) must be created")
                    return
                }
                sessions.append(ams)
            }

            // Read the DELTA, never the absolute: rtp_session_new seeds `pos`
            // randomly, so a fresh session does not start at zero.
            let startPositions = sessions.map { airplay_test_master_session_rtp_pos($0) }

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()

            let packet = Self.programMaterial()
            let entries: [(pcm: Data, streamId: UInt32)] =
                (1...Self.streamCount).map { (pcm: packet, streamId: $0) }

            let elapsed = ContinuousClock().measure {
                for index in 0..<Self.packetCount {
                    engine.write(streams: entries, pts: Self.pts(forPacket: index))
                }
            }

            // `write` is nonisolated/fire-and-forget by contract even though
            // headless mode runs it inline, so settle briefly before reading the
            // C side back.
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms

            let expectedSamples = UInt32(Self.packetCount * Self.samplesPerPacket)
            for (index, ams) in sessions.enumerated() {
                let advanced = airplay_test_master_session_rtp_pos(ams) &- startPositions[index]
                #expect(advanced == expectedSamples,
                    "stream \(index + 1) must have encoded all \(Self.packetCount) packets — the RTP position only advances after a successful alac_encode, so a short count means the timing above measured something other than encoding")
            }

            let wallSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let audioSeconds = Double(Self.packetCount * Self.samplesPerPacket) / Double(Self.sampleRate)
            let rtf = wallSeconds / audioSeconds
            print(String(format: "ENCODE_BENCH streams=%u audio_s=%.1f wall_s=%.3f rtf=%.3f",
                         Self.streamCount, audioSeconds, wallSeconds, rtf))

            // A hang-stop, not a speed claim: the suite never asserts machine
            // speed. The 0.25 factor one stream per speaker is gated on is read
            // off the line above, not asserted here; 1.0 only says the encoder
            // is not pathologically slow.
            #expect(rtf <= 1.0,
                "16 streams must encode faster than they play; measured rtf \(rtf)")
        }
    }
}
