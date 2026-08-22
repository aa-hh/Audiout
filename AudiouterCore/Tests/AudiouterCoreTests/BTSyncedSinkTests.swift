import Foundation
import Testing
@testable import AudiouterCore

/// BT-SINK / BT-REFSEL / BT-DRIFT (PLAN-UNIVERSAL-SYNC Wave 2): the per-device
/// Bluetooth sink manager. Fully offline — no engine start, no real device, no
/// sound: the render core is driven directly with synthetic cycle times (the
/// `SyncedLocalSinkTests` harness style) and the drift corrector with a
/// synthetic pacing clock.
@Suite final class BTSyncedSinkTests: IsolatedSuite {

    // MARK: - Fixtures

    static let sampleRate = 48_000.0
    static let nsPerFrame = 1_000_000_000.0 / sampleRate
    static let anchorSec = 1_000
    static let anchorNanos = Int64(anchorSec) * 1_000_000_000

    /// Enqueue a strictly-increasing ramp starting at 1.0 (every real sample
    /// non-zero, so "first non-silence" is unambiguous) into the manager.
    @discardableResult
    static func enqueueRamp(into manager: BTSyncedSink, atSec sec: Int = anchorSec) -> [Float] {
        var ramp = [Float](repeating: 0, count: 30_000)
        for i in 0..<ramp.count { ramp[i] = Float(i + 1) }
        ramp.withUnsafeBufferPointer { buf in
            manager.enqueue(
                interleavedFrames: buf.baseAddress!, frameCount: ramp.count,
                pts: timespec(tv_sec: sec, tv_nsec: 0))
        }
        return ramp
    }

    /// Drive the sink's render core from `startNanos` in 512-frame cycles until
    /// the first non-zero sample appears; returns its monotonic instant and
    /// value. Pre-release cycles must be entirely silent and drain nothing.
    static func firstNonSilence(
        of sink: BTDeviceSink, startNanos: Int64, cycles: Int = 80
    ) -> (nanos: Int64, sample: Float)? {
        let framesPerCycle = 512
        var out = [Float](repeating: .nan, count: framesPerCycle)
        for cycle in 0..<cycles {
            let cycleStart = startNanos
                + Int64((Double(cycle * framesPerCycle) * nsPerFrame).rounded())
            let produced = out.withUnsafeMutableBufferPointer { ob in
                sink.renderInterleaved(
                    into: ob, frameCount: framesPerCycle, cycleStartMonotonicNanos: cycleStart)
            }
            if let idx = out.firstIndex(where: { $0 != 0 }) {
                #expect(out[0..<idx].allSatisfy { $0 == 0 },
                        "everything before the release point must be silence")
                return (cycleStart + Int64((Double(idx) * nsPerFrame).rounded()), out[idx])
            }
            #expect(!produced, "a fully-silent cycle must not have drained the ring")
        }
        return nil
    }

    // MARK: - BT-SINK: ramp+pts releases at the computed target, per device

    @Test func rampReleasesAtComputedTarget_perDevice() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 100 })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        // Offsets set BEFORE the sinks exist, so no rebuild races the anchor.
        manager.setOffsetMs(30, forDeviceUID: "dev-b")
        manager.setDevices([
            .init(deviceID: 0, uid: "dev-a"),
            .init(deviceID: 0, uid: "dev-b"),
        ])

        let ramp = Self.enqueueRamp(into: manager)

        // dev-a: no offset → releases at pts + 100 ms.
        // dev-b: 30 ms device offset → scheduled 30 ms EARLIER: pts + 70 ms.
        let expectations: [(uid: String, delayMs: Int64)] = [("dev-a", 100), ("dev-b", 70)]
        for (uid, delayMs) in expectations {
            let sink = try #require(manager.sinkForTesting(uid: uid))
            let hit = try #require(
                Self.firstNonSilence(of: sink, startNanos: Self.anchorNanos),
                "\(uid): audio was never released")
            let target = Self.anchorNanos + delayMs * 1_000_000
            #expect(abs(hit.nanos - target) <= Int64(Self.nsPerFrame.rounded()),
                    "\(uid): first non-silence must land within one frame of the target")
            #expect(hit.sample == ramp[0],
                    "\(uid): the delay line must release in order, starting at ramp[0]")
        }
    }

    // MARK: - BT-REFSEL: reference selection per group composition

    @Test func btOnlyComposition_usesFixedBufferReference() {
        let btOnly = BTGroupComposition(airPlayPresent: false, macLocalPresent: false)
        // 500 buffer − 120 device offset + 10 trim = 390 ms. The (absurd) 2000 ms
        // presentation value proves the AirPlay term is not consulted.
        #expect(BTReferenceTimeline.delayNanos(
            composition: btOnly, presentationDelayMs: 2_000, btOnlyBufferMs: 500,
            deviceOffsetMs: 120, trimMs: 10) == 390_000_000)
        // An offset larger than the buffer clamps at zero, never negative.
        #expect(BTReferenceTimeline.delayNanos(
            composition: btOnly, presentationDelayMs: 2_000, btOnlyBufferMs: 500,
            deviceOffsetMs: 600, trimMs: 0) == 0)
    }

    @Test func airPlayComposition_usesLivePresentationDelay() {
        let mixed = BTGroupComposition(airPlayPresent: true, macLocalPresent: false)
        // presentationDelay − offset + trim; the 500 ms BT-only buffer is ignored.
        let at250 = BTReferenceTimeline.delayNanos(
            composition: mixed, presentationDelayMs: 250, btOnlyBufferMs: 500,
            deviceOffsetMs: 40, trimMs: 5)
        #expect(at250 == 215_000_000)
        // A changed LIVE presentation value moves the delay by exactly the same
        // amount — the R4 guarantee that this is never a hardcoded constant.
        let at100 = BTReferenceTimeline.delayNanos(
            composition: mixed, presentationDelayMs: 100, btOnlyBufferMs: 500,
            deviceOffsetMs: 40, trimMs: 5)
        #expect(at250 - at100 == 150_000_000)
    }

    @Test func macPresence_neverChangesABTDelay() {
        // BT+AirPlay+Mac ≡ BT+AirPlay (AirPlay stays the single reference), and
        // BT+Mac ≡ BT-only (the Mac IS the reference clock either way).
        for airPlay in [true, false] {
            let withoutMac = BTReferenceTimeline.delayNanos(
                composition: BTGroupComposition(airPlayPresent: airPlay, macLocalPresent: false),
                presentationDelayMs: 250, btOnlyBufferMs: 500, deviceOffsetMs: 80, trimMs: -15)
            let withMac = BTReferenceTimeline.delayNanos(
                composition: BTGroupComposition(airPlayPresent: airPlay, macLocalPresent: true),
                presentationDelayMs: 250, btOnlyBufferMs: 500, deviceOffsetMs: 80, trimMs: -15)
            #expect(withoutMac == withMac, "airPlayPresent=\(airPlay)")
        }
    }

    @Test func compositionChange_reanchorsWithTheNewReference() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 100 })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
        let sink = try #require(manager.sinkForTesting(uid: "dev-a"))

        // Session 1 under the AirPlay reference: releases at pts + 100 ms.
        Self.enqueueRamp(into: manager, atSec: Self.anchorSec)
        let first = try #require(Self.firstNonSilence(of: sink, startNanos: Self.anchorNanos))
        #expect(abs(first.nanos - (Self.anchorNanos + 100_000_000))
                <= Int64(Self.nsPerFrame.rounded()))

        // The group loses its AirPlay member → BT-only reference. stop() drains
        // the queued rebuild synchronously, so the next enqueue re-anchors
        // deterministically under the new 500 ms fixed buffer.
        manager.setComposition(BTGroupComposition(airPlayPresent: false, macLocalPresent: false))
        manager.stop()

        let secondAnchorSec = Self.anchorSec + 1_000
        let secondAnchorNanos = Int64(secondAnchorSec) * 1_000_000_000
        Self.enqueueRamp(into: manager, atSec: secondAnchorSec)
        let second = try #require(Self.firstNonSilence(of: sink, startNanos: secondAnchorNanos))
        #expect(abs(second.nanos - (secondAnchorNanos + 500_000_000))
                <= Int64(Self.nsPerFrame.rounded()),
                "after the composition change the BT-only buffer must set the target")
    }

    // MARK: - BT-SYNC-DRAWER T3: usable trim range (D11)

    @Test func usableTrimRangeMs_btOnlyOffset400_flooredAtMinus100() {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 1_000 })
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
        manager.setComposition(BTGroupComposition(airPlayPresent: false, macLocalPresent: false))
        manager.setOffsetMs(400, forDeviceUID: "dev-a")

        // 500 ms BT-only buffer − 400 ms device offset = 100 ms of headroom
        // before the ≥ 0 clamp bites, so the floor sits at −100 (D11).
        #expect(manager.usableTrimRangeMs(forDeviceUID: "dev-a") == -100...BTSyncTrim.rangeMs)
    }

    @Test func usableTrimRangeMs_movesLiveWhenAirPlayJoins() {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 1_000 })
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
        manager.setComposition(BTGroupComposition(airPlayPresent: false, macLocalPresent: false))
        manager.setOffsetMs(400, forDeviceUID: "dev-a")
        #expect(manager.usableTrimRangeMs(forDeviceUID: "dev-a") == -100...BTSyncTrim.rangeMs)

        // AirPlay joins the group: the reference term swaps from the 500 ms
        // BT-only buffer to the live 1000 ms presentation delay (the T3
        // trap — this MUST be a live re-query against the SAME manager/sink,
        // never a value cached at some earlier read).
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        let range = manager.usableTrimRangeMs(forDeviceUID: "dev-a")
        // 1000 ms reference − 400 ms offset = 600 ms past the clamp, which
        // overshoots the ±500 ms trim range entirely, so the floor pins at
        // the full −500 — strictly lower than the BT-only −100 above.
        #expect(range == -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    }

    @Test func usableTrimRangeMs_unknownUID_yieldsFullRange() {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 1_000 })
        #expect(manager.usableTrimRangeMs(forDeviceUID: "never-seen")
                == -BTSyncTrim.rangeMs...BTSyncTrim.rangeMs)
    }

    // MARK: - BT-SYNC-DRAWER T2: live trim as a delay-line seek

    /// A mono delay line whose ring is big enough that nothing here ever wraps.
    static func makeDelayLine(crossfadeFrames: Int) -> BTDelayLine {
        BTDelayLine(
            minimumCapacityFrames: 1 << 14, channelCount: 1,
            crossfadeFrames: crossfadeFrames)
    }

    /// Fill a mono line with frames whose VALUE is their own index, so a
    /// read-back sample names the exact position it came from.
    static func writeIndexRamp(into line: BTDelayLine, frames count: Int) {
        let ramp = (0..<count).map(Float.init)
        ramp.withUnsafeBufferPointer {
            _ = line.write(interleavedFrames: $0.baseAddress!, frameCount: count)
        }
    }

    static func readMono(_ line: BTDelayLine, frames: Int) -> [Float] {
        var out: [Float] = []
        var frame: Float = 0
        for _ in 0..<frames {
            guard withUnsafeMutablePointer(to: &frame, { line.readFrame(into: $0) }) else { break }
            out.append(frame)
        }
        return out
    }

    static func maxStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    @Test func ringSeek_clampsToHistoryBehindAndUnreadDataAhead() {
        let ring = BTFrameRing(minimumCapacityFrames: 8, channelCount: 1)
        let frames = (0..<4).map(Float.init)
        frames.withUnsafeBufferPointer {
            _ = ring.write(interleavedFrames: $0.baseAddress!, frameCount: 4)
        }

        // Forward: four unread frames, so an over-ask stops exactly at the
        // write pointer and reports what it managed.
        #expect(ring.seek(byFrames: 10) == 4)
        #expect(ring.seek(byFrames: 1) == 0, "nothing left ahead of the read pointer")

        // Backward: with nothing unread the whole 8-frame capacity is history,
        // and once replayed there is none left to replay again.
        #expect(ring.seek(byFrames: -100) == -8)
        #expect(ring.seek(byFrames: -1) == 0)
    }

    @Test func shift_movesTheTimelineByExactlyTheRequestedFrames() {
        let crossfade = 8
        let line = Self.makeDelayLine(crossfadeFrames: crossfade)
        Self.writeIndexRamp(into: line, frames: 4_096)
        _ = Self.readMono(line, frames: 1_000)          // read position is now 1000

        line.requestShift(frames: -240)                  // a LONGER delay: replay history
        let after = Self.readMono(line, frames: crossfade + 4)

        // The first faded frame carries fade-out weight 1, so it is EXACTLY the
        // sample the un-shifted line would have produced — that is what makes
        // the splice continuous rather than merely quiet.
        #expect(after[0] == 1_000)
        // Past the fade the line is playing exactly 240 frames further back
        // than it would have been, and keeps advancing one frame per read.
        #expect(after[crossfade] == Float(1_000 - 240 + crossfade))
        #expect(after[crossfade + 3] == Float(1_000 - 240 + crossfade + 3))
    }

    @Test func twoShiftsBeforeOneRead_bothLand() {
        let crossfade = 8
        let line = Self.makeDelayLine(crossfadeFrames: crossfade)
        Self.writeIndexRamp(into: line, frames: 4_096)
        _ = Self.readMono(line, frames: 1_000)

        // A fast scrub hands over several deltas between two render cycles.
        // They must ACCUMULATE — an overwriting "pending shift" would drop the
        // first one and the ruler would stop tracking the audio.
        line.requestShift(frames: -100)
        line.requestShift(frames: -140)
        let after = Self.readMono(line, frames: crossfade + 1)
        #expect(after[crossfade] == Float(1_000 - 240 + crossfade))
    }

    /// The anti-click assertion: a raw seek splices two unrelated points of the
    /// waveform together and clicks; the crossfade is what stops it.
    @Test func shift_leavesNoStepBiggerThanTheSourceSignalsOwn() {
        let line = Self.makeDelayLine(crossfadeFrames: 240)   // 5 ms at 48 kHz
        let sine = Self.oneKilohertzSine(frames: 8_192)
        sine.withUnsafeBufferPointer {
            _ = line.write(interleavedFrames: $0.baseAddress!, frameCount: sine.count)
        }

        _ = Self.readMono(line, frames: 2_000)
        line.requestShift(frames: -777)          // deliberately not a whole period
        let out = Self.readMono(line, frames: 2_000)

        #expect(Self.maxStep(out) <= Self.maxStep(sine) * Self.spliceStepCeiling,
                "step \(Self.maxStep(out)) vs source \(Self.maxStep(sine))")
    }

    @Test func shiftArrivingMidCrossfade_staysContinuous() {
        let crossfade = 240
        let line = Self.makeDelayLine(crossfadeFrames: crossfade)
        let sine = Self.oneKilohertzSine(frames: 8_192)
        sine.withUnsafeBufferPointer {
            _ = line.write(interleavedFrames: $0.baseAddress!, frameCount: sine.count)
        }

        _ = Self.readMono(line, frames: 2_000)
        line.requestShift(frames: -777)
        let duringFade = Self.readMono(line, frames: crossfade / 3)   // well inside the fade
        line.requestShift(frames: -333)
        let after = Self.readMono(line, frames: 2_000)

        // Measured across the join too, so a half-applied first fade (the
        // failure mode: the old tail simply dropped when the second shift
        // arrived) shows up as a step at the boundary.
        #expect(Self.maxStep(duringFade + after) <= Self.maxStep(sine) * Self.spliceStepCeiling,
                "step \(Self.maxStep(duringFade + after)) vs source \(Self.maxStep(sine))")
    }

    /// THE SIGN PIN (plan trap 4.1). A larger trim means the device plays
    /// LATER, means a longer delay, means the read pointer moves BACKWARD.
    /// Inverting it compiles and still produces plausible-sounding audio, so
    /// this is asserted on the real manager→sink path, in frames.
    @Test func positiveTrim_seeksTheReadPointerBackward() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 100 })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
        Self.enqueueRamp(into: manager)
        let sink = try #require(manager.sinkForTesting(uid: "dev-a"))

        // The ramp's value is its position + 1, so the last sample of a cycle
        // reads off where the delay line has got to; the difference between two
        // consecutive cycles is how far the timeline moved.
        let framesPerCycle = 512
        var out = [Float](repeating: 0, count: framesPerCycle)
        var cycle = 0
        func renderCycleTail() -> Float {
            let start = Self.anchorNanos
                + Int64((Double(cycle * framesPerCycle) * Self.nsPerFrame).rounded())
            cycle += 1
            out.withUnsafeMutableBufferPointer {
                _ = sink.renderInterleaved(
                    into: $0, frameCount: framesPerCycle, cycleStartMonotonicNanos: start)
            }
            return out[framesPerCycle - 1]
        }

        while renderCycleTail() == 0 {}                   // pre-release cycles are silent
        let settled = renderCycleTail()
        #expect(renderCycleTail() - settled == Float(framesPerCycle),
                "an untrimmed cycle advances exactly one buffer")

        // +5 ms at 48 kHz = 240 frames of history replayed, so this cycle
        // advances 240 frames LESS than an untrimmed one.
        let beforeTrim = out[framesPerCycle - 1]
        manager.setTrimMs(5, forDeviceUID: "dev-a")
        #expect(renderCycleTail() - beforeTrim == Float(framesPerCycle - 240))

        // And back to zero moves it forward again by the same 240.
        let beforeUndo = out[framesPerCycle - 1]
        manager.setTrimMs(0, forDeviceUID: "dev-a")
        #expect(renderCycleTail() - beforeUndo == Float(framesPerCycle + 240))
    }

    @Test func preReleaseTrim_movesTheGateInsteadOfSeeking() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 100 })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
        let ramp = Self.enqueueRamp(into: manager)

        // Anchored by that enqueue but still holding silence. Nothing has been
        // emitted for a seek to stay continuous WITH, and seeking would throw
        // away pre-roll the device has not played yet — so the gate moves.
        manager.setTrimMs(50, forDeviceUID: "dev-a")

        let sink = try #require(manager.sinkForTesting(uid: "dev-a"))
        let hit = try #require(Self.firstNonSilence(of: sink, startNanos: Self.anchorNanos))
        #expect(abs(hit.nanos - (Self.anchorNanos + 150_000_000))
                <= Int64(Self.nsPerFrame.rounded()),
                "the release target must move from 100 ms to 100 + 50 ms")
        #expect(hit.sample == ramp[0],
                "and the delay line must still release from its very first frame")
    }

    /// An equal-power pair sums to at most √2 where the two sides correlate, so
    /// a spliced sinusoid can carry that much more slope than the source; the
    /// slow fade envelope adds a few percent on top. A real click is a step of
    /// order the full amplitude — some fifteen times a 1 kHz sine's own — so
    /// this ceiling still catches one with room to spare.
    static let spliceStepCeiling: Float = 1.5

    static func oneKilohertzSine(frames: Int) -> [Float] {
        (0..<frames).map { Float(sin(2 * Double.pi * 1_000 * Double($0) / sampleRate)) }
    }

    // MARK: - BT-DRIFT: pacing-clock corrector with the adaptive settle gate

    /// Synthetic pacing clock: advances a device sample counter at a commanded
    /// ppm skew from the host clock, with optional re-buffer jumps — the
    /// offline stand-in for `AudioDeviceGetCurrentTime` on a real speaker.
    private final class SyntheticPacingClock {
        private(set) var hostNanos: Int64 = 5_000_000_000
        private(set) var deviceSampleTime: Double = 0
        let nominalRate = BTSyncedSinkTests.sampleRate

        @discardableResult
        func tick(
            _ corrector: BTDriftCorrector, skewPpm: Double, jumpMs: Double = 0
        ) -> Double {
            hostNanos += 1_000_000_000   // the sink's 1 s sampling cadence
            deviceSampleTime += (1 + skewPpm * 1e-6) * nominalRate
                + jumpMs * 1e-3 * nominalRate
            return corrector.ingest(
                deviceSampleTime: deviceSampleTime, nominalRate: nominalRate,
                hostNanos: hostNanos)
        }
    }

    @Test func driftCorrector_convergesOnSteadyDrift() {
        let corrector = BTDriftCorrector()
        let clock = SyntheticPacingClock()

        // Settle window: a clean +80 ppm clock stays neutral until it has been
        // jump-free for 10 s, then trust is established.
        for _ in 0..<11 {
            clock.tick(corrector, skewPpm: 80)
            #expect(corrector.correctionPpm == 0, "neutral while settling")
        }
        clock.tick(corrector, skewPpm: 80)
        #expect(corrector.trust == .trusted, "10 jump-free seconds must earn trust")

        // Steady drift: the loop must converge to the negation of the skew (a
        // +80 ppm fast device clock is nulled by consuming input 80 ppm slower)
        // and hold the residual misalignment near zero.
        for _ in 0..<150 { clock.tick(corrector, skewPpm: 80) }
        #expect(abs(corrector.correctionPpm - (-80)) <= 3,
                "got \(corrector.correctionPpm) ppm")
        #expect(abs(corrector.latestPhaseErrorNanos) <= 500_000,
                "residual misalignment must be held below 0.5 ms, got \(corrector.latestPhaseErrorNanos)")
    }

    @Test func driftCorrector_noWindupDuringJumpySettling() {
        let corrector = BTDriftCorrector()
        let clock = SyntheticPacingClock()

        // Sonos-style warm-up: ±5–100 ms re-buffer jumps every third sample for
        // ~40 s (the live-measured shape). The gate must never trust the clock
        // and the correction must stay EXACTLY neutral — no wind-up at all.
        let jumps: [Double] = [40, -25, 100, -5, 60, -80, 12, -47, 90, -33, 8, -100, 55]
        for i in 0..<40 {
            let jump = (i % 3 == 0) ? jumps[(i / 3) % jumps.count] : 0
            clock.tick(corrector, skewPpm: 80, jumpMs: jump)
            #expect(corrector.trust == .settling, "sample \(i): still distrusted")
            #expect(corrector.correctionPpm == 0, "sample \(i): no wind-up")
        }

        // Jumps stop (the stack settled): trust arrives after 10 clean seconds.
        // AT the flip the correction is still exactly neutral — the jumpy
        // period left no integrator residue for the first trusted update.
        var cleanTicks = 0
        while corrector.trust == .settling, cleanTicks <= 12 {
            clock.tick(corrector, skewPpm: 80)
            cleanTicks += 1
        }
        #expect(corrector.trust == .trusted, "trust must arrive within ~10 clean samples")
        #expect(corrector.correctionPpm == 0, "trust must begin from neutral")

        // And the loop then converges cleanly, as if the chaos never happened.
        for _ in 0..<150 { clock.tick(corrector, skewPpm: 80) }
        #expect(abs(corrector.correctionPpm - (-80)) <= 3)
    }

    @Test func driftCorrector_reanchorsOnMidStreamJump() {
        let corrector = BTDriftCorrector()
        let clock = SyntheticPacingClock()

        // Establish trust and converge on a steady +50 ppm clock.
        for _ in 0..<12 { clock.tick(corrector, skewPpm: 50) }
        for _ in 0..<150 { clock.tick(corrector, skewPpm: 50) }
        #expect(corrector.trust == .trusted)
        let converged = corrector.correctionPpm
        #expect(abs(converged - (-50)) <= 3)

        // A mid-stream +30 ms re-buffer jump: distrust re-entered, the
        // correction HELD at last-good — the step is re-anchored away, never
        // chased with a rate excursion.
        clock.tick(corrector, skewPpm: 50, jumpMs: 30)
        #expect(corrector.trust == .settling)
        #expect(corrector.correctionPpm == converged, "held at last-good, not reset, not slewed")

        var maxDeviation = 0.0
        for _ in 0..<5 {   // still inside the re-settle window: held throughout
            clock.tick(corrector, skewPpm: 50)
            #expect(corrector.trust == .settling)
            maxDeviation = max(maxDeviation, abs(corrector.correctionPpm - (-50)))
        }
        for _ in 0..<106 {   // re-trust after 10 clean seconds, then keep running
            clock.tick(corrector, skewPpm: 50)
            maxDeviation = max(maxDeviation, abs(corrector.correctionPpm - (-50)))
        }
        #expect(corrector.trust == .trusted, "a jump-free stretch must re-earn trust")
        #expect(maxDeviation <= 10,
                "the 30 ms step must never be chased (that would need a ~500 ppm excursion); worst deviation \(maxDeviation)")
        #expect(abs(corrector.correctionPpm - (-50)) <= 3,
                "the rate estimate must survive the re-anchor")
    }
}

/// The one BT-SINK case that touches `Telemetry`'s process-global test sink, so
/// it lives under `SerializedSharedState` (cookbook §18) while the rest of the
/// suite above stays parallel. Named to keep `--filter BTSyncedSinkTests`
/// matching both.
extension SerializedSharedState {

    @Suite final class BTSyncedSinkTestsRebuildTelemetry: IsolatedSuite {

        private final class LineCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var lines: [String] = []
            func append(_ line: String) { lock.withLock { lines.append(line) } }
            func snapshot() -> [String] { lock.withLock { lines } }
        }

        /// D6 in one assertion: a trim must not rebuild the sink, because a
        /// rebuild re-arms the release gate and the device falls silent for the
        /// whole delay — about half a second per edit.
        @Test func trimChangeNeverRebuildsTheSink() {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let manager = BTSyncedSink(
                renderSampleRate: 48_000, channelCount: 1, presentationDelayMs: { 100 })
            manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
            manager.setTrimMs(12.5, forDeviceUID: "dev-a")
            manager.setTrimMs(-3, forDeviceUID: "dev-a")
            // Positive control: an OFFSET change IS a structural change and must
            // still rebuild — without it an empty log would prove nothing.
            manager.setOffsetMs(40, forDeviceUID: "dev-a")
            manager.stop()                    // drains the sink's async rebuild
            Telemetry._installTestSink(nil)   // flush barrier

            let lines = capture.snapshot()
            let rebuilds = lines.filter { $0.contains("\"evt\":\"bt_sink_rebuild\"") }
            #expect(rebuilds.count == 1, "lines: \(lines)")
            #expect(rebuilds.first?.contains("\"cause\":\"offset_change\"") == true,
                    "lines: \(lines)")
            #expect(!lines.contains { $0.contains("trim_change") }, "lines: \(lines)")
        }
    }

    // MARK: - Tone (per-device EQ)

    /// The manager remembers a device's tone in its own table, exactly as it
    /// does the gain: the usual case is the backend pushing an EQ in the same
    /// selection change that creates the sink, so a value set BEFORE the sink
    /// exists has to reach it — otherwise the speaker plays its first buffers
    /// unshaped.
    @Test func eqIsRememberedPerUIDBeforeTheSinkExists() throws {
        let manager = BTSyncedSink(
            renderSampleRate: 48_000, channelCount: 2, presentationDelayMs: { 100 })
        let eq = DeviceEQ(bassDB: 5, trebleDB: -4)
        manager.setEQ(eq, forDeviceUID: "dev-a")
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])

        let sink = try #require(manager.sinkForTesting(uid: "dev-a"))
        #expect(sink.eqForTesting == eq,
                "a sink created after the EQ was set must start already holding it")
    }
}

/// A non-optional witness does not satisfy an optional protocol requirement:
/// Swift takes the default implementation instead, silently, with no compile
/// error. `BTSyncedSink.anchoredDeviceUIDs()` was written that way, so the
/// backend always saw the "can't tell" default and the idle-speaker fix it
/// feeds never ran at all. These assertions go THROUGH the protocol, which is
/// the only place the mismatch is observable.
@Suite struct BTSyncedSinkProtocolWitnessTests {

    @Test func theRealSinkAnswersAnchoredThroughTheProtocol() {
        let sink: BTSyncedSinkControlling = BTSyncedSink(presentationDelayMs: { 250 })
        #expect(sink.anchoredDeviceUIDs() != nil,
                "the real sink must answer, not fall through to the protocol's can't-tell default")
    }

    @Test func aSinkWithNoDevicesAnchorsNothing() {
        let sink: BTSyncedSinkControlling = BTSyncedSink(presentationDelayMs: { 250 })
        #expect(sink.anchoredDeviceUIDs() == [])
    }
}
