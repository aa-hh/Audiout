// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation

/// Mic capture for the alignment probe. The Mac stages two simultaneous
/// exponential sine sweeps — a down sweep on the reference fan-out, an up
/// sweep on the Bluetooth fan-out — and the phone records both arriving at
/// one microphone; this type owns nothing about that pattern, it just
/// accumulates mono Float32 samples for ``ProbeKit/ProbeAnalyzer`` to
/// matched-filter afterwards.
///
/// **Never opens a Bluetooth input.** If the phone's own audio session
/// pulled in a paired Bluetooth input, iOS could force that same speaker
/// into HFP call mode — corrupting the very measurement being taken. So the
/// session category carries no Bluetooth options at all, and the input is
/// pinned to the built-in mic rather than left to whatever the system would
/// otherwise prefer.
final class ProbeCaptureSession: @unchecked Sendable {
    enum CaptureError: Error {
        case builtInMicUnavailable
        case sessionConfigurationFailed(any Error)
        case engineStartFailed(any Error)
        /// The input node reported a 0 Hz format — no usable hardware rate,
        /// so there is no rate to synthesize sweeps at or divide lags by.
        case noCaptureFormat
    }

    /// Why a capture stopped being trustworthy part-way through. Both of
    /// these end the run: the tape can no longer be described by one sample
    /// rate and one continuous stretch of time, and nothing downstream could
    /// tell — each sweep still correlates on its own, so the confidence stays
    /// high and the offset comes out silently scaled.
    enum Disruption: Sendable {
        /// Siri, a phone call, another app taking the session: the tape is
        /// truncated wherever the interruption landed.
        case interrupted
        /// A route change or media-services reset (charger, CarPlay,
        /// accessory). The engine reconfigures and buffers resume at a NEW
        /// hardware rate, appending to samples taken at the old one.
        case configurationChanged
    }

    /// Hard cap regardless of what the Mac-side run does — a stuck probe must
    /// never record forever. About 5.5 s of tape is what a run actually uses:
    /// 1 s of ambient lead-in before the Mac is asked to fire (see
    /// ``ProbeSession/minimumLeadInSeconds``), the Mac's 0.5 s scheduling
    /// lead, the 1 s sweep, and ``ProbeSession/pipelineTailSeconds`` (3 s) of
    /// air still in flight after the feed is done with it. The rest of this
    /// ceiling is slack for the network round-trip that asks the Mac to fire,
    /// not room the measurement itself uses.
    static let maxDuration: TimeInterval = 15

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "AudioutRemote.ProbeCapture")
    private var samples: [Float] = []
    private var stopWorkItem: DispatchWorkItem?
    private var observers: [any NSObjectProtocol] = []
    private var disruptionReason: Disruption?

    /// The rate the samples were ACTUALLY produced at — the input tap's own
    /// format, never `AVAudioSession.sampleRate`. The two can disagree (a
    /// route settling after `setPreferredInput`, another app holding the
    /// session, hardware renegotiated by `engine.start()`), and the analyzer
    /// both synthesizes its sweep templates at this rate and divides sample
    /// lags by it — so a 48000-vs-44100 slip would scale every reading by
    /// 8.8% against a mismatched template, with nothing to notice it.
    private(set) var sampleRate: Double = 0

    /// Non-nil once the run stopped being trustworthy; the caller must refuse
    /// rather than measure. Nil for a clean run.
    var disruption: Disruption? { queue.sync { disruptionReason } }

    /// Whether the mic can be used without prompting again: `true` only for
    /// `.granted`, so the caller knows to show the denied state instead of
    /// (re)requesting for `.denied`.
    static var permissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    static var permissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    /// Resolves once the user has answered (or immediately, if already
    /// answered). `true` iff capture may proceed.
    static func requestPermission() async -> Bool {
        if permissionGranted { return true }
        if permissionDenied { return false }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Configures the session, pins the built-in mic, and starts the input
    /// tap. Call ``requestPermission()`` first — this does not itself
    /// request access.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.measurement` disables the system's own signal processing
            // (AGC, noise suppression) that would otherwise smear the
            // sweeps' arrival times; the empty options set is deliberate —
            // no `.allowBluetooth`/`.allowBluetoothA2DP` of any kind.
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            throw CaptureError.sessionConfigurationFailed(error)
        }

        guard let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            throw CaptureError.builtInMicUnavailable
        }
        do {
            try session.setPreferredInput(builtInMic)
        } catch {
            throw CaptureError.sessionConfigurationFailed(error)
        }
        // `.measurement` disables AGC, so the gain sits at the hardware
        // default — observed too low to hear the probe over the mic's own
        // noise floor (live finding). Pin it to maximum where the hardware
        // allows; failure is fine, it just stays at the default.
        if session.isInputGainSettable {
            try? session.setInputGain(1.0)
        }

        queue.sync {
            samples.removeAll()
            disruptionReason = nil
        }

        let input = engine.inputNode
        // The tap's format is what the buffers arrive in, so it — not the
        // session — is the authoritative rate. Same choice the Mac's
        // `BuiltInMicRecorder.start()` makes, for the same reason.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw CaptureError.noCaptureFormat }
        sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }
            // Down-mix to mono regardless of the hardware's native channel
            // count — the analyzer's contract is a single Float32 stream.
            var mono = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let data = channelData[channel]
                for i in 0..<frameCount { mono[i] += data[i] / Float(channelCount) }
            }
            // Capture `mono` by value: the tap block runs on the render
            // thread and must not hand the accumulator a buffer it could
            // still be writing to.
            self.queue.async { [mono] in self.samples.append(contentsOf: mono) }
        }

        // Watch for the two ways the tape can stop meaning one thing, from
        // before the engine starts so a change during start-up is caught.
        // Neither is repaired: a spliced or truncated tape is discarded, not
        // resampled — a wrong alignment number is worse than none.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: session, queue: nil) { [weak self] _ in
                self?.invalidate(.interrupted)
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange,
                               object: engine, queue: nil) { [weak self] _ in
                self?.invalidate(.configurationChanged)
            },
        ]

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObservers()
            throw CaptureError.engineStartFailed(error)
        }

        let workItem = DispatchWorkItem { [weak self] in _ = self?.stop() }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration, execute: workItem)
    }

    /// First disruption wins — later ones are the same run coming apart, and
    /// the earliest is the one that describes where the tape stopped being
    /// one recording.
    private func invalidate(_ reason: Disruption) {
        queue.async { [self] in
            if disruptionReason == nil { disruptionReason = reason }
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Tears down the tap/engine and returns everything captured so far.
    /// Safe to call more than once (a no-op after the first). Check
    /// ``disruption`` before trusting what comes back.
    ///
    /// Main queue only, like ``start()``. The class is `@unchecked Sendable`
    /// for the tap's sake — the tap block is the ONLY thing that touches
    /// `samples`, and it does so behind `queue`. Everything else here
    /// (`stopWorkItem`, `observers`, the engine) is unguarded and stays
    /// correct only because one queue drives it.
    @discardableResult
    func stop() -> [Float] {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        removeObservers()
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return queue.sync { samples }
    }

    /// A run that is abandoned rather than finished — the owner drops the
    /// session mid-measurement — still has a live engine, an active audio
    /// session and two notification observers. Nothing else reaches `stop()`
    /// on that path: the timeout and the duration cap both hold the session
    /// weakly, so neither fires. Left alone it is a microphone that stays hot
    /// after the wizard has gone.
    deinit { stop() }
}
