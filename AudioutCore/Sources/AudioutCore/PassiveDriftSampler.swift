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
        /// One peak inside more than one Bluetooth baseline's window and no
        /// other peak inside any of theirs: those speakers arrived TOGETHER.
        /// The baselines took that arrival as the sync point; nothing is
        /// corrected.
        case merged(deviceUIDs: [String], delayMs: Double)
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
    /// Every threshold as the correlator ships it, `minPeakToSidelobe`
    /// included.
    ///
    /// NEVER lower `minPeakToSidelobe` here to let a quiet arrival through.
    /// A true arrival in a living room scores 2.5 to 2.9 against the whole
    /// tape, so 2.3 looks like the fix and is the trap: at 2.3 the app
    /// accepted a peak that was no arrival within three windows and moved a
    /// speaker that had not moved (live test 2026-09-13, spec decision 15).
    /// The whole-tape background is mostly lags nowhere near the peak, so it
    /// cannot see the music's own next repeat, which is exactly what that
    /// false arrival was. The two gates the correlator applies beside it
    /// measure where the competition actually sits: the peak's height over
    /// the nearest rival lag, and its score against the 300 ms either side of
    /// it. Those are what a marginal window has to clear.
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
    /// recent window, clearing none of the correlator's gates. For the field
    /// log, so a refused window shows which gate stopped it, or that the
    /// arrival was outside the search at all. Empty when the slice was refused
    /// before correlating.
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
                                 ambientNoise: [Float]? = nil,
                                 countsTowardBlind: Bool = true) -> Outcome {
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
            if countsTowardBlind {
                consecutiveUnusableWindows += 1
                if consecutiveUnusableWindows >= Self.blindAfterUnusableWindows { isBlind = true }
            }
            return .unusable(rejection)
        case .usable(let peaks):
            consecutiveUnusableWindows = 0
            lastPeaks = peaks
            return attribute(peaks: peaks, hostNanos: hostNanos)
        }
    }

    /// A refused window worth one quick retry (spec decision 18): at least
    /// two of the three gates the correlator applies beside whole-tape
    /// confidence — margin, local score, agreeing bands — already cleared.
    /// Whole-tape `confidence` is excluded on purpose: decision 15 already
    /// moved the acceptance call onto the other three, so counting it again
    /// here would retry on the same signal that decision rejected.
    public static func isNearMiss(candidates: [DriftPeak], correlator: PassiveDriftCorrelator) -> Bool {
        candidates.contains { peak in
            let clearedGates = [
                peak.margin >= correlator.minPeakMargin,
                peak.localConfidence >= correlator.minLocalScore,
                peak.agreeingBands >= correlator.minAgreeingBands,
            ].filter { $0 }.count
            return clearedGates >= 2
        }
    }

    // MARK: - Attribution

    private struct Match {
        let baselineIndex: Int
        let deviationMs: Double
    }

    private mutating func attribute(peaks: [DriftPeak], hostNanos: Int64) -> Outcome {
        // Two speakers playing the same program IN SYNC merge into one peak,
        // and that is the state the user wants whatever the model expected: a
        // by-ear trim compensating a stale stored latency leaves the model
        // tens of ms off, so assigning the merged peak to the nearer speaker
        // corrected one of an in-sync pair (live test 2026-09-13, ruling:
        // treat as in sync). The baselines take the arrival as the sync point
        // and later windows measure departures from it.
        if let merged = mergedArrival(peaks: peaks) {
            for index in merged.baselineIndices {
                baselines[index].expectedDelayMs = merged.delayMs
            }
            return .merged(deviceUIDs: merged.baselineIndices.map { baselines[$0].deviceUID }.sorted(),
                           delayMs: merged.delayMs)
        }
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

    /// The peak that is the ONLY one inside the search window of more than one
    /// Bluetooth baseline, with the baselines it is that for.
    private func mergedArrival(peaks: [DriftPeak]) -> (baselineIndices: [Int], delayMs: Double)? {
        var solePeak: [Int: Int] = [:]   // baseline index → the one peak in its window
        for (b, baseline) in baselines.enumerated() where !baseline.isAnchor {
            let inside = peaks.indices.filter {
                abs(peaks[$0].delayMs - baseline.expectedDelayMs) <= searchHalfWidthMs
            }
            if inside.count == 1 { solePeak[b] = inside[0] }
        }
        let claimants = Dictionary(grouping: solePeak.keys) { solePeak[$0]! }
        guard let (peak, indices) = claimants.first(where: { $0.value.count > 1 }) else { return nil }
        return (indices.sorted(), peaks[peak].delayMs)
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
        /// The uid is what the once-per-minute-per-speaker rate limit and the
        /// clock-step storm classification key on.
        case clockJump(uid: String)
        /// This speaker's baseband link came back up. The uid is what the
        /// settling suppression keys on: a reconnecting sink's pacing clock
        /// keeps stepping while it re-buffers, and those steps are not worth
        /// a window.
        case reconnect(uid: String)
        case audioModeChange
        case silenceToAudio
        /// A guessed attribution is waiting to be checked — the window spec
        /// decision 7 promises, asked for by ``DriftCorrectionApplier``.
        case verify
        /// A near-miss window's single follow-up (spec decision 18), taken
        /// `retryDelaySeconds` after the refusal it answers. Never itself
        /// retried, and never counted toward the blind budget.
        case retry

        /// The case name alone, without payload — what the log's `"trigger"`
        /// field carries.
        var label: String {
            switch self {
            case .periodic: return "periodic"
            case .clockJump: return "clockJump"
            case .reconnect: return "reconnect"
            case .audioModeChange: return "audioModeChange"
            case .silenceToAudio: return "silenceToAudio"
            case .verify: return "verify"
            case .retry: return "retry"
            }
        }

        /// The speaker a clock step or a reconnect named; `nil` for every
        /// other trigger.
        var uid: String? {
            switch self {
            case .clockJump(let uid), .reconnect(let uid): return uid
            default: return nil
            }
        }
    }

    /// Long enough for the correlator, short enough to be cheap: the spec's
    /// "even 10 seconds is more than necessary". Longer buys nothing: the
    /// score is the peak over the whole correlation's background, and for
    /// music that background is the program's own structure, which grows
    /// with the window exactly as the peak does (8 s scored 2.49 where 4 s
    /// scored 2.56, live test 2026-09-13).
    static let windowSeconds = 4.0
    /// 25 minutes (spec decision 18). Live tests 2–4 showed inter-speaker
    /// drift is event-shaped — reconnect, a bad link, silence into audio —
    /// not a slow drift the old 3-minute cadence was built to catch, and a
    /// clock-step storm blinded the tracker in 25 s flat. The event triggers
    /// below do the real work; this is just the sparse backstop between them.
    static let periodicIntervalSeconds = 1500.0
    /// The first window lands here instead of at the full periodic interval:
    /// a fresh session is worth an early read.
    static let firstWindowSeconds = 180.0
    /// One quick follow-up after a near-miss refusal (spec decision 18).
    static let retryDelaySeconds = 30.0
    /// `BTClockStability.stableAfterSeconds` (10 s) is how long the pacing
    /// clock keeps stepping after a reconnect; this waits past that so the
    /// window lands on a sink that has actually settled, while staying well
    /// inside the "within 30 s" the acceptance bar wants.
    static let reconnectDelaySeconds = 15.0
    /// At most one clock-step window per speaker inside this span.
    static let clockStepWindowSpacingSeconds = 60.0
    /// This many steps from one speaker inside the spacing window is a bad
    /// link, not a run of real jumps.
    static let clockStepStormCount = 10
    /// Silence has to hold this long before the edge into audio counts as an
    /// event — a gap between tracks is not one.
    static let silenceEdgeSeconds = 60.0
    /// How often the silence poll checks `programIsSilent`.
    static let silencePollIntervalSeconds = 1.0
    /// Headroom past the deepest baseline so the reference slice still fits
    /// inside the capture once a speaker's delay has shifted it.
    static let searchMarginMs = 50.0

    private let ring: ReferenceAudioRing
    private let makeRecorder: @Sendable () -> MicProbeRecording
    private let permissionIsGranted: @Sendable () -> Bool
    private let programIsSilent: @Sendable () -> Bool
    private let now: @Sendable () -> TimeInterval
    private let isNearMiss: @Sendable ([DriftPeak], PassiveDriftCorrelator) -> Bool
    private let onObservations: @Sendable ([DriftCorrectionPolicy.Observation]) -> Void
    private let windowSeconds: Double
    private let intervalSeconds: Double
    private let firstWindowSeconds: Double
    private let retryDelaySeconds: Double
    private let reconnectDelaySeconds: Double
    private let silenceEdgeSeconds: Double
    private let pollIntervalSeconds: Double
    private let clockStepWindowSpacingSeconds: Double
    private let clockStepStormCount: Int
    private let queue = DispatchQueue(label: "com.audiout.passive-drift")

    /// `queue` only.
    private var sampler = PassiveDriftSampler()
    private var timer: DispatchSourceTimer?
    private var silenceTimer: DispatchSourceTimer?
    private var windowInFlight = false
    /// Whether periodic sampling is meant to be running — true between
    /// ``start()`` and ``stop()``, including a blind spell when the timer
    /// itself is cancelled.
    private var isRunning = false

    /// `queue` only. One clock-step rate-limit/storm state per speaker uid.
    private struct ClockStepState {
        /// Step times inside the last `clockStepWindowSpacingSeconds`, for the
        /// storm count.
        var stepTimes: [TimeInterval] = []
        /// When this speaker last took a window — set only when one actually
        /// started, so a skipped attempt never spends the slot.
        var lastWindowTime: TimeInterval?
        /// This speaker's most recent step, suppressed ones included: the
        /// bad-link clear measures its quiet gap from here.
        var lastStepTime: TimeInterval?
        /// Set by a reconnect: until this time, or until that reconnect's own
        /// window runs, this speaker's clock steps take no window of their
        /// own. `nil` when the speaker is not settling.
        var reconnectSettlingUntil: TimeInterval?
        var badLink = false
    }
    private var clockStepState: [String: ClockStepState] = [:]

    /// `queue` only. The silence-edge poll's own state: when the current
    /// silent spell started, `nil` while the program is audible.
    private var silentSince: TimeInterval?

    init(ring: ReferenceAudioRing,
         windowSeconds: Double = PassiveDriftTracker.windowSeconds,
         intervalSeconds: Double = PassiveDriftTracker.periodicIntervalSeconds,
         firstWindowSeconds: Double = PassiveDriftTracker.firstWindowSeconds,
         retryDelaySeconds: Double = PassiveDriftTracker.retryDelaySeconds,
         reconnectDelaySeconds: Double = PassiveDriftTracker.reconnectDelaySeconds,
         silenceEdgeSeconds: Double = PassiveDriftTracker.silenceEdgeSeconds,
         pollIntervalSeconds: Double = PassiveDriftTracker.silencePollIntervalSeconds,
         clockStepWindowSpacingSeconds: Double = PassiveDriftTracker.clockStepWindowSpacingSeconds,
         clockStepStormCount: Int = PassiveDriftTracker.clockStepStormCount,
         makeRecorder: @escaping @Sendable () -> MicProbeRecording = { BuiltInMicRecorder() },
         permissionIsGranted: @escaping @Sendable () -> Bool = { MicCapturePermission.isGranted },
         programIsSilent: @escaping @Sendable () -> Bool = { false },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         isNearMiss: @escaping @Sendable ([DriftPeak], PassiveDriftCorrelator) -> Bool = PassiveDriftSampler.isNearMiss,
         onObservations: @escaping @Sendable ([DriftCorrectionPolicy.Observation]) -> Void) {
        self.ring = ring
        self.windowSeconds = windowSeconds
        self.intervalSeconds = intervalSeconds
        self.firstWindowSeconds = firstWindowSeconds
        self.retryDelaySeconds = retryDelaySeconds
        self.reconnectDelaySeconds = reconnectDelaySeconds
        self.silenceEdgeSeconds = silenceEdgeSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.clockStepWindowSpacingSeconds = clockStepWindowSpacingSeconds
        self.clockStepStormCount = clockStepStormCount
        self.makeRecorder = makeRecorder
        self.permissionIsGranted = permissionIsGranted
        self.programIsSilent = programIsSilent
        self.now = now
        self.isNearMiss = isNearMiss
        self.onObservations = onObservations
    }

    deinit {
        timer?.cancel()
        silenceTimer?.cancel()
    }

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

    var consecutiveUnusableWindows: Int {
        queue.sync { sampler.consecutiveUnusableWindows }
    }

    func start() {
        queue.async { [self] in
            isRunning = true
            if timer == nil { scheduleTimer() }
            if silenceTimer == nil { scheduleSilencePoll() }
        }
    }

    func stop() {
        queue.async {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.silenceTimer?.cancel()
            self.silenceTimer = nil
            // Silence measured before the stop says nothing about the sink the
            // next start() builds: left set, the first poll after a restart
            // reads audible against it and takes a silence-to-audio window on a
            // sink one second old — the unsettled sink the reconnect delay
            // exists to avoid.
            self.silentSince = nil
        }
    }

    /// `queue` only.
    private func scheduleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + firstWindowSeconds, repeating: intervalSeconds)
        timer.setEventHandler { [weak self] in self?.takeWindow() }
        self.timer = timer
        timer.resume()
    }

    /// `queue` only.
    private func scheduleSilencePoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollIntervalSeconds, repeating: pollIntervalSeconds)
        timer.setEventHandler { [weak self] in self?.pollSilence() }
        self.silenceTimer = timer
        timer.resume()
    }

    /// `queue` only. A silent spell that held for `silenceEdgeSeconds` and
    /// then ended is an event (spec decision 18); a short gap between tracks
    /// is not.
    private func pollSilence() {
        if programIsSilent() {
            if silentSince == nil { silentSince = now() }
            return
        }
        if let since = silentSince, now() - since >= silenceEdgeSeconds {
            takeWindow(reason: .silenceToAudio)
        }
        silentSince = nil
    }

    /// Take a window now, unless one is already running. The reason names the
    /// seam that fired; the window itself is the same either way.
    func trigger(_ reason: Trigger) {
        queue.async {
            switch reason {
            case .clockJump(let uid):
                self.handleClockStep(uid: uid)
            case .reconnect(let uid):
                // Every step of the re-buffering burst below reaches
                // `handleClockStep`, and the first passes the rate limit
                // because nothing has used this speaker's allowance in a
                // minute — a window on a sink that is not rendering yet, spent
                // out of the five-window blind budget, and on a Move the burst
                // marks the link bad on top. The settled window scheduled here
                // is the one worth taking; the timeout is the backstop for a
                // reconnect whose window never fires.
                self.clockStepState[uid, default: ClockStepState()].reconnectSettlingUntil =
                    self.now() + self.clockStepWindowSpacingSeconds
                // The pacing clock is still settling for up to
                // `BTClockStability.stableAfterSeconds` after a reconnect.
                self.queue.asyncAfter(deadline: .now() + self.reconnectDelaySeconds) {
                    self.clockStepState[uid]?.reconnectSettlingUntil = nil
                    self.takeWindow(reason: .reconnect(uid: uid))
                }
            default:
                self.takeWindow(reason: reason)
            }
        }
    }

    /// `queue` only. Rate-limits and storm-classifies one speaker's clock
    /// steps, then takes a window when the step is allowed through.
    private func handleClockStep(uid: String) {
        let t = now()
        var state = clockStepState[uid] ?? ClockStepState()

        if let settlingUntil = state.reconnectSettlingUntil {
            guard t >= settlingUntil else {
                // A reconnecting sink's steps say only that it is still
                // re-buffering. `lastStepTime` moves anyway, exactly as the
                // bad-link path moves it, so the storm logic keeps measuring
                // real quiet on the link.
                state.lastStepTime = t
                clockStepState[uid] = state
                return
            }
            state.reconnectSettlingUntil = nil
        }

        if state.badLink {
            guard let lastStep = state.lastStepTime,
                  t - lastStep >= clockStepWindowSpacingSeconds
            else {
                // The gap is measured from the PREVIOUS step, suppressed ones
                // included, so only real quiet on the link clears it. Frozen at
                // the step that declared the storm, a link stepping every few
                // seconds cleared on schedule, took an unusable window and
                // re-stormed, over and over, until the mic went blind.
                state.lastStepTime = t
                clockStepState[uid] = state
                return
            }
            state.badLink = false
            state.stepTimes = []
            Telemetry.log(.localPlayback, "drift_clock_step_storm_cleared", ["uid": uid])
        }

        state.stepTimes.append(t)
        state.stepTimes.removeAll { t - $0 > clockStepWindowSpacingSeconds }
        state.lastStepTime = t

        if state.stepTimes.count >= clockStepStormCount {
            state.badLink = true
            clockStepState[uid] = state
            Telemetry.log(.localPlayback, "drift_clock_step_storm",
                          ["uid": uid, "steps": String(state.stepTimes.count)])
            return
        }

        if let lastWindow = state.lastWindowTime,
           t - lastWindow < clockStepWindowSpacingSeconds {
            clockStepState[uid] = state
            return
        }

        clockStepState[uid] = state
        // The limit counts windows that ran, not attempts: a step skipped
        // because one was already in flight must not silence this speaker's
        // next step for a minute and leave a real jump unmeasured.
        if takeWindow(reason: .clockJump(uid: uid)) {
            clockStepState[uid]?.lastWindowTime = t
        }
    }

    /// `queue` only.
    private func logFields(_ reason: Trigger, _ extra: [String: String]) -> [String: String] {
        var fields = extra
        fields["trigger"] = reason.label
        if let uid = reason.uid { fields["uid"] = uid }
        return fields
    }

    /// `queue` only. True when a window actually started.
    @discardableResult
    private func takeWindow(reason: Trigger = .periodic) -> Bool {
        let skip: String? = windowInFlight ? "window_in_flight"
            : sampler.isBlind ? "blind"
            : sampler.baselines.isEmpty ? "no_baselines"
            : !permissionIsGranted() ? "no_mic_permission" : nil
        if let skip {
            Telemetry.log(.localPlayback, "drift_window_skipped", logFields(reason, ["reason": skip]))
            return false
        }
        let recorder = makeRecorder()
        ring.setArmed(true)
        guard let captureRate = try? recorder.start(), captureRate > 0 else {
            ring.setArmed(false)
            Telemetry.log(.localPlayback, "drift_window_skipped",
                          logFields(reason, ["reason": "mic_start_failed"]))
            return false
        }
        Telemetry.log(.localPlayback, "drift_window_started",
                      logFields(reason, ["seconds": String(format: "%.1f", windowSeconds)]))
        windowInFlight = true
        queue.asyncAfter(deadline: .now() + windowSeconds) { [self] in
            finishWindow(recorder: recorder, captureRate: captureRate, reason: reason)
            ring.setArmed(false)
            windowInFlight = false
        }
        return true
    }

    /// `queue` only.
    private func finishWindow(recorder: MicProbeRecording, captureRate: Double, reason: Trigger) {
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

        let reference = Self.mono(slice.pcm)
        Self.dumpWindowIfEnabled(reference: reference, capture: capture,
                                 captureRate: captureRate, baselines: sampler.baselines)
        let outcome = sampler.analyze(
            reference: reference,
            referenceRate: Double(PCMFormat.airplay.sampleRate),
            capture: capture, captureRate: captureRate, hostNanos: startNanos,
            countsTowardBlind: reason != .retry)
        Self.logWindow(outcome, peaks: sampler.lastPeaks, candidates: sampler.lastCandidates,
                       baselines: sampler.baselines)
        if case .observations(let observations) = outcome, !observations.isEmpty {
            onObservations(observations)
        }
        if reason != .retry, case .unusable(.noConvincingPeak) = outcome,
           isNearMiss(sampler.lastCandidates, sampler.correlator) {
            // The retry's own `drift_window_started` line carries
            // `trigger: retry`, so nothing extra is logged here.
            queue.asyncAfter(deadline: .now() + retryDelaySeconds) { [weak self] in
                self?.takeWindow(reason: .retry)
            }
        }
        if sampler.isBlind { timer?.cancel(); timer = nil }
    }

    /// Diagnostic only: with `defaults write <bundle id> audiout.driftDumpWindows
    /// -bool YES`, every measured window's reference and capture are written
    /// as raw little-endian Float32 mono under ~/Library/Logs/Audiout/drift-windows/,
    /// with a sidecar naming the rates and baselines, so a window can be
    /// analysed offline against the correlator's verdict (live test
    /// 2026-09-13: scores stayed marginal at any volume, genre or distance).
    /// razor: no rotation, no size cap — turn it off when done.
    private static func dumpWindowIfEnabled(reference: [Float], capture: [Float],
                                            captureRate: Double,
                                            baselines: [PassiveDriftSampler.Baseline]) {
        guard UserDefaults.standard.bool(forKey: "audiout.driftDumpWindows") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Audiout/drift-windows", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        func write(_ samples: [Float], _ suffix: String) {
            samples.withUnsafeBufferPointer { buf in
                try? Data(buffer: buf).write(to: dir.appendingPathComponent("\(stamp)-\(suffix).f32"))
            }
        }
        write(reference, "ref")
        write(capture, "cap")
        let meta: [String: Any] = [
            "referenceRate": PCMFormat.airplay.sampleRate,
            "captureRate": captureRate,
            "baselines": baselines.map { ["uid": $0.deviceUID, "expectedDelayMs": $0.expectedDelayMs,
                                          "anchor": $0.isAnchor] },
        ]
        if let json = try? JSONSerialization.data(withJSONObject: meta) {
            try? json.write(to: dir.appendingPathComponent("\(stamp)-meta.json"))
        }
    }

    /// The ring's interleaved S16LE frames as the mono float the correlator
    /// takes.
    /// One local line per measured window: what the correlator heard, what the
    /// sampler made of it. Local only — `Telemetry.log` never leaves the Mac,
    /// so device ids are allowed here.
    static func logWindow(_ outcome: PassiveDriftSampler.Outcome, peaks: [DriftPeak],
                          candidates: [DriftPeak],
                          baselines: [PassiveDriftSampler.Baseline]) {
        // delay@score/local/margin: the whole-tape score, then the two numbers
        // that decide whether the peak is an arrival or the music's own next
        // repeat. Reading a refused window means reading all three, so all
        // three go in the line.
        let format = { (p: DriftPeak) in
            String(format: "%.1fms@%.1f/%.1f/%.1f",
                   p.delayMs, p.confidence, p.localConfidence, p.margin)
        }
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
        case .merged(let deviceUIDs, let delayMs):
            fields["result"] = "merged"
            fields["devices"] = deviceUIDs.joined(separator: ",")
            fields["delayMs"] = String(format: "%.1f", delayMs)
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
