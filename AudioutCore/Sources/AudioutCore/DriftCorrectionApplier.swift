// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Puts ``DriftCorrectionPolicy``'s decisions on the Bluetooth speakers
/// (roadmap 085 ticket 05).
///
/// The policy says what to move and whether the move may be made at once; this
/// owns the moving — the slew's rate cap, the gap a slew's remainder lands in,
/// the analytics line, and the guard that keeps a correction off anything but a
/// Bluetooth speaker (spec decision 13). Everything it touches arrives as a
/// closure, so a test drives it with no sink, no store and no clock.
///
/// What a correction moves is the speaker's stored MEASURED LATENCY — the
/// number the wizard's Keep writes — never its trim. Two reasons, and both
/// have to hold:
///
/// - It is what actually changed. A reconnect rolls the speaker a fresh
///   20–90 ms of its own latency; the measurement on file is simply out of
///   date, and the correction is the new measurement.
/// - `NativeBackend.refreshDriftTrackingLocked` rebuilds every baseline as
///   `room + trim`. Move the trim and the baseline moves WITH the speaker, so
///   the next window reads the same error again and the trim walks to its
///   clamp. The measured latency is absent from that expression, so a
///   correction leaves the baselines exactly where the calibration put them.
///
/// A corrected speaker's stored calibration is marked stale rather than
/// quietly replaced: the latency now in force is the tracker's, not the number
/// the user's own calibration left there.
final class DriftCorrectionApplier: @unchecked Sendable {

    /// One whole millisecond per step, twice a second — 2 ms of correction per
    /// second of music, the rate spec decision 5 calls inaudible. A measured
    /// latency is whole milliseconds (``BTSyncTrim/resolutionMs``, the same
    /// quantum both halves of the delay term keep), so a smaller step would
    /// round away to nothing.
    static let slewStepMs = BTSyncTrim.resolutionMs
    static let slewStepSeconds = 0.5
    /// No real program audio rendered for this long is a playback gap: a
    /// correction may land whole, inaudibly. Well past a buffer's worth of
    /// render cycles, well under a track change.
    /// razor: one fixed line. The upgrade path is the keep-alive's own silence
    /// verdict, once ticket 04's live test says what it really sees.
    static let gapAfterSilentSeconds = 1.0

    private let queue = DispatchQueue(label: "com.audiout.drift-correction")
    private let isBluetooth: @Sendable (String) -> Bool
    private let currentLatencyMs: @Sendable (String) -> Double
    private let writeLatencyMs: @Sendable (_ ms: Double, _ uid: String, _ persist: Bool) -> Void
    private let markCalibrationStale: @Sendable (String) -> Void
    private let programIsSilent: @Sendable () -> Bool
    /// How long one slew step waits. Only the tests pass anything but
    /// ``slewStepSeconds`` — shortening it there keeps a rate-cap assertion
    /// from costing the suite whole seconds.
    private let stepSeconds: Double

    /// `queue` only.
    private var policy = DriftCorrectionPolicy()
    private var slewRemainingMs: [String: Double] = [:]
    private var slewAppliedMs: [String: Double] = [:]
    private var timer: DispatchSourceTimer?
    private var surfacedMs: [String: Double] = [:]

    init(isBluetooth: @escaping @Sendable (String) -> Bool,
         currentLatencyMs: @escaping @Sendable (String) -> Double,
         writeLatencyMs: @escaping @Sendable (Double, String, Bool) -> Void,
         markCalibrationStale: @escaping @Sendable (String) -> Void,
         programIsSilent: @escaping @Sendable () -> Bool,
         stepSeconds: Double = DriftCorrectionApplier.slewStepSeconds) {
        self.stepSeconds = stepSeconds
        self.isBluetooth = isBluetooth
        self.currentLatencyMs = currentLatencyMs
        self.writeLatencyMs = writeLatencyMs
        self.markCalibrationStale = markCalibrationStale
        self.programIsSilent = programIsSilent
    }

    deinit { timer?.cancel() }

    /// One sampling window's usable observations.
    func handle(_ observations: [DriftCorrectionPolicy.Observation]) {
        queue.async { [self] in
            let actions = policy.decide(observations, programIsSilent: programIsSilent())
            for action in actions { apply(action, recordEvent: true) }
        }
    }

    /// The last correction this speaker was big enough to be told about
    /// (``DriftCorrectionPolicy/surfaceAtOrAboveMs``), in signed milliseconds —
    /// the state a surface renders; `nil` once nothing is outstanding to say.
    func surfacedCorrectionMs(forDevice uid: String) -> Double? {
        queue.sync { surfacedMs[uid] }
    }

    /// The user has seen the notice for this speaker.
    func clearSurfacedCorrection(forDevice uid: String) {
        queue.async { self.surfacedMs[uid] = nil }
    }

    // MARK: - Applying

    /// `queue` only. `recordEvent` is false for the in-gap remainder of a slew
    /// that silence interrupted: the same correction already counted once, and
    /// counting it twice would report drift that never happened.
    private func apply(_ action: DriftCorrectionPolicy.Action, recordEvent: Bool) {
        switch action {
        case .ignore, .scheduleVerify:
            break   // nothing moves; ticket 06 is what logs these
        case .correct(let correction):
            apply(correction, kind: "correct", recordEvent: recordEvent)
        case .swapAndRecorrect(let corrections):
            for correction in corrections {
                apply(correction, kind: "swap_recorrect", recordEvent: recordEvent)
            }
        }
    }

    /// `queue` only.
    private func apply(_ correction: DriftCorrectionPolicy.Correction,
                       kind: String, recordEvent: Bool) {
        let uid = correction.deviceUID
        // Spec decision 13: AirPlay and Cast receivers run scheduled delays
        // against the room reference clock and are never adjusted. The sampler
        // already emits no observation for one, so reaching here means the
        // baselines and the device list disagree — refuse and say so.
        guard isBluetooth(uid) else {
            Telemetry.log(.localPlayback, "drift_correction_refused",
                          ["device": uid, "reason": "not_bluetooth"])
            return
        }
        if correction.notify { surfacedMs[uid] = correction.ms }
        Telemetry.log(.localPlayback, "drift_correction_started", [
            "device": uid, "kind": kind,
            "ms": String(format: "%+.1f", correction.ms),
            "latencyBeforeMs": String(format: "%.1f", currentLatencyMs(uid)),
            "placement": correction.placement == .inGap ? "gap" : "slew",
            "notify": correction.notify ? "true" : "false",
        ])
        switch correction.placement {
        case .inGap:
            move(uid, byMs: correction.ms, persist: true)
        case .slew:
            // A re-correction replaces what is left of the old one: the fresh
            // error IS the move still needed, not an addition to it.
            slewRemainingMs[uid] = correction.ms
            slewAppliedMs[uid] = 0
            startTimerIfNeeded()
            stepSlews()
        }
        guard recordEvent else { return }
        Analytics.capture("bt_sync:drift_corrected", [
            "action": kind,
            "placement": correction.placement == .inGap ? "gap" : "slew",
            "magnitude_ms_bucket": BTSpeakerTiming.offsetBucket(correction.ms),
            "surfaced": correction.notify ? "true" : "false",
        ])
    }

    /// `queue` only. The measured latency the wizard's Keep writes, moved by
    /// `byMs`.
    ///
    /// THE DIRECTION, derived from the sink's own delay formula
    /// (`BTSyncedSink.delayNanos(forUID:)`): `reference − measuredLatency +
    /// trim`. A speaker that sounded LATER than its baseline arrives with
    /// `delta` POSITIVE (``PassiveDriftSampler``'s sign convention), and it
    /// sounded later because it is now adding more latency of its own — so the
    /// measured latency goes UP by exactly that much, the sink subtracts more,
    /// holds the audio for less, and the speaker moves back EARLIER onto its
    /// baseline. Adding `delta` to the TRIM instead would hold it longer still
    /// and send it further away, one window at a time, until the clamp stopped
    /// it.
    private func move(_ uid: String, byMs delta: Double, persist: Bool) {
        let target = BTSyncTrim.snap(currentLatencyMs(uid) + delta)
        writeLatencyMs(target, uid, persist)
        // Only a persisted move changes what is stored, so only a persisted
        // move can make the stored calibration stale.
        if persist {
            markCalibrationStale(uid)
            Telemetry.log(.localPlayback, "drift_correction_landed",
                          ["device": uid, "latencyAfterMs": String(format: "%.1f", target)])
        }
    }

    // MARK: - Slew

    /// `queue` only.
    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + stepSeconds, repeating: stepSeconds)
        timer.setEventHandler { [weak self] in self?.stepSlews() }
        self.timer = timer
        timer.resume()
    }

    /// `queue` only. One step of every running slew — or, the moment the music
    /// stops, the whole remainder at once, which is inaudible by definition.
    private func stepSlews() {
        guard !slewRemainingMs.isEmpty else { stopTimer(); return }
        if programIsSilent() { finishSlewsInGap(); return }
        for (uid, remaining) in slewRemainingMs {
            let step = min(Self.slewStepMs, abs(remaining)) * (remaining < 0 ? -1 : 1)
            let left = remaining - step
            // Below half a millisecond nothing survives the trim's own
            // rounding, so the slew is done rather than stepping forever.
            let done = abs(left) < BTSyncTrim.resolutionMs / 2
            move(uid, byMs: step, persist: done)
            slewAppliedMs[uid, default: 0] += step
            if done {
                slewRemainingMs[uid] = nil
                slewAppliedMs[uid] = nil
            } else {
                slewRemainingMs[uid] = left
            }
        }
        if slewRemainingMs.isEmpty { stopTimer() }
    }

    /// `queue` only.
    private func finishSlewsInGap() {
        let applied = slewAppliedMs
        slewRemainingMs = [:]
        slewAppliedMs = [:]
        stopTimer()
        for action in policy.programBecameSilent(appliedSoFarMs: applied) {
            apply(action, recordEvent: false)
        }
    }

    /// `queue` only.
    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
