import Foundation
import Testing
@testable import AudioutCore

/// BT-SINK / BT-REFSEL (PLAN-UNIVERSAL-SYNC Wave 2): the per-device Bluetooth
/// sink manager. Fully offline — no engine start, no real device, no sound: the
/// render core is driven directly with synthetic cycle times (the
/// `SyncedLocalSinkTests` harness style).
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

    /// Same ramp, delivered through the UID-scoped feed instead of the
    /// whole-system fan-out.
    @discardableResult
    static func enqueueRamp(
        into manager: BTSyncedSink, forDeviceUIDs uids: [String], atSec sec: Int = anchorSec
    ) -> [Float] {
        var ramp = [Float](repeating: 0, count: 30_000)
        for i in 0..<ramp.count { ramp[i] = Float(i + 1) }
        ramp.withUnsafeBufferPointer { buf in
            manager.enqueue(
                interleavedFrames: buf.baseAddress!, frameCount: ramp.count,
                pts: timespec(tv_sec: sec, tv_nsec: 0), forDeviceUIDs: uids)
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

    // MARK: - CAST-SYNC: the N-way room-delay reduction

    /// THE Phase (ii) invariant on the timing side (sync architecture brief
    /// §3): every composition that ships today returns today's reference when
    /// `castTermMs` is `nil`, because an absent operand makes the `max` the
    /// identity. Table-driven over all six shipped compositions, including the
    /// one that carries an explicit `castPresent: false`.
    @Test func roomDelay_withNoCastTerm_reducesToTodaysReference() {
        let S = 1_000, btOnly = 500
        let cases: [(name: String, composition: BTGroupComposition, expected: Int)] = [
            ("AirPlay only", BTGroupComposition(airPlayPresent: true, macLocalPresent: false), S),
            ("AirPlay + Mac", BTGroupComposition(airPlayPresent: true, macLocalPresent: true), S),
            ("AirPlay + BT", BTGroupComposition(airPlayPresent: true, macLocalPresent: false), S),
            ("BT only", BTGroupComposition(airPlayPresent: false, macLocalPresent: false), btOnly),
            ("BT + Mac", BTGroupComposition(airPlayPresent: false, macLocalPresent: true), btOnly),
            ("BT, castPresent false",
             BTGroupComposition(airPlayPresent: false, macLocalPresent: false, castPresent: false),
             btOnly),
        ]
        for c in cases {
            #expect(BTReferenceTimeline.roomDelayMs(
                composition: c.composition, presentationDelayMs: S,
                btOnlyBufferMs: btOnly, castTermMs: nil) == c.expected, "\(c.name)")
            // And the delay every BT device actually renders on is the same
            // number it is today — the reduction is not just in the helper.
            #expect(BTReferenceTimeline.delayNanos(
                composition: c.composition, presentationDelayMs: S, btOnlyBufferMs: btOnly,
                deviceOffsetMs: 120, trimMs: 10, castTermMs: nil)
                == BTReferenceTimeline.delayNanos(
                    composition: c.composition, presentationDelayMs: S, btOnlyBufferMs: btOnly,
                    deviceOffsetMs: 120, trimMs: 10), "\(c.name): delayNanos")
        }
    }

    /// The other half of the same rule: a Cast term only ever RAISES the room
    /// delay (delay-to-worst — no output's own latency can be shortened), and a
    /// Cast device selects the presentation reference exactly as AirPlay does.
    @Test func roomDelay_takesTheLongestActiveTerm() {
        let btOnly = BTGroupComposition(airPlayPresent: false, macLocalPresent: false)
        let withCast = BTGroupComposition(
            airPlayPresent: false, macLocalPresent: false, castPresent: true)

        #expect(BTReferenceTimeline.roomDelayMs(
            composition: btOnly, presentationDelayMs: 1_000,
            btOnlyBufferMs: 500, castTermMs: 5_500) == 5_500,
            "a Cast receiver 5.5 s behind live sets the room delay")
        #expect(BTReferenceTimeline.roomDelayMs(
            composition: withCast, presentationDelayMs: 5_500,
            btOnlyBufferMs: 500, castTermMs: nil) == 5_500,
            "a Cast device authors a presentation timeline, like AirPlay")
        #expect(BTReferenceTimeline.roomDelayMs(
            composition: withCast, presentationDelayMs: 6_000,
            btOnlyBufferMs: 500, castTermMs: 5_500) == 6_000,
            "and the room never shortens to the faster of the two")
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

    // MARK: - The release gate catches up on a late first cycle

    /// One 512-frame render cycle starting at `nanos`.
    static func renderCycle(
        _ sink: BTDeviceSink, at nanos: Int64, frames: Int = 512
    ) -> (produced: Bool, samples: [Float]) {
        var out = [Float](repeating: 0, count: frames)
        let produced = out.withUnsafeMutableBufferPointer {
            sink.renderInterleaved(
                into: $0, frameCount: frames, cycleStartMonotonicNanos: nanos)
        }
        return (produced, out)
    }

    /// A manager with one device, an AirPlay reference and `presentationDelayMs`
    /// of 100 — i.e. a 100 ms target — already fed one ramp.
    ///
    /// The caller MUST keep the manager alive for the whole test: its `deinit`
    /// stops every sink, which clears the anchor, and a sink whose anchor has
    /// gone renders silence forever after.
    static func anchoredSink(uid: String = "dev-a") throws -> (BTSyncedSink, BTDeviceSink, [Float]) {
        let manager = BTSyncedSink(
            renderSampleRate: sampleRate, channelCount: 1, presentationDelayMs: { 100 })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: uid)])
        let ramp = enqueueRamp(into: manager)
        return (manager, try #require(manager.sinkForTesting(uid: uid)), ramp)
    }

    /// THE DEFECT. The producer anchors on the first captured buffer without
    /// waiting for the engine, so a slow `engine.start()` (well over 500 ms on
    /// A2DP, and every rebuild pays it again) can put the first render cycle
    /// PAST the target. The ring is a plain FIFO: releasing its oldest frame
    /// there would make the real delay "however long the engine took", for the
    /// rest of the session.
    @Test func lateFirstCycle_catchesUpInsteadOfReleasingStaleAudio() throws {
        let (manager, sink, ramp) = try Self.anchoredSink()
        defer { manager.stop() }

        // 300 ms past the 100 ms target.
        let skipped = Int(0.300 * Self.sampleRate)
        let cycle = Self.renderCycle(sink, at: Self.anchorNanos + 400_000_000)

        #expect(cycle.produced)
        #expect(cycle.samples[0] == ramp[skipped],
                "the gate must release the frame that was DUE now, not the oldest one buffered")
        #expect(cycle.samples[1] == ramp[skipped + 1], "and keep running from there")
    }

    @Test func cycleBeforeTheTarget_stillWaitsAndSkipsNothing() throws {
        let (manager, sink, ramp) = try Self.anchoredSink()
        defer { manager.stop() }

        let early = Self.renderCycle(sink, at: Self.anchorNanos + 50_000_000)
        #expect(!early.produced, "half way to the target is still silence")
        #expect(early.samples.allSatisfy { $0 == 0 })

        // On time: nothing to catch up, so the ring still starts at frame 0.
        let onTime = Self.renderCycle(sink, at: Self.anchorNanos + 100_000_000)
        #expect(onTime.produced)
        #expect(onTime.samples[0] == ramp[0])
    }

    @Test func overshootBiggerThanTheRing_releasesWhatIsThereAndGoesOnFromFresh() throws {
        // 30_000 frames of ramp is 625 ms — less than this 1000 ms overshoot.
        let (manager, sink, _) = try Self.anchoredSink()
        defer { manager.stop() }

        let cycle = Self.renderCycle(sink, at: Self.anchorNanos + 1_100_000_000)
        #expect(!cycle.produced, "everything buffered was already overdue")
        #expect(cycle.samples.allSatisfy { $0 == 0 })

        // Empty, not stale: the next capture plays from its own first frame.
        let fresh = Self.enqueueRamp(into: manager, atSec: Self.anchorSec + 2)
        let next = Self.renderCycle(sink, at: Self.anchorNanos + 1_200_000_000)
        #expect(next.produced)
        #expect(next.samples[0] == fresh[0])
    }

    // MARK: - Part 3a: an alignment survives a lineup change

    /// A presentation delay the test can move between sessions — the stand-in
    /// for the reference timeline shifting when a speaker joins or leaves.
    private final class MovablePresentationDelay: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ value: Int) { self.value = value }
        var ms: Int {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Drive one session to release, move the reference, rebuild `rebuilds`
    /// times with `cause` (no enqueue in between, so only the first rebuild sees
    /// an anchored session), then re-anchor — and report the delay the new
    /// session actually gates on.
    private static func delayAfterRebuild(cause: String, rebuilds: Int = 1) throws -> Int64 {
        let presentation = MovablePresentationDelay(100)
        let manager = BTSyncedSink(
            renderSampleRate: sampleRate, channelCount: 1,
            presentationDelayMs: { presentation.ms })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
        let sink = try #require(manager.sinkForTesting(uid: "dev-a"))

        enqueueRamp(into: manager, atSec: anchorSec)
        _ = try #require(firstNonSilence(of: sink, startNanos: anchorNanos),
                         "the first session must reach its release gate")

        presentation.ms = 300
        for _ in 0..<rebuilds {
            sink.requestRebuild(cause: cause)
            sink.test_waitForPendingRebuild()
        }

        let secondAnchorSec = anchorSec + 1_000
        enqueueRamp(into: manager, atSec: secondAnchorSec)
        return sink.test_anchoredDelayNanos
    }

    @Test func configChangeRebuildCarriesTheSessionDelay() throws {
        #expect(try Self.delayAfterRebuild(cause: "config_change") == 100_000_000,
                "adding or removing a speaker must not move an alignment already made by ear")
    }

    /// Two lineup changes in a row with the music paused — no enqueue re-anchors
    /// between them, so the second rebuild finds `anchored` already false and
    /// must leave the first one's stash alone.
    @Test func backToBackConfigChangeRebuildsKeepCarryingTheSessionDelay() throws {
        #expect(try Self.delayAfterRebuild(cause: "config_change", rebuilds: 2) == 100_000_000,
                "a second lineup change before the next anchor must not drop the carry")
    }

    @Test func compositionChangeRebuildRederivesTheSessionDelay() throws {
        #expect(try Self.delayAfterRebuild(cause: "composition_change") == 300_000_000,
                "a genuinely new reference timeline must re-derive from the provider")
    }

    // MARK: - Per-app claim: fan-out exclusion and the UID-scoped feed

    /// A UID claimed for per-app routing must not double-receive the
    /// whole-system mix — the fan-out `enqueue` has to skip it while still
    /// reaching a sink nobody has claimed.
    @Test func fanOutEnqueue_skipsClaimedUID_reachesUnclaimedUID() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 100 })
        manager.setDevices([
            .init(deviceID: 0, uid: "dev-a"),
            .init(deviceID: 0, uid: "dev-b"),
        ])
        manager.setPerAppClaimedUIDs(["dev-b"])

        let sinkA = try #require(manager.sinkForTesting(uid: "dev-a"))
        let sinkB = try #require(manager.sinkForTesting(uid: "dev-b"))

        Self.enqueueRamp(into: manager)

        _ = try #require(Self.firstNonSilence(of: sinkA, startNanos: Self.anchorNanos),
                          "the whole-system fan-out must still reach an unclaimed UID")
        #expect(Self.firstNonSilence(of: sinkB, startNanos: Self.anchorNanos) == nil,
                "the whole-system fan-out must skip a per-app-claimed UID")
    }

    /// The UID-scoped feed is the per-app delivery path: it must reach only
    /// the devices named in its list, not every live sink.
    @Test func uidScopedEnqueue_reachesOnlyTheNamedUIDs() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 100 })
        manager.setDevices([
            .init(deviceID: 0, uid: "dev-a"),
            .init(deviceID: 0, uid: "dev-b"),
        ])

        let sinkA = try #require(manager.sinkForTesting(uid: "dev-a"))
        let sinkB = try #require(manager.sinkForTesting(uid: "dev-b"))

        Self.enqueueRamp(into: manager, forDeviceUIDs: ["dev-b"])

        _ = try #require(Self.firstNonSilence(of: sinkB, startNanos: Self.anchorNanos),
                          "the UID-scoped feed must reach the named device")
        #expect(Self.firstNonSilence(of: sinkA, startNanos: Self.anchorNanos) == nil,
                "the UID-scoped feed must not reach every live sink")
    }

    /// A UID the manager has no sink for is silently skipped — same posture
    /// as `setGain(_:forDeviceUID:)` — never a crash, and it must not land on
    /// an unrelated live sink instead.
    @Test func uidScopedEnqueue_unknownUIDIsSilentlySkipped() throws {
        let manager = BTSyncedSink(
            renderSampleRate: Self.sampleRate, channelCount: 1,
            presentationDelayMs: { 100 })
        manager.setDevices([.init(deviceID: 0, uid: "dev-a")])

        let sinkA = try #require(manager.sinkForTesting(uid: "dev-a"))

        Self.enqueueRamp(into: manager, forDeviceUIDs: ["dev-nonexistent"])

        #expect(Self.firstNonSilence(of: sinkA, startNanos: Self.anchorNanos) == nil,
                "an unknown UID must be a no-op: no crash, and no fall-through to an unrelated sink")
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

            /// Poll (never sleep a fixed amount) until the release-gate line
            /// lands — it is emitted from `graphQueue`, not from the render
            /// call that recorded it.
            func pollForOvershootLine(timeout: TimeInterval = 3) async -> String? {
                await pollForLines(evt: "bt_sink_release_overshoot", count: 1)?.first
            }

            /// The same poll, for any event and any number of lines.
            func pollForLines(evt: String, count: Int = 1,
                              timeout: TimeInterval = 3) async -> [String]? {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let hits = snapshot().filter { $0.contains("\"evt\":\"\(evt)\"") }
                    if hits.count >= count { return hits }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return nil
            }
        }

        /// THE OTHER HALF of the wizard's permanent silence: a forward seek is
        /// how a LARGER measured latency lands, and one that reaches the write
        /// pointer leaves the ring dry with nothing to play and no way back.
        @Test func anOverLargeForwardSeekIsClampedShortOfTheWritePointerAndLogged() async throws {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            // 30_000 frames = 625 ms buffered behind a 100 ms gate.
            let (manager, sink, _) = try BTSyncedSinkTests.anchoredSink()
            defer { manager.stop() }
            _ = BTSyncedSinkTests.renderCycle(
                sink, at: BTSyncedSinkTests.anchorNanos + 100_000_000)

            // 600 ms of extra latency asks for a 600 ms forward seek out of a
            // ring holding ~614 ms — inside it, but not by the safety margin.
            manager.setOffsetMs(600, forDeviceUID: "dev-a")
            let line = try #require(
                await capture.pollForLines(evt: "bt_sink_seek_clamped")?.first, "no line")
            #expect(line.contains("\"requestedMs\":\"-600.0\""), "\(line)")
            #expect(line.contains("\"appliedMs\":\"-514.3\""),
                    "clamped 100 ms short of the write pointer: \(line)")
            #expect(line.contains("\"uid\":\"dev-a\""), "\(line)")

            let after = BTSyncedSinkTests.renderCycle(sink, at: BTSyncedSinkTests.anchorNanos)
            #expect(after.produced, "the ring must still have audio in it")
            #expect(after.samples.contains { $0 != 0 })
        }

        /// The invariant the clamp exists for, over a whole run's worth of
        /// candidates: no sequence of previews can empty the ring.
        @Test func noSequenceOfLatencyPreviewsCanSeekTheRingDry() throws {
            let (manager, sink, _) = try BTSyncedSinkTests.anchoredSink()
            defer { manager.stop() }
            _ = BTSyncedSinkTests.renderCycle(
                sink, at: BTSyncedSinkTests.anchorNanos + 100_000_000)

            for (i, latencyMs) in [200, 900, 1_500, 2_000, 400, 1_800, 0].enumerated() {
                // The live producer keeps feeding through a run.
                BTSyncedSinkTests.enqueueRamp(
                    into: manager, atSec: BTSyncedSinkTests.anchorSec + 2 + i)
                manager.setOffsetMs(latencyMs, forDeviceUID: "dev-a")
                let cycle = BTSyncedSinkTests.renderCycle(
                    sink, at: BTSyncedSinkTests.anchorNanos + 200_000_000)
                #expect(cycle.produced, "silent after a preview at \(latencyMs) ms")
            }
        }

        /// The producer's drop counter, surfaced at the gate opening AND at
        /// session end — the `razor: no drop counters yet` note this replaces
        /// meant a ring that overflowed left no trace at all, and reporting it
        /// only at gate openings meant a wizard run (one gate, at the start)
        /// still left none for everything after it.
        @Test func ringDropsAreCountedPerGateAndResetWithTheSession() async throws {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let manager = BTSyncedSink(
                renderSampleRate: BTSyncedSinkTests.sampleRate, channelCount: 1,
                presentationDelayMs: { 100 })
            defer { manager.stop() }
            manager.setComposition(
                BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
            manager.setDevices([.init(deviceID: 0, uid: "dev-a")])
            let sink = try #require(manager.sinkForTesting(uid: "dev-a"))

            // The ring holds 11 s (1_048_576 frames once rounded up — the
            // Cast room-delay capacity), so five of these fit and the last
            // two have nowhere to go and are dropped wholesale.
            var block = [Float](repeating: 1, count: 200_000)
            func feed(atSec sec: Int) {
                block.withUnsafeBufferPointer { buf in
                    manager.enqueue(interleavedFrames: buf.baseAddress!,
                                    frameCount: block.count,
                                    pts: timespec(tv_sec: sec, tv_nsec: 0))
                }
            }
            for i in 0..<7 { feed(atSec: BTSyncedSinkTests.anchorSec + i) }

            // Open the gate; the NEXT enqueue posts the stashed record.
            _ = BTSyncedSinkTests.renderCycle(
                sink, at: BTSyncedSinkTests.anchorNanos + 100_000_000)
            feed(atSec: BTSyncedSinkTests.anchorSec + 4)
            let first = try #require(
                await capture.pollForLines(evt: "bt_sink_ring_drops")?.first, "no line")
            #expect(first.contains("\"chunks\":\"2\""), "\(first)")
            #expect(first.contains("\"uid\":\"dev-a\""), "\(first)")
            #expect(first.contains("\"at\":\"gate_open\""), "\(first)")

            // A new session starts the count over: the drops above belong to the
            // old one and must not be re-reported against this gate. The rebuild
            // that ends the old session emits its own line on the way out.
            manager.setComposition(
                BTGroupComposition(airPlayPresent: false, macLocalPresent: false))
            sink.test_waitForPendingRebuild()
            BTSyncedSinkTests.enqueueRamp(
                into: manager, atSec: BTSyncedSinkTests.anchorSec + 10)
            _ = BTSyncedSinkTests.renderCycle(
                sink, at: BTSyncedSinkTests.anchorNanos + 11_000_000_000)
            BTSyncedSinkTests.enqueueRamp(
                into: manager, atSec: BTSyncedSinkTests.anchorSec + 11)
            let lines = try #require(
                await capture.pollForLines(evt: "bt_sink_ring_drops", count: 3), "missing lines")
            #expect(lines[1].contains("\"at\":\"session_end\""),
                    "the rebuild closes the old session with a count: \(lines)")
            #expect(lines[2].contains("\"chunks\":\"0\"")
                    && lines[2].contains("\"at\":\"gate_open\""),
                    "the counter resets with the session: \(lines)")
        }

        /// A wizard run has ONE gate opening, at the start, so drops that happen
        /// during it were never reported anywhere (live report, 2026-08-22 — a
        /// Bluetooth speaker went silent mid-run with nothing in the log to
        /// explain it). Session end is the second reporting point.
        @Test func ringDropsAreAlsoReportedWhenTheSessionEnds() async throws {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let manager = BTSyncedSink(
                renderSampleRate: BTSyncedSinkTests.sampleRate, channelCount: 1,
                presentationDelayMs: { 100 })
            manager.setComposition(
                BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
            manager.setDevices([.init(deviceID: 0, uid: "dev-a")])

            // Overflow the ring (11 s ≈ 1_048_576 frames: five blocks fit,
            // two drop) WITHOUT ever opening the gate, so the only line that
            // can carry these drops is the one session end emits.
            var block = [Float](repeating: 1, count: 200_000)
            for i in 0..<7 {
                block.withUnsafeBufferPointer { buf in
                    manager.enqueue(interleavedFrames: buf.baseAddress!,
                                    frameCount: block.count,
                                    pts: timespec(tv_sec: BTSyncedSinkTests.anchorSec + i,
                                                  tv_nsec: 0))
                }
            }
            manager.stop()

            let line = try #require(
                await capture.pollForLines(evt: "bt_sink_ring_drops")?.first, "no line")
            #expect(line.contains("\"at\":\"session_end\""), "\(line)")
            #expect(line.contains("\"chunks\":\"2\""), "\(line)")
            #expect(line.contains("\"uid\":\"dev-a\""), "\(line)")
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
            // A MEASURED LATENCY is the same linear term in the delay as a trim
            // (roadmap 056 Part A: `reference − latency + trim`), and the wizard
            // pushes one per trial — so it lands the same way, live.
            manager.setOffsetMs(40, forDeviceUID: "dev-a")
            // Positive control: moving the REFERENCE timeline genuinely is
            // structural — without it an empty log would prove nothing.
            manager.setBTOnlyBufferMs(900)
            manager.stop()                    // drains the sink's async rebuild
            Telemetry._installTestSink(nil)   // flush barrier

            let lines = capture.snapshot()
            let rebuilds = lines.filter { $0.contains("\"evt\":\"bt_sink_rebuild\"") }
            #expect(rebuilds.count == 1, "lines: \(lines)")
            #expect(rebuilds.first?.contains("\"cause\":\"composition_change\"") == true,
                    "lines: \(lines)")
            #expect(!lines.contains { $0.contains("trim_change") }, "lines: \(lines)")
        }

        /// The gate's own line, and the proof it is emitted OFF the render
        /// thread: the render call only stashes the numbers, so nothing can
        /// appear until the producer has posted them to `graphQueue`.
        @Test func releaseOvershootIsLoggedOffTheRenderThread() async throws {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let (manager, sink, _) = try BTSyncedSinkTests.anchoredSink()
            defer { manager.stop() }
            _ = BTSyncedSinkTests.renderCycle(
                sink, at: BTSyncedSinkTests.anchorNanos + 400_000_000)
            BTSyncedSinkTests.enqueueRamp(into: manager)

            let line = try #require(await capture.pollForOvershootLine(), "no line")
            #expect(line.contains("\"overshootMs\":\"300.0\""), "\(line)")
            #expect(line.contains("\"caughtUpMs\":\"300.0\""), "\(line)")
            #expect(line.contains("\"partial\":\"0\""), "\(line)")
        }

        /// A ring that could not cover the overshoot says so, so the owner can
        /// tell "start-up was late but we recovered" from "we ran dry".
        @Test func aShortRingReleasesPartialAndSaysSo() async throws {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            // 30_000 frames of ramp = 625 ms against a 1000 ms overshoot.
            let (manager, sink, _) = try BTSyncedSinkTests.anchoredSink()
            defer { manager.stop() }
            _ = BTSyncedSinkTests.renderCycle(
                sink, at: BTSyncedSinkTests.anchorNanos + 1_100_000_000)
            BTSyncedSinkTests.enqueueRamp(into: manager)

            let line = try #require(await capture.pollForOvershootLine(), "no line")
            #expect(line.contains("\"overshootMs\":\"1000.0\""), "\(line)")
            #expect(line.contains("\"caughtUpMs\":\"625.0\""), "\(line)")
            #expect(line.contains("\"partial\":\"1\""), "\(line)")
        }

        /// The anchor line: fired the instant `enqueue` sets the anchor —
        /// `anchoredSink()`'s ramp does that on the first buffer — carrying the
        /// capture pts the session anchored on and the delay the anchor
        /// resolved (100 ms: `presentationDelayMs: { 100 }`, no offset/trim,
        /// AirPlay-present so the presentation term is the reference).
        @Test func anchorEmitsBtSinkAnchoredWithPtsAndDelay() async throws {
            let capture = LineCapture()
            Telemetry._installTestSink { capture.append($0) }
            defer { Telemetry._installTestSink(nil) }

            let (manager, _, _) = try BTSyncedSinkTests.anchoredSink()
            defer { manager.stop() }

            let line = try #require(
                await capture.pollForLines(evt: "bt_sink_anchored")?.first, "no line")
            #expect(line.contains("\"uid\":\"dev-a\""), "\(line)")
            #expect(line.contains("\"anchorPtsNanos\":\"\(BTSyncedSinkTests.anchorNanos)\""), "\(line)")
            #expect(line.contains("\"delayNanos\":\"100000000\""), "\(line)")
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
