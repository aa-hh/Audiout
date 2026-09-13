// SPDX-License-Identifier: GPL-2.0-or-later

import AirPlayEngine
import Foundation
import ProbeKit

/// Turns one mic window into per-speaker delay observations (roadmap 085
/// ticket 03).
///
/// ``PassiveDriftCorrelator`` says only *a speaker arrived at this delay*: all
/// speakers play the same program, so the signal cannot say which. This does
/// the saying, by matching each returned peak to the nearest calibrated
/// baseline delay and reading the difference as that speaker's error. Pure —
/// no mic, no clock, no queue — so every rule is assertable; ``PassiveDriftTracker``
/// beside it owns the capture, the cadence and the ring.
///
/// Sign convention, the same one ``MicProbeSession/Result`` already uses:
/// positive means the speaker sounded LATER than its baseline, which is what
/// `DriftCorrectionPolicy` turns straight into a trim move.
///
/// Three rules the delays alone would get wrong:
///
/// - **An AirPlay or Cast arrival is read-only** (spec decision 13). Those
///   receivers play on the shared room reference clock and do not drift, so an
///   arrival of one that is off baseline measures the MIC, not the speaker —
///   the mic moved, or the capture path changed. That deviation is subtracted
///   from every Bluetooth deviation and folded into the baselines, exactly as
///   the chirp probe uses its reference lane, and no observation is ever
///   emitted for such a device.
/// - **Everything shifted together is the mic, not the room** (decision 8).
///   With no anchor to measure against, a common shift across every Bluetooth
///   peak re-baselines instead of correcting. It is the only mic-movement
///   guard the Mac has; the phone's motion sensors do not exist here.
/// - **A blind mic goes quiet** (decision 9). Five consecutive unusable
///   windows — lid shut, wrong room — stop the tracking rather than retrying
///   forever, and ``isBlind`` is what the UI will render later.
public struct PassiveDriftSampler: Sendable {

    /// One speaker's calibrated arrival delay, measured from the instant a
    /// block left the fan-out to the instant the mic hears it.
    public struct Baseline: Equatable, Sendable {
        public let deviceUID: String
        public let kind: Device.Kind
        public var expectedDelayMs: Double

        public init(deviceUID: String, kind: Device.Kind, expectedDelayMs: Double) {
            self.deviceUID = deviceUID
            self.kind = kind
            self.expectedDelayMs = expectedDelayMs
        }

        /// Everything that is not a Bluetooth speaker is scheduled against the
        /// room reference clock, so it anchors the measurement instead of
        /// being corrected by it.
        public var isAnchor: Bool { kind != .bluetooth }
    }

    public enum Outcome: Equatable, Sendable {
        /// What this window measured, one entry per matched Bluetooth speaker
        /// (including the ones that did not move — the policy reads those as
        /// confirmation that an earlier correction landed).
        case observations([DriftCorrectionPolicy.Observation])
        /// Every peak moved by the same amount with no anchor to check it
        /// against: the baselines absorbed the shift and nothing is corrected.
        case rebaselined(shiftMs: Double)
        case unusable(DriftRejection)
        /// Sampling is quietly off after ``blindAfterUnusableWindows``.
        case blind
    }

    /// Consecutive unusable windows before the mic is treated as blind.
    /// razor: one fixed count for every Mac, the spec's starting N. The
    /// upgrade path is a count tuned from the field log (ticket 06).
    public static let blindAfterUnusableWindows = 5
    /// How far either side of a baseline a peak may sit and still be that
    /// speaker's — the largest Bluetooth jump worth tracking, per
    /// ``PassiveDriftCorrelator/analyze(reference:referenceRate:capture:captureRate:expectedDelaysMs:searchHalfWidthMs:ambientNoise:)``.
    public static let defaultSearchHalfWidthMs = 120.0
    /// Deviations spread no wider than this are one common shift, not several
    /// independent jumps. Well under the 10 ms the policy already calls
    /// inaudible, so a real single-speaker jump can never hide inside it.
    public static let sameShiftWithinMs = 5.0

    public private(set) var baselines: [Baseline]
    public private(set) var consecutiveUnusableWindows = 0
    /// The mic has gone quiet (decision 9). Cleared by ``reArm()``.
    public private(set) var isBlind = false

    public var searchHalfWidthMs = PassiveDriftSampler.defaultSearchHalfWidthMs
    public var correlator = PassiveDriftCorrelator()

    public init(baselines: [Baseline] = []) {
        self.baselines = baselines
    }

    /// A fresh calibration. Re-arms a blind mic: new baselines mean the user
    /// just measured the room, so the old refusals say nothing about it.
    public mutating func setBaselines(_ baselines: [Baseline]) {
        self.baselines = baselines
        reArm()
    }

    /// The correlator's peaks from the most recent usable window, for the
    /// field log. Empty until one lands.
    public private(set) var lastPeaks: [DriftPeak] = []
    /// The strongest peak inside each baseline's search window from the most
    /// recent window, whatever its confidence — for the field log, so a refused
    /// window shows whether the arrival scored just under the threshold or was
    /// outside the search. Empty when the slice was refused before correlating.
    public private(set) var lastCandidates: [DriftPeak] = []

    /// Start listening again after a blind spell — a re-sync or a new
    /// calibration.
    public mutating func reArm() {
        isBlind = false
        consecutiveUnusableWindows = 0
    }

    /// Measure one window. `reference[0]` and `capture[0]` must be the same
    /// monotonic instant (the correlator's alignment contract); `hostNanos` is
    /// that instant, carried onto every observation.
    public mutating func analyze(reference: [Float], referenceRate: Double,
                                 capture: [Float], captureRate: Double,
                                 hostNanos: Int64,
                                 ambientNoise: [Float]? = nil) -> Outcome {
        lastPeaks = []
        lastCandidates = []
        guard !isBlind else { return .blind }
        guard !baselines.isEmpty else { return .observations([]) }

        let (outcome, candidates) = correlator.analyzeWithCandidates(
            reference: reference, referenceRate: referenceRate,
            capture: capture, captureRate: captureRate,
            expectedDelaysMs: baselines.map(\.expectedDelayMs),
            searchHalfWidthMs: searchHalfWidthMs,
            ambientNoise: ambientNoise)
        lastCandidates = candidates

        switch outcome {
        case .unusable(let rejection):
            consecutiveUnusableWindows += 1
            if consecutiveUnusableWindows >= Self.blindAfterUnusableWindows { isBlind = true }
            return .unusable(rejection)
        case .usable(let peaks):
            consecutiveUnusableWindows = 0
            lastPeaks = peaks
            return attribute(peaks: peaks, hostNanos: hostNanos)
        }
    }

    // MARK: - Attribution

    private struct Match {
        let baselineIndex: Int
        let deviationMs: Double
    }

    private mutating func attribute(peaks: [DriftPeak], hostNanos: Int64) -> Outcome {
        let (matches, contended) = matched(peaks: peaks)
        guard !matches.isEmpty else { return .observations([]) }

        let anchorDeviations = matches
            .filter { baselines[$0.baselineIndex].isAnchor }
            .map(\.deviationMs)
        let bluetooth = matches.filter { !baselines[$0.baselineIndex].isAnchor }

        // No anchor to measure the mic against: a shift every speaker shares
        // is the mic's, and re-baselining it is the whole response.
        if anchorDeviations.isEmpty, bluetooth.count > 1 {
            let deviations = bluetooth.map(\.deviationMs)
            let shift = median(deviations)
            if let spread = deviations.max().map({ $0 - (deviations.min() ?? $0) }),
               spread <= Self.sameShiftWithinMs,
               abs(shift) >= DriftCorrectionPolicy.ignoreBelowMs {
                shiftBaselines(by: shift)
                return .rebaselined(shiftMs: shift)
            }
        }

        // An anchor's own deviation IS the mic's offset (decision 13): take it
        // out of every Bluetooth deviation, and fold it into the baselines so
        // the next window starts from where the mic actually is.
        let micOffsetMs = anchorDeviations.isEmpty ? 0 : median(anchorDeviations)
        if abs(micOffsetMs) >= BTSyncTrim.resolutionMs { shiftBaselines(by: micOffsetMs) }

        let errors = bluetooth.map { ($0.baselineIndex, $0.deviationMs - micOffsetMs) }
        let movedCount = errors.filter { abs($0.1) >= DriftCorrectionPolicy.ignoreBelowMs }.count
        let observations = errors
            .map { index, errorMs in
                let moved = abs(errorMs) >= DriftCorrectionPolicy.ignoreBelowMs
                return DriftCorrectionPolicy.Observation(
                    deviceUID: baselines[index].deviceUID,
                    errorMs: errorMs,
                    hostNanos: hostNanos,
                    isBestGuess: moved && (movedCount > 1 || contended))
            }
            .sorted { $0.deviceUID < $1.deviceUID }
        return .observations(observations)
    }

    /// Nearest-peak assignment, closest pair first, each peak used once.
    /// `contended` is true when a baseline's own nearest peak went to another
    /// baseline — the ambiguity that makes an assignment a guess.
    private func matched(peaks: [DriftPeak]) -> (matches: [Match], contended: Bool) {
        var candidates: [(baseline: Int, peak: Int, distance: Double)] = []
        for (b, baseline) in baselines.enumerated() {
            for (p, peak) in peaks.enumerated() {
                let distance = abs(peak.delayMs - baseline.expectedDelayMs)
                guard distance <= searchHalfWidthMs else { continue }
                candidates.append((b, p, distance))
            }
        }
        candidates.sort { $0.distance < $1.distance }

        var nearestPeak: [Int: Int] = [:]
        for candidate in candidates where nearestPeak[candidate.baseline] == nil {
            nearestPeak[candidate.baseline] = candidate.peak
        }

        var matches: [Match] = []
        var takenPeaks: Set<Int> = []
        var takenBaselines: Set<Int> = []
        var contended = false
        for candidate in candidates {
            guard !takenPeaks.contains(candidate.peak),
                  !takenBaselines.contains(candidate.baseline) else { continue }
            takenPeaks.insert(candidate.peak)
            takenBaselines.insert(candidate.baseline)
            if nearestPeak[candidate.baseline] != candidate.peak { contended = true }
            matches.append(Match(
                baselineIndex: candidate.baseline,
                deviationMs: peaks[candidate.peak].delayMs
                    - baselines[candidate.baseline].expectedDelayMs))
        }
        // A baseline left unmatched because its nearest peak went elsewhere is
        // the same ambiguity seen from the other side.
        for (baseline, peak) in nearestPeak
        where !takenBaselines.contains(baseline) && takenPeaks.contains(peak) {
            contended = true
        }
        return (matches, contended)
    }

    private mutating func shiftBaselines(by ms: Double) {
        for index in baselines.indices { baselines[index].expectedDelayMs += ms }
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

// MARK: - The loop

/// Drives ``PassiveDriftSampler`` from the built-in mic and the retained
/// program audio: arm the reference ring, record a few seconds, correlate the
/// two, hand the observations on.
///
/// What it deliberately does not do: act on an observation (ticket 05), log
/// one (ticket 06), or ask for the microphone. A mic that was never granted
/// means tracking is simply off — this feature is not worth a permission
/// prompt the user did not ask for.
final class PassiveDriftTracker: @unchecked Sendable {

    /// Why a window is being taken. Every non-periodic reason is a moment the
    /// bench data says alignment jumps (spec decision 2).
    enum Trigger: Equatable, Sendable {
        case periodic
        /// `BTClockStability.Outcome.jumped` — the pacing clock re-anchored.
        case clockJump
        case reconnect
        case audioModeChange
        case silenceToAudio
    }

    /// Long enough for the correlator, short enough to be cheap: the spec's
    /// "even 10 seconds is more than necessary".
    static let windowSeconds = 4.0
    /// razor: one fixed cadence in the spec's 2–5 minute band. The upgrade
    /// path is a cadence that widens while everything stays put.
    static let periodicIntervalSeconds = 180.0
    /// Headroom past the deepest baseline so the reference slice still fits
    /// inside the capture once a speaker's delay has shifted it.
    static let searchMarginMs = 50.0

    private let ring: ReferenceAudioRing
    private let makeRecorder: @Sendable () -> MicProbeRecording
    private let permissionIsGranted: @Sendable () -> Bool
    private let onObservations: @Sendable ([DriftCorrectionPolicy.Observation]) -> Void
    private let windowSeconds: Double
    private let intervalSeconds: Double
    private let queue = DispatchQueue(label: "com.audiout.passive-drift")

    /// `queue` only.
    private var sampler = PassiveDriftSampler()
    private var timer: DispatchSourceTimer?
    private var windowInFlight = false
    /// Whether periodic sampling is meant to be running — true between
    /// ``start()`` and ``stop()``, including a blind spell when the timer
    /// itself is cancelled.
    private var isRunning = false

    init(ring: ReferenceAudioRing,
         windowSeconds: Double = PassiveDriftTracker.windowSeconds,
         intervalSeconds: Double = PassiveDriftTracker.periodicIntervalSeconds,
         makeRecorder: @escaping @Sendable () -> MicProbeRecording = { BuiltInMicRecorder() },
         permissionIsGranted: @escaping @Sendable () -> Bool = { MicCapturePermission.isGranted },
         onObservations: @escaping @Sendable ([DriftCorrectionPolicy.Observation]) -> Void) {
        self.ring = ring
        self.windowSeconds = windowSeconds
        self.intervalSeconds = intervalSeconds
        self.makeRecorder = makeRecorder
        self.permissionIsGranted = permissionIsGranted
        self.onObservations = onObservations
    }

    deinit { timer?.cancel() }

    /// The calibrated per-speaker delays this tracker measures against, and a
    /// re-arm of a blind mic.
    func setBaselines(_ baselines: [PassiveDriftSampler.Baseline]) {
        queue.async { [self] in
            sampler.setBaselines(baselines)
            // A blind spell cancelled the periodic timer; re-arming the sampler
            // without rescheduling it would leave only event triggers sampling,
            // for good.
            if isRunning, timer == nil { scheduleTimer() }
        }
    }

    var isBlind: Bool {
        queue.sync { sampler.isBlind }
    }

    var baselines: [PassiveDriftSampler.Baseline] {
        queue.sync { sampler.baselines }
    }

    func start() {
        queue.async { [self] in
            isRunning = true
            guard timer == nil else { return }
            scheduleTimer()
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// `queue` only.
    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
        timer.setEventHandler { [weak self] in self?.takeWindow() }
        self.timer = timer
        timer.resume()
    }

    /// Take a window now, unless one is already running. The reason names the
    /// seam that fired; the window itself is the same either way.
    func trigger(_ reason: Trigger) {
        queue.async { self.takeWindow(reason: reason) }
    }

    /// `queue` only.
    private func takeWindow(reason: Trigger = .periodic) {
        let skip: String? = windowInFlight ? "window_in_flight"
            : sampler.isBlind ? "blind"
            : sampler.baselines.isEmpty ? "no_baselines"
            : !permissionIsGranted() ? "no_mic_permission" : nil
        if let skip {
            Telemetry.log(.localPlayback, "drift_window_skipped",
                          ["trigger": "\(reason)", "reason": skip])
            return
        }
        let recorder = makeRecorder()
        ring.setArmed(true)
        guard let captureRate = try? recorder.start(), captureRate > 0 else {
            ring.setArmed(false)
            Telemetry.log(.localPlayback, "drift_window_skipped",
                          ["trigger": "\(reason)", "reason": "mic_start_failed"])
            return
        }
        Telemetry.log(.localPlayback, "drift_window_started",
                      ["trigger": "\(reason)", "seconds": String(format: "%.1f", windowSeconds)])
        windowInFlight = true
        queue.asyncAfter(deadline: .now() + windowSeconds) { [self] in
            finishWindow(recorder: recorder, captureRate: captureRate)
            ring.setArmed(false)
            windowInFlight = false
        }
    }

    /// `queue` only.
    private func finishWindow(recorder: MicProbeRecording, captureRate: Double) {
        let capture = recorder.stop()
        // Without the instant of `capture[0]` there is no shared zero to
        // measure a delay from, so the window is dropped rather than guessed
        // at — and that is a setup fault, not a deaf mic, so it does not count
        // toward the quiet disable.
        guard let startNanos = recorder.firstSampleHostNanos, !capture.isEmpty else {
            Telemetry.log(.localPlayback, "drift_window_dropped",
                          ["reason": capture.isEmpty ? "empty_capture" : "no_mic_timestamp"])
            return
        }

        let tailMs = (sampler.baselines.map(\.expectedDelayMs).max() ?? 0)
            + sampler.searchHalfWidthMs + Self.searchMarginMs
        let referenceNanos = Int64((Double(capture.count) / captureRate * 1_000_000_000).rounded())
            - Int64(tailMs * 1_000_000)
        // The retained run must begin at the mic's own first sample: the
        // correlator measures every delay from that shared zero, so a slice
        // that starts anywhere else biases every peak by the difference.
        // Frame quantisation inside the ring is the only slack allowed.
        let frameNanos = Int64(1_000_000_000 / Double(PCMFormat.airplay.sampleRate))
        guard referenceNanos > 0,
              let slice = ring.slice(fromNanos: startNanos,
                                     toNanos: startNanos + referenceNanos),
              abs(slice.startPtsNanos - startNanos) <= frameNanos
        else {
            Telemetry.log(.localPlayback, "drift_window_dropped",
                          ["reason": "reference_not_aligned"])
            return
        }

        let outcome = sampler.analyze(
            reference: Self.mono(slice.pcm),
            referenceRate: Double(PCMFormat.airplay.sampleRate),
            capture: capture, captureRate: captureRate, hostNanos: startNanos)
        Self.logWindow(outcome, peaks: sampler.lastPeaks, candidates: sampler.lastCandidates,
                       baselines: sampler.baselines)
        if case .observations(let observations) = outcome, !observations.isEmpty {
            onObservations(observations)
        }
        if sampler.isBlind { timer?.cancel(); timer = nil }
    }

    /// The ring's interleaved S16LE frames as the mono float the correlator
    /// takes.
    /// One local line per measured window: what the correlator heard, what the
    /// sampler made of it. Local only — `Telemetry.log` never leaves the Mac,
    /// so device ids are allowed here.
    static func logWindow(_ outcome: PassiveDriftSampler.Outcome, peaks: [DriftPeak],
                          candidates: [DriftPeak],
                          baselines: [PassiveDriftSampler.Baseline]) {
        let format = { (p: DriftPeak) in String(format: "%.1fms@%.2f", p.delayMs, p.confidence) }
        var fields: [String: String] = [
            "peaks": peaks.map(format).joined(separator: ","),
            "candidates": candidates.map(format).joined(separator: ","),
            "baselines": baselines.map {
                "\($0.deviceUID)\($0.isAnchor ? "(anchor)" : "")=\(String(format: "%.1f", $0.expectedDelayMs))"
            }.joined(separator: ","),
        ]
        switch outcome {
        case .observations(let observations):
            fields["result"] = observations.isEmpty ? "aligned" : "observations"
            fields["errors"] = observations.map {
                "\($0.deviceUID)=\(String(format: "%+.1f", $0.errorMs))\($0.isBestGuess ? "(guess)" : "")"
            }.joined(separator: ",")
        case .rebaselined(let shiftMs):
            fields["result"] = "rebaselined"
            fields["shiftMs"] = String(format: "%+.1f", shiftMs)
        case .unusable(let rejection):
            fields["result"] = "unusable"
            fields["rejection"] = rejection.rawValue
        case .blind:
            fields["result"] = "blind"
        }
        Telemetry.log(.localPlayback, "drift_window_result", fields)
    }

    static func mono(_ pcm: Data, channels: Int = PCMFormat.airplay.channels) -> [Float] {
        pcm.withUnsafeBytes { raw -> [Float] in
            let samples = raw.bindMemory(to: Int16.self)
            let frames = samples.count / channels
            let scale = Float(1) / (Float(Int16.max) + 1) / Float(channels)
            var out = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += Float(samples[frame * channels + channel])
                }
                out[frame] = sum * scale
            }
            return out
        }
    }
}
