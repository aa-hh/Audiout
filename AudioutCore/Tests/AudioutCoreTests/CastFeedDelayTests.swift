// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design: this file carries NO GPL SPDX header. It is a
// clean-room Google Cast (CASTV2) implementation written from the public wire
// behaviour only; no code was copied from any GPL/LGPL project. Do not add a
// GPL header to this file and do not move GPL-derived code into it.

@testable import AudioutCore
import CastSender
import Foundation
import Network
import Testing

/// CAST-SYNC: the per-device feed delay that lets the room-delay controller
/// hold a Cast leg back to the room's common delay, and the observability the
/// controller reads it through.
///
/// Offline by construction — the ring and the fan-out are driven directly, and
/// the one manager test points at a port nothing listens on, so a session (and
/// its feed) exists without a receiver anywhere. Socket behaviour is
/// `CastOutputManagerTests`' job.
@Suite struct CastFeedDelayTests {

    // MARK: - Fixtures

    /// One block of audibly non-zero S16LE stereo, amplitude 1000 on both
    /// channels — the same figure `CastOutputManagerTests` feeds.
    private func tone(frames: Int) -> Data {
        var out = Data(count: frames * 4)
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in 0..<(frames * 2) { samples[sample] = 1000 }
        }
        return out
    }

    /// What ``CastFeedStats/peakDBFS`` reports for a block whose loudest sample
    /// is `amplitude` — the same arithmetic the ring runs, so it compares exact.
    private func dbfs(amplitude: Double) -> Double { 20 * log10(amplitude / 32768) }

    /// What an all-zero block reports.
    private let silentDBFS: Double = -120

    private func frameValues(_ pcm: Data) -> [Int16] {
        let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    // MARK: - The bypass is structural

    @Test func aFeedNeverAskedForADelayHasNoLine() {
        let ring = CastFeedRing()
        #expect(ring.test_hasDelayLine == false)
        // A zero ask builds the line, so a later small grow has captured
        // audio to replay, and a line at 0 is still the byte path.
        // Turns red if a zero request stops building the line, or a line at zero changes a byte.
        ring.setDelayMs(0)
        #expect(ring.test_hasDelayLine == true)

        let block = tone(frames: 882)
        ring.push(block)
        #expect(ring.render(frames: 882) == block)
        #expect(ring.stats == CastFeedStats(
            achievedDelayMs: 0, droppedBlocks: 0,
            underrunFrames: 0, feedResets: 0,
            peakDBFS: dbfs(amplitude: 1000), writes: 1))
    }

    // MARK: - Delaying by inserting zeros in FRONT of the ring

    /// The mechanism, and the reason it is free: the zeros go in ahead of the
    /// ring, so the ring's fill rate is exactly what it was and the server's
    /// wall-clock pacing is satisfied at the same rate. Five seconds of delay
    /// through a two-second ring is the proof — stuffing the zeros INTO the
    /// ring instead would have started dropping live audio past 2 s.
    @Test func fiveSecondsOfDelayCostsTheTwoSecondRingNothing() {
        let ring = CastFeedRing()
        ring.setDelayMs(5000)
        #expect(ring.test_hasDelayLine)

        // 6 s of tone, one 20 ms block at a time, each block drained straight
        // back out — the producer/consumer balance the real server runs at.
        var rendered: [Int16] = []
        for _ in 0..<300 {
            ring.push(tone(frames: 882))
            rendered += frameValues(ring.render(frames: 882))
        }

        let stats = ring.stats
        #expect(stats.droppedBlocks == 0)
        #expect(stats.underrunFrames == 0)
        #expect(stats.achievedDelayMs == 5000)
        // 5 s of inserted silence, then the audio, in step: nothing was lost in
        // between.
        #expect(rendered.count == 264_600)
        #expect(rendered[0..<220_500].allSatisfy { $0 == 0 })
        #expect(rendered[220_500...].allSatisfy { $0 == 1000 })
    }

    /// A share grow of up to `feedGateBandMs` replays audio the line already
    /// captured behind the crossfade; a larger one inserts its zeros.
    /// Turns red if `CastFeedRing` builds its line without the `feedGateBandMs` crossfaded-grow limit, so a 50 ms share grow inserts silence, or a 150 ms one stops inserting it.
    @Test func aShareGrowInsideTheGateBandReplaysAndALargerOneInsertsSilence() {
        let ring = CastFeedRing()
        ring.setDelayMs(1000)
        for _ in 0..<100 {
            ring.push(tone(frames: 882))
            _ = ring.render(frames: 882)
        }

        ring.setDelayMs(1050)
        var small: [Int16] = []
        for _ in 0..<10 {
            ring.push(tone(frames: 882))
            small += frameValues(ring.render(frames: 882))
        }
        #expect(!small.contains(0))

        ring.setDelayMs(1200)
        var large: [Int16] = []
        for _ in 0..<20 {
            ring.push(tone(frames: 882))
            large += frameValues(ring.render(frames: 882))
        }
        #expect(large.filter { $0 == 0 }.count == 6_615)
    }

    // MARK: - The reset()-on-GET reconciliation

    /// Every receiver GET drops the backlog, and a mid-session re-GET therefore
    /// throws away audio the delay line had ALREADY held back — the leg's
    /// achieved delay silently shortens by exactly that much. The line in front
    /// survives it; the discarded milliseconds and the reset count are what the
    /// room-delay controller re-settles on.
    @Test func aGETDiscardsDelayedAudioAndSaysHowMuch() {
        let ring = CastFeedRing()
        ring.setDelayMs(1000)
        // 2 s in, nothing out: the ring fills to its capacity behind a 1 s line.
        for _ in 0..<100 { ring.push(tone(frames: 882)) }
        #expect(ring.stats.achievedDelayMs == 3000)

        #expect(ring.reset() == 2000)
        #expect(ring.stats.feedResets == 1)
        #expect(ring.stats.achievedDelayMs == 1000, "the line in front is not what a GET resets")

        // Still emitting delayed audio rather than restarting into silence,
        // which is the visible half of the line having survived.
        ring.push(tone(frames: 882))
        #expect(ring.render(frames: 882) == tone(frames: 882))
    }

    // MARK: - Drops and underruns

    @Test func aBlockPastCapacityIsDroppedAndCounted() {
        let ring = CastFeedRing()
        for _ in 0..<101 { ring.push(tone(frames: 882)) }  // one block past 2 s
        #expect(ring.stats.droppedBlocks == 1)

        _ = ring.render(frames: 88_200)
        _ = ring.render(frames: 441)
        let stats = ring.stats
        #expect(stats.underrunFrames == 441, "what the consumer had to invent")
        #expect(stats.peakDBFS == silentDBFS, "an invented block is silence, and reads as silence")
    }

    /// 512 frames of a running ramp: frame k of the stream carries k, on both
    /// channels, so a lost, repeated or misplaced frame shows in the values.
    private static func ramp(block: Int) -> Data {
        var out = Data(count: 512 * 4)
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<512 {
                let value = Int16(truncatingIfNeeded: block * 512 + frame)
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
        }
        return out
    }

    /// A consumer holding the ring's lock for the producer's whole run costs
    /// it nothing, and a producer and consumer on two threads carry the ramp
    /// through about 3.7 wraps of the ring intact.
    /// Turns red if `push` takes the consumer lock again, or the counters mis-address a wrap.
    @Test func theProducerNeverWaitsOnTheConsumerLockAndCarriesTheRampAcrossWraps() {
        let ring = CastFeedRing()
        let firstRun = 160
        let done = DispatchSemaphore(value: 0)
        var finished = DispatchTimeoutResult.timedOut
        ring.test_withLockHeld {
            // Own threads, not the global queue: a loaded suite can leave a
            // global-queue block unstarted past the 5 s, which reads as a wait.
            Thread {
                for block in 0..<firstRun { ring.push(Self.ramp(block: block)) }
                done.signal()
            }.start()
            finished = done.wait(timeout: .now() + 5)
        }
        #expect(finished == .success)
        #expect(ring.stats.droppedBlocks == 0)
        #expect(ring.stats.writes == firstRun)
        let first = frameValues(ring.render(frames: firstRun * 512))
        #expect(first == (0..<(firstRun * 512)).map { Int16(truncatingIfNeeded: $0) })

        let secondRun = 640
        Thread {
            for block in firstRun..<(firstRun + secondRun) {
                while (ring.bufferedFrames ?? 0) > 44_100 { usleep(200) }
                ring.push(Self.ramp(block: block))
            }
        }.start()
        var second: [Int16] = []
        let deadline = Date().addingTimeInterval(10)
        while second.count < secondRun * 512, Date() < deadline {
            let n = ring.bufferedFrames ?? 0
            if n > 0 { second += frameValues(ring.render(frames: n)) }
        }
        #expect(second == ((firstRun * 512)..<((firstRun + secondRun) * 512)).map { Int16(truncatingIfNeeded: $0) })
        #expect(ring.stats.droppedBlocks == 0)
    }

    /// Turns red if `push` stops counting the block its failed
    /// `producerLock.try()` throws away, writes it anyway, or a later push
    /// stops landing.
    @Test func aPushRefusedByTheProducerLockIsCountedAndWritesNothing() {
        let ring = CastFeedRing()
        let block = tone(frames: 882)
        ring.test_withProducerLockHeld {
            DispatchQueue.global().sync { ring.push(block) }
        }
        #expect(ring.stats.droppedBlocks == 1)
        #expect(ring.stats.writes == 0)
        #expect((ring.bufferedFrames ?? 0) == 0)

        ring.push(block)
        #expect(ring.stats.droppedBlocks == 1)
        #expect(ring.stats.writes == 1)
    }

    // MARK: - Was there SOUND in what the server served?

    /// The counters cannot answer it. `underrunFrames` only sees frames the
    /// ring could not fill, so a leg that is fed and drained on time reads
    /// perfectly healthy whether it is carrying music or zeros. The peak is
    /// taken over the bytes that go out, and the arrival count says whether
    /// the capture tap is still handing anything over at all.
    @Test func servedAudioReportsItsPeakAndTheBlocksItArrivedIn() {
        let ring = CastFeedRing()
        for _ in 0..<3 { ring.push(tone(frames: 882)) }
        _ = ring.render(frames: 2646)

        let stats = ring.stats
        #expect(stats.peakDBFS == dbfs(amplitude: 1000))
        #expect(stats.writes == 3)
    }

    /// The case that made this worth adding: the receiver is playing, the ring
    /// is full, nothing underruns, and every byte served is zero because the
    /// feed gain is at 0. `underrunFrames` stays at 0 through all of it.
    @Test func aLegMutedByItsFeedGainReadsSilentWithNoUnderrun() {
        let ring = CastFeedRing()
        ring.setTargetGain(0)
        for _ in 0..<3 { ring.push(tone(frames: 882)) }
        // The first block carries the 882-frame ramp down from unity and is
        // therefore NOT silent; the one after it is the steady state the
        // receiver hears for the rest of the session.
        _ = ring.render(frames: 882)
        _ = ring.render(frames: 882)

        let stats = ring.stats
        #expect(stats.underrunFrames == 0, "the ring fed every frame it was asked for")
        #expect(stats.writes == 3, "and the producer kept arriving")
        #expect(stats.peakDBFS == silentDBFS, "yet the receiver got silence")
    }

    @Test func aFeedNobodyPushedToCountsNoArrivals() {
        #expect(CastFeedRing().stats.writes == 0)
    }

    // MARK: - The standing queue

    /// A fresh GET's ring refills before it plays, the render that ends the
    /// refill trims the backlog to the standing queue, and a short render
    /// starts the refill again.
    /// Turns red if `render` takes audio while refilling, trims the backlog to anything but the standing queue, or keeps taking after a short render.
    @Test func aStandingQueueRefillsBeforeItPlaysAndTrimsToItsDepth() {
        let ring = CastFeedRing(standingQueueMs: 80)
        ring.reset()
        ring.push(tone(frames: 882))
        // The prime: refilling, so it takes nothing and the block stays queued.
        #expect(ring.render(frames: 44_100).allSatisfy { $0 == 0 })
        #expect(ring.stats.underrunFrames == 44_100)
        #expect(ring.bufferedFrames == 882)

        // About 520 ms queued: the oldest audio goes, and exactly the standing
        // queue stays behind the block served.
        for _ in 0..<25 { ring.push(tone(frames: 882)) }
        #expect(frameValues(ring.render(frames: 882)).allSatisfy { $0 == 1000 })
        #expect(ring.timing.queuedMs == 80)

        // Asked for more than is queued: the real head, a silent tail, and the
        // next render refills instead of playing the one block that arrives.
        let short = frameValues(ring.render(frames: 4_410))
        #expect(short[..<3_528].allSatisfy { $0 == 1000 })
        #expect(short[3_528...].allSatisfy { $0 == 0 })
        ring.push(tone(frames: 882))
        #expect(ring.render(frames: 882).allSatisfy { $0 == 0 })
    }

    /// The live shape: a 512-frame tap block against an 882-frame pacing tick
    /// for 60 s, after 1 s of renders with nothing pushed, with one block lost
    /// every 10 s. Each loss shortens the standing queue instead of reaching
    /// the receiver as a gap.
    /// Turns red if `render` stops holding the standing queue: at `standingQueueMs` 0 each skipped push adds about 512 underrun frames.
    @Test func aStandingQueueAbsorbsALostBlockEveryTenSeconds() throws {
        let ring = CastFeedRing(standingQueueMs: 80)
        for _ in 0..<50 { _ = ring.render(frames: 882) }

        let block = tone(frames: 512)
        let end = 60 * 44_100
        var nextPush = 0
        var nextRender = 0
        var nextSkip = 10 * 44_100
        var underrunAtFirstAudio: Int?
        while nextPush < end || nextRender < end {
            if nextPush <= nextRender, nextPush < end {
                if nextPush >= nextSkip { nextSkip += 10 * 44_100 } else { ring.push(block) }
                nextPush += 512
            } else {
                let out = ring.render(frames: 882)
                if underrunAtFirstAudio == nil, out.contains(where: { $0 != 0 }) {
                    underrunAtFirstAudio = ring.stats.underrunFrames
                }
                nextRender += 882
            }
        }
        let atFirstAudio = try #require(underrunAtFirstAudio, "the refill never ended")
        #expect(ring.stats.underrunFrames == atFirstAudio)
    }

    // MARK: - The feed gate

    /// A closed gate holds the leg silent without touching its level, opening
    /// it fades in through the level ramp, and a GET while it is closed starts
    /// silent.
    /// Turns red if the gate stops zeroing the output, opens with a step instead of the ramp, or `reset()` restarts a closed leg at its level.
    @Test func aClosedFeedGateServesSilenceAndOpensThroughTheRamp() {
        let ring = CastFeedRing()
        ring.setTargetGain(0.5)
        ring.setFeedGate(open: false)
        for _ in 0..<3 { ring.push(tone(frames: 882)) }
        _ = ring.render(frames: 882)                    // the ramp down
        #expect(ring.render(frames: 882).allSatisfy { $0 == 0 })
        #expect(ring.gainTarget == 0.5, "the gate never rewrites the level")

        ring.setFeedGate(open: true)
        let opening = frameValues(ring.render(frames: 882))
        #expect(zip(opening, opening.dropFirst()).allSatisfy { $0 <= $1 }, "never decreasing")
        #expect(opening.last == 500)

        ring.setFeedGate(open: false)
        ring.reset()
        ring.push(tone(frames: 882))
        #expect(ring.render(frames: 882).allSatisfy { $0 == 0 })
    }

    // MARK: - Where the time goes

    private func ts(_ nanos: Int64) -> timespec {
        timespec(tv_sec: Int(nanos / 1_000_000_000), tv_nsec: Int(nanos % 1_000_000_000))
    }

    private func close(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= 0.01
    }

    /// Turns red if the ring stops stamping pushed blocks with their capture
    /// pts and push time, or if `reset()` stops realigning the stamp cursor to
    /// the first post-reset push.
    @Test func eachRenderedFrameReadsBackItsCaptureAndPushTimes() {
        let ms: Int64 = 1_000_000
        let t0: Int64 = 1_000 * ms
        let ring = CastFeedRing()
        ring.setDelayMs(1000)
        for k in 0..<60 {
            let pts = t0 + Int64(k) * 20 * ms
            ring.push(tone(frames: 882), pts: ts(pts), nowNanos: pts + 23 * ms)
        }

        _ = ring.render(frames: 441, nowNanos: t0 + 1207 * ms)
        var timing = ring.timing
        var last = timing.lastRender
        #expect(close(last?.ioprocToPushMs, 23))
        #expect(close(last?.delayLineMs, 1000))
        #expect(close(last?.ringWaitMs, 1184))
        #expect(close(last?.queueAheadMs, 0))
        #expect(close(last?.pacingPhaseMs, 1184))
        #expect(close(last?.ageMs, 2207))
        #expect(timing.renderedFramesSinceReset == 441)

        // Halfway into the first block: its frame 441 was captured 10 ms after
        // the block's pts and had 10 ms queued ahead of it.
        _ = ring.render(frames: 882, nowNanos: t0 + 1217 * ms)
        last = ring.timing.lastRender
        #expect(close(last?.ioprocToPushMs, 13))
        #expect(close(last?.queueAheadMs, 10))
        #expect(close(last?.ringWaitMs, 1194))

        ring.reset()
        let t1 = t0 + 5_000 * ms
        ring.push(tone(frames: 882), pts: ts(t1), nowNanos: t1 + 5 * ms)
        _ = ring.render(frames: 441, nowNanos: t1 + 30 * ms)
        timing = ring.timing
        last = timing.lastRender
        #expect(close(last?.ioprocToPushMs, 5))
        #expect(close(last?.ringWaitMs, 25))
        #expect(timing.renderedFramesSinceReset == 441)
        #expect(timing.delayLineMs == 1000)
    }

    /// Turns red if `CastFanOut.write` stops counting the writes its failed
    /// `lock.try()` throws away.
    @Test func aFanOutWriteRefusedByItsLockIsCounted() {
        let ring = CastFeedRing()
        let fanOut = CastFanOut()
        fanOut.setRings([ring])
        let block = tone(frames: 882)
        let zero = timespec(tv_sec: 0, tv_nsec: 0)
        fanOut.test_withLockHeld {
            DispatchQueue.global().sync { fanOut.write(pcm: block, pts: zero) }
        }
        #expect(fanOut.droppedWrites == 1)
        #expect(ring.stats.writes == 0)

        fanOut.write(pcm: block, pts: zero)
        #expect(fanOut.droppedWrites == 1)
        #expect(ring.stats.writes == 1)
    }

    // MARK: - The feed rate

    /// At 100 ppm a render of 882 frames reads 882.0882 captured frames, the
    /// fraction carried from one render to the next.
    /// Turns red if the rate stops reaching the render, the resampler restarts at each render (about 2,000 frames off), or a render rounds the rate to whole frames instead of carrying the fraction (90 frames off).
    @Test func aFeedRateConsumesItsShareOfCapturedFramesExactlyOverALongRun() {
        let ring = CastFeedRing()
        ring.setRatePpm(100)
        for _ in 0..<50 { ring.push(tone(frames: 882)) }
        for _ in 0..<1_000 {
            ring.push(tone(frames: 882))
            _ = ring.render(frames: 882)
        }
        #expect(ring.bufferedFrames == 44_010)
        #expect(ring.stats.underrunFrames == 0)
    }

    /// A rate of 0 is the plain copy whether or not it was ever set, and a GET
    /// takes a ring that once had a rate back to it.
    /// Turns red if a rate of 0 sends the feed through the resampler (its primed frames leave a 2-frame silent tail), or `reset()` leaves a ring that once had a rate on the resampler.
    @Test func aFeedRateOfZeroIsTheByteForBytePathAndAGETReturnsToIt() {
        let untouched = CastFeedRing()
        let zero = CastFeedRing()
        zero.setRatePpm(0)
        for ring in [untouched, zero] {
            for block in 0..<3 { ring.push(Self.ramp(block: block)) }
        }
        let first = Self.ramp(block: 0) + Self.ramp(block: 1) + Self.ramp(block: 2)
        #expect(untouched.render(frames: 1_536) == first)
        #expect(zero.render(frames: 1_536) == first)
        #expect(zero.stats.underrunFrames == 0)

        let regot = CastFeedRing()
        regot.setRatePpm(50)
        for block in 0..<3 { regot.push(Self.ramp(block: block)) }
        _ = regot.render(frames: 882)
        regot.reset()
        regot.setRatePpm(0)
        for block in 3..<6 { regot.push(Self.ramp(block: block)) }
        #expect(regot.render(frames: 1_536) == Self.ramp(block: 3) + Self.ramp(block: 4) + Self.ramp(block: 5))
    }

    /// A faster rate that would read the ring below its standing queue runs
    /// at 1 instead, so the queue holds and nothing underruns past the refill.
    /// Turns red if a rate above 1 is applied when it would take the ring below its standing queue (3,262 left), or the rate is ignored (3,528 left).
    @Test func aFasterFeedRateNeverTakesTheStandingQueue() {
        let ring = CastFeedRing(standingQueueMs: 80)
        ring.setRatePpm(100)
        ring.reset()
        for _ in 0..<3_005 {
            ring.push(tone(frames: 882))
            _ = ring.render(frames: 882)
        }
        #expect(ring.stats.underrunFrames == 3_528)
        #expect(ring.bufferedFrames == 3_526)
    }

    // MARK: - The controller's and the user's terms compose

    @Test func roomDelayAndUserOffsetComposeAndClampAtTheFloor() {
        let manager = CastOutputManager(
            serverBindsLoopbackOnly: true,
            streamHostOverride: "127.0.0.1",
            requestTimeout: 1,
            reconnectDelay: 60,
            playDeadline: 60)
        defer { manager.stopAll() }
        // Port 1 on loopback: nothing listens, so the session fails and stays —
        // which is all this needs, because the feed belongs to the session.
        manager.setDevices([CastDeviceRecord(
            id: "dev1", friendlyName: "Fake", model: nil,
            endpoint: .hostPort(host: "127.0.0.1", port: 1))])

        manager.setCastRoomDelayMs(2000, forDeviceID: "dev1")
        manager.setCastUserOffsetMs(-500, forDeviceID: "dev1")
        #expect(appliedDelayMs(manager) == 1500)

        // The trim exists for the receiver's own output stage and whatever TV
        // or soundbar chain follows it — tens of ms, not seconds. It can never
        // pull the leg below the floor: those frames are not captured yet.
        manager.setCastUserOffsetMs(-9000, forDeviceID: "dev1")
        #expect(appliedDelayMs(manager) == 0)

        #expect(manager.castFeedStats(forDevice: "nobody") == nil)

        // Turns red if `setCastRatePpm` stops reaching the session's own ring.
        manager.setCastRatePpm(40, forDeviceID: "dev1")
        #expect(manager.test_ring(forDevice: "dev1")?.test_ratePpm == 40)
    }

    /// One block through the fan-out so the line adopts the pending value, then
    /// the line's applied delay on its own, without the queued audio.
    /// Both reads are `queue`-synchronous, so they also flush the setters.
    private func appliedDelayMs(_ manager: CastOutputManager) -> Int? {
        _ = manager.castFeedStats(forDevice: "dev1")
        manager.feed.write(pcm: tone(frames: 882), pts: timespec(tv_sec: 0, tv_nsec: 0))
        return manager.test_ring(forDevice: "dev1")?.timing.delayLineMs
    }
}
