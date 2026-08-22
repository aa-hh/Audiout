// SPDX-License-Identifier: GPL-2.0-or-later

import AVFoundation

/// Mic capture for the BT auto-cal spike's alignment probe
/// (dev/notes/bt-autocal-spike-spec.md). The phone records continuously
/// while the Mac alternately mutes the target/reference devices against a
/// tick bed; this type owns nothing about that pattern — it just accumulates
/// mono Float32 samples for ``ProbeKit/ProbeAnalyzer`` to read afterwards.
///
/// **Never opens a Bluetooth input.** The spec calls this out explicitly:
/// if the phone's own audio session pulled in a paired Bluetooth input, iOS
/// could force that same speaker into HFP call mode — corrupting the very
/// measurement being taken. So the session category carries no Bluetooth
/// options at all, and the input is pinned to the built-in mic rather than
/// left to whatever the system would otherwise prefer.
final class ProbeCaptureSession: @unchecked Sendable {
    enum CaptureError: Error {
        case builtInMicUnavailable
        case sessionConfigurationFailed(any Error)
        case engineStartFailed(any Error)
    }

    /// Hard cap regardless of what the Mac-side run does — a stuck probe
    /// must never record forever.
    static let maxDuration: TimeInterval = 90

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "AudiouterRemote.ProbeCapture")
    private var samples: [Float] = []
    private var stopWorkItem: DispatchWorkItem?
    private(set) var sampleRate: Double = 0

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
            // (AGC, noise suppression) that would otherwise distort tick
            // timing; the empty options set is deliberate — no
            // `.allowBluetooth`/`.allowBluetoothA2DP` of any kind.
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

        queue.sync { samples.removeAll() }
        sampleRate = session.sampleRate

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
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
            self.queue.async { self.samples.append(contentsOf: mono) }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        let workItem = DispatchWorkItem { [weak self] in _ = self?.stop() }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration, execute: workItem)
    }

    /// Tears down the tap/engine and returns everything captured so far.
    /// Safe to call more than once (a no-op after the first).
    @discardableResult
    func stop() -> [Float] {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return queue.sync { samples }
    }
}
