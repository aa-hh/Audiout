// Copyright (C) 2026 ahh and contributors.
//
// LICENSE-CLEAN by design, like SyncProbeCorrelator.swift which it drives:
// no GPL SPDX header, and no GPL-derived code may move in.

import AVFoundation
import CoreAudio
import Foundation

extension ISO8601DateFormatter {
    /// Colons are legal in a macOS filename but the Finder shows them as `/`,
    /// so the dump stamp drops them.
    static let micProbeDumpStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime,
                           .withDashSeparatorInDate]
        return f
    }()
}

// MARK: - Mic permission

/// The microphone TCC gate for the probe (roadmap 064). A denied or
/// undecided mic is NEVER an error — the by-ear wizard is the fallback — so
/// this reports capability, not failure.
public enum MicCapturePermission {
    /// True only when macOS has already granted this app the microphone.
    public static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Ask if undecided (the system prompt), report the outcome either way.
    public static func ensure(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default: completion(false)
        }
    }
}

// MARK: - Recorder

/// What ``MicProbeSession`` needs from a microphone — seam for tests.
public protocol MicProbeRecording {
    /// Begin capturing; returns the capture sample rate.
    func start() throws -> Double
    /// Stop and hand back everything captured, mono.
    func stop() -> [Float]
}

/// Captures the Mac's BUILT-IN microphone, pinned by device ID.
///
/// Never the default input: with a Bluetooth speaker connected the default
/// input may BE that speaker's own mic, and opening it forces the A2DP→HFP
/// collapse this feature exists to avoid (PLAN-UNIVERSAL-SYNC risk R-A2DP/HFP).
public final class BuiltInMicRecorder: MicProbeRecording {

    public enum RecorderError: Error { case noBuiltInMicrophone }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []

    public init() {}

    public func start() throws -> Double {
        guard let mic = Self.builtInMicrophoneID() else {
            throw RecorderError.noBuiltInMicrophone
        }
        try engine.inputNode.auAudioUnit.setDeviceID(mic)
        // Pinning the device updates `inputFormat` but leaves `outputFormat`
        // reporting the PREVIOUS device's rate, and a tap installed with that
        // stale format (`format: nil` takes it) makes `start()` throw -10868
        // from InitializeActiveNodesInInputChain. Tap with the hardware format.
        let format = engine.inputNode.inputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [self] buffer, _ in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { return }
            let channels = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                for i in 0..<frames { mono[i] += data[c][i] }
            }
            if channels > 1 {
                let inverse = 1 / Float(channels)
                for i in 0..<frames { mono[i] *= inverse }
            }
            lock.lock(); samples.append(contentsOf: mono); lock.unlock()
        }
        engine.prepare()
        try engine.start()
        return format.sampleRate
    }

    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    /// The first built-in device with input channels — nil on a Mac without
    /// one (a headless mini), in which case the probe simply never runs.
    public static func builtInMicrophoneID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil,
                                             &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { return false }
            var configAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var configSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &configAddress, 0, nil,
                                                 &configSize) == noErr, configSize > 0
            else { return false }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(
                id, &configAddress, 0, nil, &configSize,
                raw.assumingMemoryBound(to: AudioBufferList.self)) == noErr else { return false }
            let buffers = UnsafeMutableAudioBufferListPointer(
                raw.assumingMemoryBound(to: AudioBufferList.self))
            return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
        }
    }
}

// MARK: - Session

/// One mic-probe measurement, end to end: start the built-in-mic capture,
/// have the wizard feed play the staged sweeps (DOWN on the engine/Mac lane,
/// UP on the Bluetooth lane), then matched-filter the capture and reduce it
/// to the one number the wizard wants — how many ms LATER the Bluetooth side
/// sounded than the reference.
///
/// The session never fails loudly: every path that cannot produce a
/// convincing measurement — permission lost, probe never armed (run torn
/// down), sweeps inaudible, low confidence — completes with `nil`, and the
/// by-ear wizard simply proceeds as it always has.
public final class MicProbeSession {

    public struct Result: Equatable {
        /// Bluetooth arrival minus reference arrival, ms. Positive = the
        /// Bluetooth speaker is late = its applied latency is this much too
        /// small.
        public let deltaMs: Double
        /// The weaker of the two arrivals' peak-to-sidelobe ratios.
        public let confidence: Double
    }

    /// Stages the sweeps on the live wizard feed; the two callbacks report
    /// the arm-gate opening and the last sweep frame entering the feed.
    public typealias StageProbe = (_ onStarted: @escaping () -> Void,
                                   _ onFinished: @escaping () -> Void) -> Void

    /// Must match `AlignmentTickInjector.probeSweepSeconds` — asserted by test.
    static let sweepSeconds = 1.0
    /// Air lags the feed by the sinks' pipeline delay (reference timeline,
    /// Bluetooth buffers). Generous ceiling; the correlator finds the arrivals
    /// wherever they land inside the capture.
    public static let pipelineTailSeconds = 3.0

    private let recorder: MicProbeRecording
    private let timeout: TimeInterval
    private let pipelineTail: TimeInterval
    private let queue = DispatchQueue(label: "mic-probe-session")
    private var sampleRate: Double = 0
    private var startedAt: Date?
    private var recordingBegan: Date?
    private var finished = false
    private var completion: ((Result?) -> Void)?

    public init(recorder: MicProbeRecording = BuiltInMicRecorder(),
                timeout: TimeInterval = 20,
                pipelineTail: TimeInterval = MicProbeSession.pipelineTailSeconds) {
        self.recorder = recorder
        self.timeout = timeout
        self.pipelineTail = pipelineTail
    }

    /// Kick the measurement off. `completion` is called exactly once, on the
    /// main queue.
    public func start(stage: @escaping StageProbe, completion: @escaping (Result?) -> Void) {
        queue.async { [self] in
            guard self.completion == nil, !finished else { return }
            self.completion = completion
            do {
                sampleRate = try recorder.start()
            } catch {
                Telemetry.log(.localPlayback, "mic_probe_recorder_failed",
                              ["error": String(describing: error)])
                finish(analyze: false)
                return
            }
            recordingBegan = Date()
            stage({ [weak self] in
                self?.queue.async { self?.startedAt = Date() }
            }, { [weak self] in
                guard let self else { return }
                self.queue.asyncAfter(deadline: .now() + self.pipelineTail) {
                    self.finish(analyze: true)
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(analyze: true)
            }
        }
    }

    /// Abandon the run (wizard cancelled). The recorder is stopped; the
    /// completion still fires, with nil.
    public func cancel() {
        queue.async { self.finish(analyze: false) }
    }

    /// `queue` only. Idempotent.
    private func finish(analyze: Bool) {
        guard !finished else { return }
        finished = true
        let recording = sampleRate > 0 ? recorder.stop() : []
        let result: Result? = analyze ? measure(recording: recording) : nil
        // Diagnosis hatch: AUDIOUT_MIC_PROBE_DUMP=1 keeps the raw capture
        // (mono Float32) beside the telemetry, so a refused measurement can
        // be analysed offline instead of guessed at. Debug only, nothing
        // reads it in a shipping run.
        //
        // One file PER RUN. A fixed name cost a whole investigation on
        // 2026-08-28: three runs failed, a fourth succeeded and overwrote
        // them, and the surviving bytes were analysed for hours as though
        // they were the failure. Refusals are exactly what a diagnosis hatch
        // exists to preserve, and they are the runs a retry follows.
        if ProcessInfo.processInfo.environment["AUDIOUT_MIC_PROBE_DUMP"] == "1",
           !recording.isEmpty {
            let stamp = ISO8601DateFormatter.micProbeDumpStamp.string(from: Date())
            let url = FileManager.default.urls(for: .libraryDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent(
                    "Logs/Audiout/mic-probe-\(stamp)-\(result != nil ? "ok" : "refused").f32")
            recording.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: url) }
            Telemetry.log(.localPlayback, "mic_probe_dump", [
                "path": url.path,
                "rate": String(Int(sampleRate)),
                "startedAtSeconds": startedAt.flatMap { started in
                    recordingBegan.map { String(format: "%.2f", started.timeIntervalSince($0)) }
                } ?? "-",
            ])
        }
        Telemetry.log(.localPlayback, "mic_probe_finished", [
            "ok": result != nil ? "1" : "0",
            "deltaMs": result.map { String(format: "%.2f", $0.deltaMs) } ?? "-",
            "confidence": result.map { String(format: "%.1f", $0.confidence) } ?? "-",
            "capturedSeconds": sampleRate > 0
                ? String(format: "%.1f", Double(recording.count) / sampleRate) : "0",
        ])
        let completion = completion
        self.completion = nil
        DispatchQueue.main.async { completion?(result) }
    }

    private func measure(recording: [Float]) -> Result? {
        guard sampleRate > 0, !recording.isEmpty else { return nil }
        // Ambient = the capture up to just before the sweeps entered the feed
        // (air can only lag the feed, so this slice is provably probe-free).
        var ambientEnd = 0
        if let startedAt, let recordingBegan {
            let seconds = startedAt.timeIntervalSince(recordingBegan) - 0.25
            ambientEnd = min(Int(seconds * sampleRate), recording.count)
        }
        return Self.analyze(recording: recording, sampleRate: sampleRate,
                            ambientEnd: ambientEnd)
    }

    /// The analysis, split from the wall-clock bookkeeping so tests can hand
    /// it a scene with an exact ambient boundary.
    ///
    /// The SNR weighting gets first go, but its failure is never the run's:
    /// the ambient slice describes the room BEFORE the sweeps, and during a
    /// wizard entry that slice legitimately carries the tail of the user's
    /// music still draining through the sinks' ~2 s delay (live finding,
    /// 2026-08-28: every probe measured fine acoustically and was then
    /// refused, because weighting by the music's spectrum crushed exactly
    /// the sweep band — for noise that was gone by sweep time). Weighting is
    /// an optimization for noise that is genuinely stationary; when it finds
    /// nothing, the plain matched filter decides.
    static func analyze(recording: [Float], sampleRate: Double,
                        ambientEnd: Int) -> Result? {
        let down = SyncProbe.samples(.downSweep(sampleRate: sampleRate,
                                                duration: sweepSeconds))
        let up = SyncProbe.samples(.upSweep(sampleRate: sampleRate,
                                            duration: sweepSeconds))
        let correlator = SyncProbeCorrelator(sampleRate: sampleRate)
        let ambient: [Float]? = ambientEnd > Int(0.3 * sampleRate)
            ? Array(recording[0..<ambientEnd]) : nil
        let measurement = ambient.flatMap {
            correlator.relativeOffset(probeA: down, probeB: up,
                                      recording: recording, ambientNoise: $0)
        } ?? correlator.relativeOffset(probeA: down, probeB: up,
                                       recording: recording, ambientNoise: nil)
        guard let m = measurement else { return nil }
        return Result(deltaMs: m.offsetSeconds * 1000,
                      confidence: min(m.arrivalA.peakToSidelobe, m.arrivalB.peakToSidelobe))
    }
}
