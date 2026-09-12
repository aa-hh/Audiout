// Idle-session silence fill in shims/outputs.c, proven headless.
//
// A receiver closes its RTSP session when a bound session carries no audio (a
// Sonos Move was seen dropping after about 30 s). The system tap idles until an
// app plays, so nothing is written until then. The fill answers that: once the
// host has been quiet for 100 ms, the shim writes zeroed PCM straight into the
// two senders' write functions at exactly real time, for every stream that has a
// device with a live session in a connected or streaming state, and stops the
// moment the host writes again.
//
// SCOPE: BUILD + HEADLESS ONLY, like MultiStreamWriteRoutingTests. Real master
// sessions via the bridge seam, no sockets, no PTP, no event loop. The fill's
// production 8 ms timer cannot fire here, so these tests drive one cycle at a
// chosen time through `outputs_idle_fill_tick_for_test`.
//
// WHAT THE MASTER-SESSION ASSERTIONS DO AND DO NOT PROVE. The fill always writes
// whole 352-sample packets, and `airplay_write` drains its input buffer while it
// holds at least `rawbuf_size` bytes, which is exactly those 352 samples
// (airplay.c:1227-1228, 4374-4377). So a fill of N packets leaves
// `input_buffer_samples` exactly where it found it whether the sender accepted
// every packet or rejected all of them: no bridge accessor can witness a
// whole-packet write. What the assertions below do catch is a malformed fill
// packet, where the `samples` count and `bufsize` disagree and the sender's
// sample counter drifts away from its byte buffer.
//
// Nested under `SerializedEngineState`: this file mutates the process-global
// device registry and the fill's own per-stream table, so it must run one test
// at a time. Each test uses its own stream id and device ids for the same reason.

import Foundation
import Testing
@testable import AirPlayEngine
import CAirPlayEngine

extension SerializedEngineState {

    @Suite struct IdleSilenceFillTests {

        private static let rate: Int64 = 44100

        private func defaultQuality() -> media_quality {
            media_quality(sample_rate: 44100, bits_per_sample: 16, channels: 2, bit_rate: 0)
        }

        /// Interleaved S16LE stereo PCM of exactly `samples` sample-frames.
        private func pcm(samples: Int) -> Data {
            Data(repeating: 0xAB, count: samples * 2 /* channels */ * 2 /* bytes per sample */)
        }

        init() {
            airplay_test_master_sessions_reset()
            outputs_dispatcher_reset()
            drainRegistry()
        }

        // MARK: - helpers

        private func drainRegistry() {
            while let head = outputs_list() { outputs_device_remove(head) }
        }

        /// A registry device the fill will consider: it carries a session pointer
        /// (never dereferenced by the fill, only tested for NULL), a state, a
        /// stream id and a quality.
        private func makeDevice(
            id: UInt64,
            streamId: UInt32,
            state: output_device_state = OUTPUT_STATE_CONNECTED,
            quality: media_quality? = nil
        ) {
            let dev = UnsafeMutablePointer<output_device>.allocate(capacity: 1)
            dev.initialize(to: output_device())
            dev.pointee.id = id
            let canonical = outputs_device_add(dev, false)!
            canonical.pointee.advertised = 1
            canonical.pointee.state = state
            canonical.pointee.stream_id = streamId
            canonical.pointee.quality = quality ?? defaultQuality()
            canonical.pointee.session = UnsafeMutableRawPointer(bitPattern: 0xDEAD_BEEF)
        }

        /// The fill and the host share one clock: pts values are CLOCK_MONOTONIC
        /// rebased by the capture layer, and the quiet-period check stamps the same
        /// clock inside the shim's broadcast write.
        private func monotonicNow() -> timespec {
            var t = timespec()
            clock_gettime(CLOCK_MONOTONIC, &t)
            return t
        }

        private func nanos(_ t: timespec) -> Int64 {
            Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec)
        }

        private func ts(fromNanos ns: Int64) -> timespec {
            timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
        }

        /// The shim advances its end time by the whole samples it wrote, truncated
        /// to nanoseconds. The tests compute the same value rather than restating it
        /// as a literal.
        private func nanosForSamples(_ samples: Int64) -> Int64 {
            samples * 1_000_000_000 / Self.rate
        }

        /// Only the fill's device scan opens a stream's bookkeeping, so a stream
        /// with a live device needs one cycle before a host write has anywhere to
        /// record itself. That cycle owes nothing by construction.
        @discardableResult
        private func primeStream(at now: timespec) -> Int32 {
            outputs_idle_fill_tick_for_test(now)
        }

        /// One host write through the real Swift API, landing in the real C
        /// fan-out. Returns the stream's end time as the shim recorded it.
        private func hostWrite(engine: AirPlayEngine, streamId: UInt32, pts: timespec, samples: Int) async -> timespec {
            engine.write(pcm: pcm(samples: samples), streamId: streamId, pts: pts)
            try? await Task.sleep(nanoseconds: 20_000_000)
            return outputs_idle_fill_end_pts_for_test(streamId)
        }

        // MARK: - tests

        /// Catches a fill that talks over the host: any fill inside the 100 ms quiet
        /// period would double up on audio the host is already sending.
        @Test func noFillWhileHostWroteWithin100ms() async {
            var q = defaultQuality()
            #expect(airplay_test_master_session_make(31, &q, false) != nil)
            makeDevice(id: 0xF001, streamId: 31)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()

            let t0 = monotonicNow()
            #expect(primeStream(at: t0) == 0, "the cycle that opens a stream's bookkeeping owes nothing")
            _ = await hostWrite(engine: engine, streamId: 31, pts: t0, samples: 100)

            let written = outputs_idle_fill_tick_for_test(ts(fromNanos: nanos(t0) + 50_000_000))
            #expect(written == 0, "a stream the host wrote 50 ms ago must get no fill")
        }

        /// Catches a fill that writes the wrong amount: it must deliver exactly the
        /// whole packets elapsed time owes, staying one packet behind the present,
        /// and carry its end time forward across consecutive cycles.
        @Test func fillWritesSamplesOwedByElapsedTime() async {
            var q = defaultQuality()
            let ams = airplay_test_master_session_make(32, &q, false)
            #expect(ams != nil)
            makeDevice(id: 0xF002, streamId: 32)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()

            let t0 = monotonicNow()
            primeStream(at: t0)
            // 200 sample-frames stay under one packet, so the sender holds them and
            // the fill's own packets have a residue to disturb if they are malformed.
            let endAfterHost = await hostWrite(engine: engine, streamId: 32, pts: t0, samples: 200)
            #expect(airplay_test_master_session_input_buffer_samples(ams) == 200)

            // 108 ms of elapsed time, minus the one packet the fill stays behind,
            // owes 12 whole packets.
            let firstTick = nanos(endAfterHost) + 108_000_000
            let first = outputs_idle_fill_tick_for_test(ts(fromNanos: firstTick))
            #expect(first == 4224, "108 ms owes 12 packets of 352 samples")
            #expect(nanos(outputs_idle_fill_end_pts_for_test(32)) - nanos(endAfterHost) == nanosForSamples(4224),
                "the end time must advance by exactly what was written, or the fill drifts against real time")
            #expect(airplay_test_master_session_input_buffer_samples(ams) == 200,
                "the sender's sample count must still match its byte buffer: a fill packet whose samples and bufsize disagree would desynchronise them")

            // 8 ms later only one further packet is owed: the previous cycle already
            // delivered everything up to its own end time.
            let second = outputs_idle_fill_tick_for_test(ts(fromNanos: firstTick + 8_000_000))
            #expect(second == 352, "a second cycle 8 ms later owes exactly one packet")
        }

        /// Catches a fill that writes to a stream nothing is listening to: without
        /// the device check it would feed a stream whose devices are still starting
        /// up or have no session at all.
        @Test func fillSkipsStreamsWithoutConnectedDevice() async {
            var q = defaultQuality()
            #expect(airplay_test_master_session_make(33, &q, false) != nil)
            makeDevice(id: 0xF003, streamId: 33, state: OUTPUT_STATE_STARTUP)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()

            let t0 = monotonicNow()
            primeStream(at: t0)
            _ = await hostWrite(engine: engine, streamId: 33, pts: t0, samples: 100)

            let written = outputs_idle_fill_tick_for_test(ts(fromNanos: nanos(t0) + 108_000_000))
            #expect(written == 0, "a stream whose only device has not connected must get no fill")
        }

        /// Catches a fill that keeps running once audio returns: the host write must
        /// re-open the quiet period, so the very next cycle writes nothing.
        @Test func hostWriteStopsFillImmediately() async {
            var q = defaultQuality()
            let ams = airplay_test_master_session_make(34, &q, false)
            #expect(ams != nil)
            makeDevice(id: 0xF004, streamId: 34)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()

            let t0 = monotonicNow()
            primeStream(at: t0)
            let endAfterHost = await hostWrite(engine: engine, streamId: 34, pts: t0, samples: 200)

            #expect(outputs_idle_fill_tick_for_test(ts(fromNanos: nanos(endAfterHost) + 108_000_000)) > 0)
            #expect(airplay_test_master_session_input_buffer_samples(ams) == 200,
                "the fill's packets must leave the sender's sample count and byte buffer in step")

            let resumed = monotonicNow()
            _ = await hostWrite(engine: engine, streamId: 34, pts: resumed, samples: 200)

            let written = outputs_idle_fill_tick_for_test(ts(fromNanos: nanos(resumed) + 8_000_000))
            #expect(written == 0, "one host write must stop the fill on the next cycle")
        }

        /// Catches a fill that reads past the end of its own buffer: the silence it
        /// writes is one packet of 44100/16-bit/stereo and nothing else, so a device
        /// advertising another format would have the sender read 352 frames of that
        /// format out of a 1408-byte buffer.
        @Test func fillSkipsStreamAtNonDefaultQuality() async {
            var q = media_quality(sample_rate: 48000, bits_per_sample: 16, channels: 2, bit_rate: 0)
            #expect(airplay_test_master_session_make(35, &q, false) != nil)
            makeDevice(id: 0xF005, streamId: 35, quality: q)

            let t0 = monotonicNow()
            primeStream(at: t0)

            let written = outputs_idle_fill_tick_for_test(ts(fromNanos: nanos(t0) + 108_000_000))
            #expect(written == 0, "a stream whose device is not 44100/16/2 must get no fill")
        }

        /// Catches serving a stream on the strength of one device: every live device
        /// on a stream is fed from the same buffer, so one device on another format
        /// disqualifies the whole stream rather than just itself.
        @Test func fillSkipsStreamWhereAnyDeviceIsNonDefaultQuality() async {
            var q = defaultQuality()
            #expect(airplay_test_master_session_make(36, &q, false) != nil)
            makeDevice(id: 0xF006, streamId: 36)
            makeDevice(id: 0xF007, streamId: 36,
                       quality: media_quality(sample_rate: 48000, bits_per_sample: 16, channels: 2, bit_rate: 0))

            let t0 = monotonicNow()
            primeStream(at: t0)

            let written = outputs_idle_fill_tick_for_test(ts(fromNanos: nanos(t0) + 108_000_000))
            #expect(written == 0, "one device on another format must disqualify the whole stream")
        }

        /// Catches a flood after the engine stops and starts again: the clock keeps
        /// running while the engine is down, so bookkeeping left from the previous
        /// run would show the whole downtime as owed and fill at the per-cycle
        /// ceiling until it caught up.
        @Test func dispatcherResetForgetsStreamBookkeeping() async {
            var q = defaultQuality()
            #expect(airplay_test_master_session_make(37, &q, false) != nil)
            makeDevice(id: 0xF008, streamId: 37)

            let engine = AirPlayEngine()
            await engine.enterHeadlessTestMode()

            let t0 = monotonicNow()
            primeStream(at: t0)
            let endAfterHost = await hostWrite(engine: engine, streamId: 37, pts: t0, samples: 100)

            outputs_dispatcher_reset()
            #expect(nanos(outputs_idle_fill_end_pts_for_test(37)) == 0, "reset must forget the stream entirely")

            let written = outputs_idle_fill_tick_for_test(ts(fromNanos: nanos(endAfterHost) + 108_000_000))
            #expect(written == 0, "the first cycle after a reset re-seeds the stream and owes nothing")
        }
    }
}
