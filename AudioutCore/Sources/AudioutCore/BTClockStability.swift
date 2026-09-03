// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like `BTSyncedSink.swift`: this file carries NO GPL
// SPDX header. The detector loop and the clock query are ported from the repo
// owner's own spike (`claude/bt-multi-spike`: `PacingProbe.swift` and
// `BTOutputEngine.currentDeviceClock`), which carried no licence header and
// derives from no GPL code. Do not add a GPL header to this file, and do not
// move GPL-derived code into it.

import CoreAudio
import Foundation

/// Whether one Bluetooth output device's pacing clock has stopped jumping.
///
/// On a Bluetooth device `AudioDeviceGetCurrentTime` reads the host-side
/// Bluetooth stack's pacing clock, not the speaker's own converter. That
/// clock steps (by a few ms up to hundreds of ms) while the stack re-buffers
/// after a connect, and stops stepping once it has settled. Measuring a
/// speaker while the clock still steps measures the settling, not the
/// speaker, so this is what decides when the phone's Measure button may go
/// live.
///
/// Fed one sample a second, it answers per sample what that sample meant and
/// keeps a running count of how long the clock has advanced without a step.
/// Pure: no device, no clock, no queue, so the whole rule is assertable.
public struct BTClockStability: Sendable {

    public enum Outcome: Equatable, Sendable {
        /// The first valid sample: it only sets the baseline.
        case ignored
        /// The clock advanced by a step the size of ordinary drift.
        case advanced
        /// `sampleTime` did not move: the device is not running IO and the
        /// query handed back a stale stamp. The stable-for count holds.
        case frozen
        /// The clock ran backwards, or host time did not advance: the
        /// device's IO restarted and reset its origin. New baseline, count 0.
        case rebaselined
        /// A step larger than ordinary drift between two samples a second
        /// apart: the stack re-anchored. Count 0. Signed, ms.
        case jumped(magnitudeMs: Double)
    }

    /// A step between two samples a second apart larger than this is a jump,
    /// not drift: real Bluetooth clock drift is a few hundred ppm, well under
    /// 0.5 ms per second.
    /// razor: one fixed threshold for every speaker. The ceiling is a learned
    /// per-device prior; nothing measured so far needs one.
    public static let jumpThresholdMs = 2.0
    /// A step of a second or more between two samples is not a re-anchor
    /// (the largest the spike ever saw was 100 ms): it is a clock whose
    /// origin moved, an IO restart the HAL reported as a forward skip rather
    /// than a backwards one. Treated as a lost baseline, never summed as a
    /// jump. Seen live on 2026-09-03: a sink rebuild read as a 19 s jump.
    /// razor: one fixed bound; the ceiling is a per-device learned bound.
    public static let lostBaselineThresholdMs = 1_000.0
    public static let sampleIntervalSeconds = 1.0
    /// How long the clock must advance jump-free before it is trusted.
    /// razor: one fixed window for every speaker (a Sony is clean in 2 s, a
    /// Sonos Move takes up to 42 s of jumps first). The ceiling is a learned
    /// per-device prior.
    public static let stableAfterSeconds = 10.0

    private struct Point {
        let sampleTime: Double
        let hostNanos: Int64
        let deviationMs: Double
    }

    private var baseline: Point?
    private var previous: Point?
    private var previousSampleTime: Double?
    /// Seconds of jump-free advance since the baseline or the last jump.
    public private(set) var stableForSeconds: Double = 0
    public var isStable: Bool { stableForSeconds >= Self.stableAfterSeconds }

    public init() {}

    /// One sample of the device clock: its `mSampleTime`, its host stamp
    /// rebased onto CLOCK_MONOTONIC nanoseconds, and the nominal rate the
    /// sample time counts in.
    public mutating func observe(sampleTime: Double, hostNanos: Int64, nominalRate: Double) -> Outcome {
        if sampleTime == previousSampleTime {
            // Drop the baseline, as the spike did: host time keeps running
            // while the clock stands still, so the first sample after a
            // freeze must start a new baseline rather than read the whole
            // idle stretch as one enormous jump.
            baseline = nil
            previous = nil
            return .frozen
        }
        previousSampleTime = sampleTime
        guard let base = baseline else {
            baseline = Point(sampleTime: sampleTime, hostNanos: hostNanos, deviationMs: 0)
            previous = baseline
            stableForSeconds = 0
            return .ignored
        }
        if sampleTime < base.sampleTime || hostNanos <= base.hostNanos {
            baseline = Point(sampleTime: sampleTime, hostNanos: hostNanos, deviationMs: 0)
            previous = baseline
            stableForSeconds = 0
            return .rebaselined
        }
        // Rate-normalised clock position minus host elapsed: flat while the
        // clock only drifts, a step the moment the stack re-anchors.
        let elapsed = Double(hostNanos - base.hostNanos) / 1_000_000_000
        let deviationMs = ((sampleTime - base.sampleTime) / nominalRate - elapsed) * 1_000
        let point = Point(sampleTime: sampleTime, hostNanos: hostNanos, deviationMs: deviationMs)
        let last = previous ?? base
        previous = point
        let step = deviationMs - last.deviationMs
        if abs(step) >= Self.lostBaselineThresholdMs {
            baseline = Point(sampleTime: sampleTime, hostNanos: hostNanos, deviationMs: 0)
            previous = baseline
            stableForSeconds = 0
            return .rebaselined
        }
        if abs(step) > Self.jumpThresholdMs {
            stableForSeconds = 0
            return .jumped(magnitudeMs: step)
        }
        stableForSeconds += Double(hostNanos - last.hostNanos) / 1_000_000_000
        return .advanced
    }
}

/// Polls one device's clock once a second on its own queue and hands every
/// outcome to `onOutcome`. Owned by the device's sink for the sink's whole
/// life. Every `start` begins a fresh detector: a start is a known IO
/// (re)start, and the first sample after one has no honest relation to the
/// samples before it. The store reads that first sample as a silent reset.
///
/// Why a timer and not the render callback: (1) the render callback's
/// `timestamp` is the engine's render timeline, whereas the re-anchor the
/// spike measured lives in the device's own `mSampleTime` to `mHostTime`
/// mapping, which only `AudioDeviceGetCurrentTime` reports; (2) the render
/// callback is a real-time thread and `BTSyncedSink` already keeps even log
/// formatting off it; (3) an error from the query (an idle device answers
/// `kAudioHardwareNotRunningError`) is a skipped tick, which the detector reads
/// as a hold. The spike's timing-only IOProc fallback is not ported: attaching
/// a second IOProc to a live playback device risks the audio for a diagnostic.
final class BTClockWatcher: @unchecked Sendable {

    /// Whether the poll runs at all. Set `AUDIOUT_BT_CLOCK_WATCH=0` to build
    /// the same app without it and compare.
    ///
    /// razor: a diagnostic switch, not a product setting. A live test on
    /// 2026-09-03 hit judder and then silence on a build carrying this file,
    /// and the stalls it showed were in the AirPlay send loop, which this
    /// file does not touch and which has stalled for seconds at a time in
    /// sessions since 2026-08-29. Reading a device's clock beside a running
    /// engine is the one new thing here, so it gets a way to be ruled out.
    /// Delete this switch once the cause is known.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AUDIOUT_BT_CLOCK_WATCH"] != "0"
    }

    private let deviceID: AudioObjectID
    private let onOutcome: @Sendable (BTClockStability.Outcome) -> Void
    private let queue: DispatchQueue
    /// Only ever touched on `queue`.
    private var detector = BTClockStability()
    private var nominalRate: Double = 0
    private var timer: DispatchSourceTimer?

    init(deviceID: AudioObjectID, deviceUID: String,
         onOutcome: @escaping @Sendable (BTClockStability.Outcome) -> Void) {
        self.deviceID = deviceID
        self.onOutcome = onOutcome
        self.queue = DispatchQueue(label: "com.audiout.btsink.clock.\(deviceUID)")
    }

    deinit { timer?.cancel() }

    /// Idempotent. `nominalRate` is the device's live rate at this start.
    func start(nominalRate: Double) {
        queue.async {
            self.nominalRate = nominalRate
            self.detector = BTClockStability()
        }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + BTClockStability.sampleIntervalSeconds,
                       repeating: BTClockStability.sampleIntervalSeconds)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {   // on queue
        var stamp = AudioTimeStamp()
        // A refused query (idle device, HAL not running) is a skipped tick:
        // no observation at all, never a rebaseline.
        guard AudioDeviceGetCurrentTime(deviceID, &stamp) == noErr,
              stamp.mFlags.contains(.sampleTimeValid),
              stamp.mFlags.contains(.hostTimeValid),
              nominalRate > 0 else { return }
        // The same mach-to-monotonic rebase the render path uses.
        let hostNanos = SyncTiming.monotonicNanos(
            CoreAudioSystemTap.timespec(fromHostTime: stamp.mHostTime))
        onOutcome(detector.observe(
            sampleTime: stamp.mSampleTime, hostNanos: hostNanos, nominalRate: nominalRate))
    }
}
