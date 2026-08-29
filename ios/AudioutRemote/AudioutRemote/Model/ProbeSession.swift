// Copyright (c) 2026 ahh. All rights reserved.

import Foundation
import ProbeKit

/// One alignment measurement end to end, from the phone's side: start the
/// microphone, let the Mac's two staged sweeps play into the room, then
/// matched-filter the capture down to the single number the Mac asked for —
/// how many ms LATER the target speaker sounded than the reference.
///
/// This is the Mac's `MicProbeSession` (roadmap 064) with one structural
/// difference. On the Mac a single process both stages the sweeps and
/// records, so that session drives the staging itself through a closure.
/// Here the MAC stages the sweeps and the phone only listens, so the two
/// moments that bound the run — the sweeps entering the feed, and the last
/// sweep frame entering it — are reported in from outside, via
/// ``probeDidStart()`` and ``probeDidFinish()``. The driver that learns those
/// moments from the Mac over the network is not built yet; this type is the
/// half that does not depend on how they arrive.
///
/// The session never fails loudly. Every path that cannot produce a
/// convincing measurement completes with a ``Refusal`` and no number, and the
/// wizard falls back to asking the user by ear — a wrong alignment is worse
/// than none. The refusal says WHY only so the UI can be truthful about it.
///
/// RAW measurement only: the phone reports what it heard, the Mac owns what
/// that means for a device's trim.
///
/// **One session measures once.** A retry — after a refusal or a good
/// reading — builds a new `ProbeSession`; the microphone, the tape and the
/// run's timing all belong to the run, and reusing them would mean tearing
/// each one down correctly for no gain. A second ``start(completion:)``
/// refuses through the completion, never silently.
@MainActor
final class ProbeSession {

    /// Why a run produced no number. Not a failure to put in front of the
    /// user as an error — the by-ear path is a perfectly good outcome — just
    /// enough detail for the UI to say something true about why it is asking.
    enum Refusal: Error {
        /// The microphone was never granted (denied, or never asked for).
        case permissionDenied
        /// The recording could not be started at all — see
        /// ``ProbeCaptureSession/CaptureError``.
        case captureFailed(any Error)
        /// The run was abandoned before it could be measured.
        case cancelled
        /// The tape was recorded but the sweeps were not found in it
        /// convincingly.
        case notMeasured(ProbeAnalysisError)
        /// An interruption or a route change landed mid-run, so the tape is
        /// truncated or spliced across two hardware sample rates. It is not
        /// measured at all: each sweep would still correlate confidently on
        /// its own and the offset would come back quietly scaled.
        case captureDisrupted(ProbeCaptureSession.Disruption)
        /// ``start(completion:)`` was called on a session that has already
        /// been started. A retry needs a NEW session — see the type's note.
        case alreadyStarted
    }

    /// How long the tape keeps running after the last sweep frame enters the
    /// feed. Air lags the feed by the sinks' own pipeline delay — the
    /// reference timeline's, and Bluetooth buffers deeply — so the sound is
    /// still in flight when the feed is done with it. A generous ceiling; the
    /// correlator finds the arrivals wherever they land inside the capture.
    static let pipelineTailSeconds: TimeInterval = 3

    /// Backstop for a run that is never finished — the Mac goes quiet, the
    /// connection drops — so the completion always fires. The tape itself
    /// stops earlier regardless, at ``ProbeCaptureSession/maxDuration``; this
    /// only bounds how long the session waits before measuring what it has.
    static let timeoutSeconds: TimeInterval = 20

    /// Guard interval subtracted from the ambient slice, so that slice ends
    /// safely before the sweeps could reach the mic even at zero distance.
    private nonisolated static let ambientGuardSeconds: TimeInterval = 0.25

    /// How long the tape must already have been running before the driver
    /// asks the Mac to stage the sweeps.
    ///
    /// The arithmetic, because it is easy to re-break: the ambient slice is
    /// the lead-in MINUS ``ambientGuardSeconds`` (0.25 s), and
    /// `ProbeAnalyzer.minimumAmbientSeconds` (0.3 s) ignores anything
    /// shorter than that floor. So a lead-in of 0.55 s or less leaves no
    /// usable slice at all and the SNR-weighted pass — the whole reason the
    /// Mac's correlator beats plain whitening — becomes dead code that never
    /// runs. 1 s of lead-in leaves 0.75 s of ambient, clear of the floor by
    /// 0.45 s: slack for the jitter in when the network round-trip actually
    /// lands. Raise the lead-in if that ever proves tight — never the guard
    /// or the floor, which match the Mac.
    static let minimumLeadInSeconds: TimeInterval = 1.0

    private let capture: ProbeCaptureSession
    private let pipelineTail: TimeInterval
    private let timeout: TimeInterval

    private var completion: ((Result<ProbeAnalysis, Refusal>) -> Void)?
    /// Monotonic, not wall clock: a clock correction landing mid-run would
    /// move the ambient boundary. Same reasoning as `WallCommandClock`.
    private var recordingBegan: TimeInterval?
    /// How far into the tape the sweeps entered the feed, in seconds.
    private var probeStartedAfter: TimeInterval?
    private var tailTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hasStarted = false
    private var isFinished = false

    init(capture: ProbeCaptureSession = ProbeCaptureSession(),
         pipelineTail: TimeInterval = ProbeSession.pipelineTailSeconds,
         timeout: TimeInterval = ProbeSession.timeoutSeconds) {
        self.capture = capture
        self.pipelineTail = pipelineTail
        self.timeout = timeout
    }

    /// Start recording and hand back to the driver, which asks the Mac to
    /// stage the sweeps and then reports the two moments below. The recorder
    /// starts BEFORE the sweeps are staged, on purpose: the lead-in it
    /// captures is what the analyzer weights the room's noise by — so the
    /// driver must wait at least ``minimumLeadInSeconds`` after this call
    /// before asking the Mac to fire.
    ///
    /// `completion` runs exactly once, on the main actor, and never before
    /// this call returns — including on a second `start`, which refuses with
    /// ``Refusal/alreadyStarted`` rather than going quiet. Ask for the
    /// microphone with `ProbeCaptureSession.requestPermission()` first — this
    /// does not itself request access.
    func start(completion: @escaping (Result<ProbeAnalysis, Refusal>) -> Void) {
        guard !hasStarted else {
            Task { completion(.failure(.alreadyStarted)) }
            return
        }
        hasStarted = true
        self.completion = completion

        guard ProbeCaptureSession.permissionGranted else {
            refuse(.permissionDenied)
            return
        }
        do {
            try capture.start()
        } catch {
            refuse(.captureFailed(error))
            return
        }
        recordingBegan = ProcessInfo.processInfo.systemUptime

        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.measureAndComplete()
        }
    }

    /// The sweeps entered the Mac's feed. Everything on the tape before this
    /// is provably probe-free — air can only LAG the feed, never lead it — so
    /// it becomes the ambient slice.
    func probeDidStart() {
        guard !isFinished, let recordingBegan else { return }
        probeStartedAfter = ProcessInfo.processInfo.systemUptime - recordingBegan
    }

    /// The last sweep frame entered the feed. The tape runs on for the
    /// pipeline tail, then the run is measured.
    func probeDidFinish() {
        guard !isFinished, tailTask == nil else { return }
        tailTask = Task { [weak self, pipelineTail] in
            try? await Task.sleep(for: .seconds(pipelineTail))
            guard !Task.isCancelled else { return }
            self?.measureAndComplete()
        }
    }

    /// Abandon the run — the user backed out, the Mac dropped. The recorder
    /// stops and the completion still fires, refused.
    func cancel() {
        refuse(.cancelled)
    }

    // MARK: Finishing

    /// Stop the tape and hand back what was captured, once. `nil` means the
    /// run was already over and the caller must do nothing further.
    private func endRun() -> [Float]? {
        guard !isFinished else { return nil }
        isFinished = true
        tailTask?.cancel()
        tailTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        return capture.stop()
    }

    private func refuse(_ refusal: Refusal) {
        guard endRun() != nil, let completion else { return }
        self.completion = nil
        // Asynchronous even for a refusal decided inside `start` itself — a
        // completion that re-enters its caller mid-call is a trap.
        Task { completion(.failure(refusal)) }
    }

    private func measureAndComplete() {
        guard let recording = endRun(), let completion else { return }
        self.completion = nil
        // A disrupted tape is thrown away unmeasured. It is the one failure
        // the analyzer cannot see: both sweeps survive a splice individually,
        // so confidence stays high while the offset between them is scaled by
        // whatever the rate changed to.
        if let disruption = capture.disruption {
            Task { completion(.failure(.captureDisrupted(disruption))) }
            return
        }
        let sampleRate = capture.sampleRate
        let ambientEnd = Self.ambientEndSample(startedAfter: probeStartedAfter,
                                               sampleRate: sampleRate,
                                               captureCount: recording.count)
        Task {
            let outcome = await Self.analyze(recording: recording, sampleRate: sampleRate,
                                             ambientEndSample: ambientEnd)
            completion(outcome.mapError(Refusal.notMeasured))
        }
    }

    /// Where the probe-free lead-in ends, in samples: the tape up to just
    /// before the sweeps entered the feed, less ``ambientGuardSeconds``. 0
    /// when the driver never reported a start — the analyzer then measures
    /// unweighted, which is a normal outcome rather than a failed one.
    nonisolated static func ambientEndSample(startedAfter seconds: TimeInterval?,
                                             sampleRate: Double,
                                             captureCount: Int) -> Int {
        guard let seconds, sampleRate > 0 else { return 0 }
        return max(0, min(Int((seconds - ambientGuardSeconds) * sampleRate), captureCount))
    }

    /// Off the main actor: a matched filter over the whole tape is hundreds
    /// of milliseconds of FFT, and the wizard is on screen while it runs.
    private nonisolated static func analyze(
        recording: [Float], sampleRate: Double, ambientEndSample: Int
    ) async -> Result<ProbeAnalysis, ProbeAnalysisError> {
        do {
            return .success(try ProbeAnalyzer(sampleRate: sampleRate)
                .analyze(recording: recording, ambientEndSample: ambientEndSample))
        } catch {
            // `analyze` only throws `ProbeAnalysisError`; the fallback keeps
            // an unexpected error a refusal rather than a crash.
            return .failure(error as? ProbeAnalysisError ?? .probeNotFound)
        }
    }
}
