// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// How a decided correction reaches the speaker: which way it moves it, which
/// number it moves, the rate cap that keeps a moving delay inaudible, the gap
/// that lands the rest of it at once, and what the move does to the stored
/// calibration.
@Suite struct DriftCorrectionApplierTests {

    /// The speakers as the SINK actually schedules them, not as the applier
    /// imagines them. Every number here comes from
    /// `BTSyncedSink.delayNanos(forUID:)`'s own formula —
    /// `reference − measuredLatency + trim` — so a test that reads
    /// ``observedErrorMs`` back is reading what the next microphone window
    /// would really measure, and an applier that moves the wrong number, or the
    /// right number the wrong way, cannot agree with it.
    private final class Room: @unchecked Sendable {

        struct Speaker {
            /// The user's nudge. Nothing in this file may move it: it is half
            /// of what `NativeBackend.refreshDriftTrackingLocked` rebuilds the
            /// baselines from.
            var trimMs: Double = 0
            /// What the wizard measured and the sink subtracts.
            var measuredLatencyMs: Double
            /// What the speaker really adds today. This is what drifts — a
            /// reconnect rolls it 20–90 ms — and nothing but the speaker
            /// itself changes it.
            var trueLatencyMs: Double
        }

        /// The room delay every output schedules against: the `reference` term
        /// above, and `room` in `refreshDriftTrackingLocked`.
        static let referenceMs = 500.0

        private let lock = NSLock()
        private var speakers: [String: Speaker]
        private var writes: [(uid: String, ms: Double, persist: Bool)] = []
        private var stale: [String] = []

        init(_ speakers: [String: Speaker]) { self.speakers = speakers }

        // MARK: What the applier is wired to

        func measuredLatencyMs(_ uid: String) -> Double {
            lock.withLock { speakers[uid]?.measuredLatencyMs ?? 0 }
        }

        func write(_ ms: Double, _ uid: String, _ persist: Bool) {
            lock.withLock {
                speakers[uid]?.measuredLatencyMs = ms
                writes.append((uid, ms, persist))
            }
        }

        func recordStale(_ uid: String) { lock.withLock { stale.append(uid) } }

        var allWrites: [(uid: String, ms: Double, persist: Bool)] { lock.withLock { writes } }
        var staleMarks: [String] { lock.withLock { stale } }

        // MARK: What the microphone would hear

        /// The speaker drifts: it starts adding `ms` more latency of its own.
        func drift(_ uid: String, byMs ms: Double) {
            lock.withLock { speakers[uid]?.trueLatencyMs += ms }
        }

        /// When the microphone hears a block that left the fan-out at zero:
        /// the sink's hold plus what the speaker itself adds.
        func arrivalMs(_ uid: String) -> Double {
            lock.withLock {
                guard let s = speakers[uid] else { return 0 }
                return Self.referenceMs - s.measuredLatencyMs + s.trimMs + s.trueLatencyMs
            }
        }

        /// The delay `NativeBackend.refreshDriftTrackingLocked` hands the
        /// sampler for this speaker, recomputed from scratch every time — which
        /// is what a selection change or a user trim write makes it do. The
        /// measured latency is deliberately absent from it.
        func rebuiltBaselineMs(_ uid: String) -> Double {
            lock.withLock { Self.referenceMs + (speakers[uid]?.trimMs ?? 0) }
        }

        /// What the next window measures: how far this speaker sounded off the
        /// baseline, positive for LATER (``PassiveDriftSampler``'s convention).
        func observedErrorMs(_ uid: String) -> Double {
            arrivalMs(uid) - rebuiltBaselineMs(uid)
        }
    }

    /// Program silence answered by call count rather than by the clock, so a
    /// loaded machine cannot decide how far a slew got before the gap.
    private final class Silence: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        private let silentFromCall: Int
        init(silentFromCall: Int) { self.silentFromCall = silentFromCall }
        func ask() -> Bool {
            lock.withLock {
                asked += 1
                return asked >= silentFromCall
            }
        }
    }

    private func applier(_ room: Room, silent: Silence,
                         bluetooth: @escaping @Sendable (String) -> Bool = { _ in true })
        -> DriftCorrectionApplier {
        DriftCorrectionApplier(
            isBluetooth: bluetooth,
            currentLatencyMs: { room.measuredLatencyMs($0) },
            writeLatencyMs: { ms, uid, persist in room.write(ms, uid, persist) },
            markCalibrationStale: { room.recordStale($0) },
            programIsSilent: { silent.ask() },
            stepSeconds: 0.02)
    }

    /// Silent from the first question — every correction lands as one move.
    private var alwaysSilent: Silence { Silence(silentFromCall: 1) }
    /// Never silent — every correction slews.
    private var alwaysPlaying: Silence { Silence(silentFromCall: .max) }

    private func observation(_ uid: String, _ errorMs: Double)
        -> DriftCorrectionPolicy.Observation {
        .init(deviceUID: uid, errorMs: errorMs, hostNanos: 0, isBestGuess: false)
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Direction

    // THE SIGN PIN. The sink holds each device for `reference −
    // measuredLatency + trim`, so a BIGGER hold plays LATER: a speaker already
    // sounding 20 ms late has to be held 20 ms LESS. The applier gets there by
    // raising the measured latency, which the sink subtracts. The inversion —
    // adding the error to the hold — is what this turns red on, and it is not
    // a cosmetic failure: the speaker ends up 40 ms late, the next window reads
    // +20 again, and the number walks to its clamp.
    @Test func aSpeakerSoundingLateIsHeldLessUntilItIsBackOnItsBaseline() async throws {
        let room = Room(["bt": .init(measuredLatencyMs: 150, trueLatencyMs: 150)])
        #expect(room.observedErrorMs("bt") == 0, "calibrated: nothing to correct yet")
        room.drift("bt", byMs: 20)
        #expect(room.observedErrorMs("bt") == 20, "the speaker now sounds 20 ms late")

        let applier = applier(room, silent: alwaysSilent)
        applier.handle([observation("bt", room.observedErrorMs("bt"))])
        try await waitFor { room.allWrites.count >= 1 }

        #expect(room.observedErrorMs("bt") == 0, "and is back on its baseline")
        #expect(room.measuredLatencyMs("bt") == 170,
                "by storing what the speaker actually adds now, not by nudging it further out")
    }

    // Turns red if a correction survives only until the baselines are next
    // rebuilt — which a selection change, a reconnect or a user trim write all
    // do, several times a session. The applier moves the measured latency
    // precisely because `refreshDriftTrackingLocked` builds its baselines from
    // `room + trim` and not from that: rebuild as often as you like and the
    // corrected speaker still reads clean. Correcting the trim instead passes
    // the test above and fails here, then walks the speaker off the fleet
    // 20 ms per window.
    @Test func aRebuiltBaselineStillReadsACorrectedSpeakerAsClean() async throws {
        let room = Room(["bt": .init(trimMs: 12, measuredLatencyMs: 150, trueLatencyMs: 150)])
        room.drift("bt", byMs: 20)
        let applier = applier(room, silent: alwaysSilent)

        applier.handle([observation("bt", room.observedErrorMs("bt"))])
        try await waitFor { room.allWrites.count >= 1 }

        // Three windows, each one preceded by a full rebuild of the baselines
        // (which is what `rebuiltBaselineMs` recomputes), and each one fed back
        // in as the next window's observation.
        for window in 1...3 {
            let error = room.observedErrorMs("bt")
            #expect(error == 0, "window \(window) must see no error to chase")
            applier.handle([observation("bt", error)])
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(room.allWrites.count == 1, "and nothing further is ever moved")
        #expect(room.measuredLatencyMs("bt") == 170)
    }

    // The other direction, which the same inversion breaks the same way: a
    // speaker that has started sounding EARLY is held longer.
    @Test func aSpeakerSoundingEarlyIsHeldLonger() async throws {
        let room = Room(["bt": .init(measuredLatencyMs: 150, trueLatencyMs: 150)])
        room.drift("bt", byMs: -25)
        let applier = applier(room, silent: alwaysSilent)

        applier.handle([observation("bt", room.observedErrorMs("bt"))])
        try await waitFor { room.allWrites.count >= 1 }

        #expect(room.measuredLatencyMs("bt") == 125)
        #expect(room.observedErrorMs("bt") == 0)
    }

    // MARK: - What may be moved, how fast, and what it costs

    // Turns red if a correction can reach an AirPlay or Cast receiver. Those
    // run scheduled delays against the room reference clock and are never
    // adjusted (spec decision 13); moving one would chase the mic instead.
    @Test func onlyABluetoothSpeakerIsEverMoved() async throws {
        let room = Room([
            "bt": .init(measuredLatencyMs: 150, trueLatencyMs: 170),
            "airplay": .init(measuredLatencyMs: 0, trueLatencyMs: 25),
        ])
        let applier = applier(room, silent: alwaysSilent, bluetooth: { $0 == "bt" })
        applier.handle([observation("bt", 20), observation("airplay", 25)])
        try await waitFor { room.allWrites.count >= 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(room.allWrites.map(\.uid) == ["bt"])
    }

    // Turns red if a correction made during music lands in one jump, or if the
    // step grows past one millisecond per half second — the ~2 ms per second of
    // music that spec decision 5 calls inaudible.
    @Test func musicMovesTheStoredLatencyOneMillisecondAtATime() async throws {
        let room = Room(["bt": .init(measuredLatencyMs: 150, trueLatencyMs: 162)])
        let applier = applier(room, silent: alwaysPlaying)
        applier.handle([observation("bt", room.observedErrorMs("bt"))])
        try await waitFor { room.measuredLatencyMs("bt") == 162 }
        #expect(room.allWrites.map(\.ms) == Array(stride(from: 151.0, through: 162.0, by: 1)))
        // Only the value that ends the move is written to disk; the steps on
        // the way are the same in-memory scrub the drawer does.
        #expect(room.allWrites.map(\.persist) == Array(repeating: false, count: 11) + [true])
        #expect(room.staleMarks == ["bt"])
        #expect(room.observedErrorMs("bt") == 0)
    }

    // Turns red if a slew interrupted by silence keeps stepping through the
    // gap instead of landing the rest at once, which is the whole reason to
    // prefer a gap: the move is inaudible there.
    @Test func aGapLandsTheRestOfASlewInOneMove() async throws {
        let room = Room(["bt": .init(measuredLatencyMs: 150, trueLatencyMs: 170)])
        // The decision and the first two slew steps see music; the music stops
        // before the third.
        let applier = applier(room, silent: Silence(silentFromCall: 4))
        applier.handle([observation("bt", room.observedErrorMs("bt"))])
        try await waitFor { room.measuredLatencyMs("bt") == 170 }
        let all = room.allWrites
        let last = try #require(all.last)
        let previous = try #require(all.dropLast().last)
        #expect(last.ms - previous.ms > BTSyncTrim.resolutionMs,
                "the remainder should land in one move, not another slew step")
        #expect(last.persist, "the value that ends the move is the one stored")
    }

    // Turns red if a correction at or above the surfacing line stops reaching
    // the state a surface reads, or if the state sticks after it is cleared.
    // The ≥ 40 ms half of spec decision 6 — the user is told about a move that
    // big, and only about one that big.
    @Test func aLargeCorrectionSurfacesUntilItIsCleared() async throws {
        let room = Room([
            "bt": .init(measuredLatencyMs: 150, trueLatencyMs: 195),
            "quiet": .init(measuredLatencyMs: 150, trueLatencyMs: 162),
        ])
        let applier = applier(room, silent: alwaysSilent)
        applier.handle([observation("bt", 45), observation("quiet", 12)])
        try await waitFor { room.allWrites.count >= 2 }
        #expect(applier.surfacedCorrectionMs(forDevice: "bt") == 45)
        #expect(applier.surfacedCorrectionMs(forDevice: "quiet") == nil)
        applier.clearSurfacedCorrection(forDevice: "bt")
        try await waitFor { applier.surfacedCorrectionMs(forDevice: "bt") == nil }
        #expect(applier.surfacedCorrectionMs(forDevice: "bt") == nil)
    }
}

/// The applier driven against the REAL Bluetooth sink, rendering real samples
/// (roadmap 085 ticket 05, "done when"): a correction is a live seek of a
/// playing delay line, and what has to hold is that the audio coming out the
/// other side carries no click and skips nothing.
///
/// The sink is driven directly with synthetic cycle times, the
/// `BTSyncedSinkTests` harness style — no engine, no device, no sound.
@Suite struct DriftCorrectionApplierSinkTests {

    static let sampleRate = 48_000.0
    static let nsPerFrame = 1_000_000_000.0 / sampleRate
    static let anchorSec = 1_000
    static let anchorNanos = Int64(anchorSec) * 1_000_000_000
    static let framesPerCycle = 512
    /// 400 ms of hold, not the 100 ms the other sink suites use: a forward seek
    /// is clamped to stay ``BTDeviceSink/seekSafetyMarginMs`` (100 ms) short of
    /// the write pointer, so a shorter hold would clamp every correction here
    /// to nothing and the assertions would pass on audio that never moved.
    static let presentationDelayMs = 400

    /// A manager holding one device, anchored on `signal`.
    ///
    /// The caller MUST keep the manager alive for the whole test: its `deinit`
    /// stops every sink, which clears the anchor.
    static func anchored(on signal: [Float], uid: String = "dev-a") throws
        -> (BTSyncedSink, BTDeviceSink) {
        let manager = BTSyncedSink(
            renderSampleRate: sampleRate, channelCount: 1,
            presentationDelayMs: { presentationDelayMs })
        manager.setComposition(BTGroupComposition(airPlayPresent: true, macLocalPresent: false))
        manager.setDevices([.init(deviceID: 0, uid: uid)])
        signal.withUnsafeBufferPointer { buf in
            manager.enqueue(
                interleavedFrames: buf.baseAddress!, frameCount: signal.count,
                pts: timespec(tv_sec: anchorSec, tv_nsec: 0))
        }
        return (manager, try #require(manager.sinkForTesting(uid: uid)))
    }

    /// The applier wired to a real sink: what it writes is the device's stored
    /// measured latency, which the manager splices live (`setOffsetMs`).
    static func applier(on manager: BTSyncedSink, silent: @escaping @Sendable () -> Bool,
                        stepSeconds: Double) -> DriftCorrectionApplier {
        DriftCorrectionApplier(
            isBluetooth: { _ in true },
            currentLatencyMs: { Double(manager.offsetMs(forDeviceUID: $0)) },
            writeLatencyMs: { ms, uid, _ in manager.setOffsetMs(Int(ms), forDeviceUID: uid) },
            markCalibrationStale: { _ in },
            programIsSilent: silent,
            stepSeconds: stepSeconds)
    }

    /// One 512-frame render cycle, `cycle` cycles after the anchor.
    static func render(_ sink: BTDeviceSink, cycle: Int) -> [Float] {
        var out = [Float](repeating: 0, count: framesPerCycle)
        let start = anchorNanos + Int64((Double(cycle * framesPerCycle) * nsPerFrame).rounded())
        out.withUnsafeMutableBufferPointer {
            _ = sink.renderInterleaved(
                into: $0, frameCount: framesPerCycle, cycleStartMonotonicNanos: start)
        }
        return out
    }

    /// Render from the anchor until the delay line releases, and return the
    /// cycle number that follows the first audible one.
    static func renderUntilAudible(_ sink: BTDeviceSink) throws -> Int {
        for cycle in 0..<200 where render(sink, cycle: cycle).contains(where: { $0 != 0 }) {
            return cycle + 1
        }
        Issue.record("the sink never released")
        return 0
    }

    static func maxStep(_ samples: [Float]) -> Float {
        zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    // (i) THE GAP MOVE. A correction taken in a playback gap is one move of the
    // whole error, and the ring is still anchored and released while it
    // happens — so what lands is a live seek, and the only thing between it and
    // an audible click is the delay line's crossfade. Turns red if a whole
    // correction ever reaches the output as a step bigger than the programme
    // material's own, which is what a raw splice sounds like.
    @Test func aWholeCorrectionTakenInAGapLeavesNoClickInTheOutput() async throws {
        let sine = (0..<400_000).map {
            Float(sin(2 * Double.pi * 1_000 * Double($0) / Self.sampleRate))
        }
        let (manager, sink) = try Self.anchored(on: sine)
        defer { manager.stop() }
        let applier = Self.applier(on: manager, silent: { true }, stepSeconds: 0.02)

        var cycle = try Self.renderUntilAudible(sink)
        for _ in 0..<10 { _ = Self.render(sink, cycle: cycle); cycle += 1 }

        applier.handle([.init(deviceUID: "dev-a", errorMs: 20, hostNanos: 0, isBestGuess: false)])
        var out: [Float] = []
        var cyclesSinceMove = 0
        for _ in 0..<300 {
            out += Self.render(sink, cycle: cycle)
            cycle += 1
            if manager.offsetMs(forDeviceUID: "dev-a") == 20 {
                cyclesSinceMove += 1
                if cyclesSinceMove > 20 { break }
            } else {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        #expect(manager.offsetMs(forDeviceUID: "dev-a") == 20,
                "one move of the whole 20 ms, not a slew")
        // The equal-power pair can sum to √2 where the two sides correlate, and
        // the fade envelope adds a few percent — the same ceiling
        // `BTSyncedSinkTests` splice assertions use. A real click is a step of
        // order the full amplitude, some fifteen times a 1 kHz sine's own.
        #expect(Self.maxStep(out) <= Self.maxStep(sine) * 1.5,
                "step \(Self.maxStep(out)) vs source \(Self.maxStep(sine))")
    }

    /// Drive a whole slew: twelve one-millisecond seeks arriving mid-playback,
    /// a few milliseconds apart, while the sink renders. Returns everything
    /// rendered from the first audible cycle on.
    static func renderThroughASlew(errorMs: Double, on signal: [Float]) async throws -> [Float] {
        let (manager, sink) = try anchored(on: signal)
        defer { manager.stop() }
        // A step every 10 ms against a render cycle every millisecond: ten
        // cycles per step nominally, so the steps stay separate the way they do
        // in life (one step per half second, one render cycle per ten
        // milliseconds) even on a machine slow enough to lose most of them. The
        // 300-iteration bound is a hang-stop, not a deadline — twelve steps
        // need about 120 ms of it.
        let applier = applier(on: manager, silent: { false }, stepSeconds: 0.01)

        var cycle = try renderUntilAudible(sink)
        var out = render(sink, cycle: cycle)
        cycle += 1

        applier.handle(
            [.init(deviceUID: "dev-a", errorMs: errorMs, hostNanos: 0, isBestGuess: false)])
        for _ in 0..<300 {
            out += render(sink, cycle: cycle)
            cycle += 1
            if manager.offsetMs(forDeviceUID: "dev-a") == Int(errorMs) { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(manager.offsetMs(forDeviceUID: "dev-a") == Int(errorMs), "the slew completed")
        // The last step is written to the sink, not to the ring: it is the next
        // render that consumes it. Drain a few more cycles so the output holds
        // the whole correction however late that step landed.
        for _ in 0..<8 {
            out += render(sink, cycle: cycle)
            cycle += 1
        }
        return out
    }

    // (ii) THE SLEW, HEARD. A dozen seeks land in the middle of the programme a
    // few milliseconds apart, each with its own crossfade, and some of them
    // start before the last one's fade has finished. Turns red if any of that
    // reaches the output as a step bigger than the programme material's own —
    // the same ceiling and the same reasoning as the gap move above, applied to
    // the case the slew exists for.
    @Test func aSlewLeavesNoStepBiggerThanTheProgrammesOwn() async throws {
        let sine = (0..<400_000).map {
            Float(sin(2 * Double.pi * 1_000 * Double($0) / Self.sampleRate))
        }
        let out = try await Self.renderThroughASlew(errorMs: 12, on: sine)
        #expect(Self.maxStep(out) <= Self.maxStep(sine) * 1.5,
                "step \(Self.maxStep(out)) vs source \(Self.maxStep(sine))")
    }

    // (ii) THE SLEW, COUNTED. The signal's value IS its own position, so the
    // output says exactly how far the timeline travelled: one frame per frame
    // played, plus the 576 frames (12 ms at 48 kHz) the correction took out of
    // it. Turns red if a step seeks the wrong way, or lands twice, or is eaten
    // by a clamp — all of which leave the arithmetic short or long.
    //
    // Per-SAMPLE ordering is deliberately not asserted here, and cannot be: the
    // crossfade is equal-power, so mid-fade the two sides sum to as much as √2,
    // and on a ramp — whose samples are large numbers, not a zero-mean
    // waveform — that bulge dwarfs the 48-frame step and reads as the output
    // going backwards. The test above is where continuity is judged, on
    // material the fade was designed for.
    @Test func aSlewTakesExactlyTheCorrectionOutOfTheTimeline() async throws {
        let ramp = (0..<400_000).map { Float($0 + 1) }
        let out = try await Self.renderThroughASlew(errorMs: 12, on: ramp)
        let played = Double(out.count)
        let first = try #require(out.first)
        let last = try #require(out.last)
        let advanced = Double(last - first)
        // Slack for one render cycle: the last step can be written after the
        // cycle that would have carried it, leaving it for the cycle after the
        // loop stopped.
        #expect(abs(advanced - (played - 1) - 576) <= Double(Self.framesPerCycle),
                "advanced \(advanced) over \(played) samples played")
    }
}
