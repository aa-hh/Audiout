// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if canImport(AudioToolbox)
import AudioToolbox
import AVFoundation
import CoreGraphics
import Darwin   // dlopen/dlsym for the private TCC audio-capture status read
#endif

/// Constructs the production ``AudioCapturePermissionProbing`` for this OS.
///
/// On macOS 14.2+ (the process-tap floor) this is ``CoreAudioTonePermissionProbe``
/// — a self-test that plays a brief tone and listens for it to verify the grant
/// for real. On older systems the tap API doesn't exist, so there's no permission
/// to grant and the probe reports ``PermissionStatus/unsupported`` without
/// touching Core Audio.
public enum AudioCapturePermissionProbeFactory {
    public static func makeDefault() -> AudioCapturePermissionProbing {
        #if canImport(AudioToolbox)
        if #available(macOS 14.2, *) {
            return CoreAudioTonePermissionProbe()
        }
        #endif
        return UnsupportedAudioCaptureProbe()
    }
}

/// Fallback for macOS < 14.2, where `AudioHardwareCreateProcessTap` doesn't
/// exist. No grant could enable capture, so we report `.unsupported` (distinct
/// from `.denied`, which would wrongly invite the user to "fix" it in Settings).
public struct UnsupportedAudioCaptureProbe: AudioCapturePermissionProbing {
    public init() {}
    public func probe() async -> PermissionStatus { .unsupported }
}

#if canImport(AudioToolbox)

/// The self-test that both TRIGGERS and VERIFIES the system-audio-capture (TCC)
/// permission, using only public API.
///
/// ## Why this exists (the problem it solves)
/// macOS gives process taps no request-or-check API: creating the tap surfaces
/// the prompt lazily, and a *denied* tap is still created successfully — it just
/// delivers all-zero buffers (`AudioHardwareCreateProcessTap` returns `noErr`
/// either way). So a probe can't read the answer from a return code; the only
/// public signal is whether captured audio is silent. Silence is ambiguous with
/// "nothing is playing," so we supply our own known audio and check for it.
///
/// ## The tone IS audible — the UI warns first
/// The quiet sine below plays to the default output through AVAudioEngine, so the
/// user DOES hear a brief beep (the tap's `.muted` only governs the tap's own
/// re-routing, not this playback path — an earlier "the user hears nothing" claim
/// here was wrong, and the surprise beep is exactly what got it flagged). Rather
/// than chase a truly-silent capture, the System Audio row's copy tells the user a
/// brief tone will play when they Allow, so it's expected — a known, deliberate
/// beep beats a mystery one. Keep that row copy and this behavior in sync.
///
/// ## How it works
/// 1. Play a quiet sine **in this process**, rendered to the default output
///    (audible — see above).
/// 2. Tap **only this process** (`CATapDescription(stereoMixdownOfProcesses:)`),
///    `muteBehavior = .muted`. Tapping only ourselves keeps it off everyone else's
///    audio (a global tap would capture ambient audio, risking a false "granted"
///    and contradicting the app's whole privacy promise).
/// 3. Read the tap for ~300 ms and take the peak sample level.
///    - peak clearly above zero → the tap delivered our tone → **granted**.
///    - peak ~zero → the tap delivered the denied-tap zeros → **denied**.
/// 4. Tear everything down promptly (the tap lives < 0.5 s), so no lingering
///    system tap or muted state.
///
/// ## ⚠️ GATED — needs ahh's live verification
/// Every other part of the setup flow is unit-tested, but this file drives real
/// Core Audio and the TCC prompt, which cannot run in CI or an agent shell
/// (unsigned/ad-hoc binaries don't get a stable TCC identity, and a shell-
/// launched process inherits the terminal's grant — see the onboarding AGENTS
/// notes and `dev/notes/p2b-nativebackend-runbook.md`). It is written to mirror
/// the proven ``CoreAudioSystemTap`` aggregate recipe, but the granted-vs-denied
/// behavior must be confirmed by ear/log on a signed build during a gated
/// session before this ships. Manual recipe: build via `scripts/make-app.sh`,
/// `open` the app, run setup, and check the tone probe reports `.granted` only
/// after the System Settings toggle is on.
@available(macOS 14.2, *)
public final class CoreAudioTonePermissionProbe: AudioCapturePermissionProbing, @unchecked Sendable {

    /// Sine level (0…1). Quiet, but far above the zero floor a denied tap emits.
    private let toneAmplitude: Float = 0.1
    private let toneHz: Double = 440
    /// How long to observe the tap before deciding (≈30 IOProc callbacks @ 48 k).
    private let observeSeconds: TimeInterval = 0.30
    /// Let the engine + HAL register this process as an audio client before we
    /// translate our pid to a process object (a process with no audio stream
    /// isn't a known Core Audio process yet).
    private let warmupSeconds: TimeInterval = 0.10
    /// Peak above this ⇒ real audio; a denied tap delivers exact zeros, so this
    /// only has to clear numerical dither.
    private let grantedPeakThreshold: Float = 0.005

    public init() {}

    public func probe() async -> PermissionStatus {
        // All Core Audio + the observation sleep run off the main actor.
        await withCheckedContinuation { (continuation: CheckedContinuation<PermissionStatus, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runProbe())
            }
        }
    }

    /// The whole synchronous probe: play tone → tap self → observe → decide →
    /// tear down. Runs on a background queue.
    private func runProbe() -> PermissionStatus {
        let tone = TonePlayer(amplitude: toneAmplitude, hz: toneHz)
        guard tone.start() else {
            // We couldn't even produce our own audio — can't verify. Treat as
            // denied so the UI points the user at Settings rather than claiming
            // success we didn't observe.
            return .denied
        }
        defer { tone.stop() }

        // Let the HAL register us as an audio process before translating our pid.
        Thread.sleep(forTimeInterval: warmupSeconds)

        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let processObject = try? Self.translatePIDToProcessObject(selfPID),
              processObject != kAudioObjectUnknown else {
            return .denied
        }

        let tap = SelfProcessTap(processObject: processObject)
        guard tap.start() else { return .denied }
        defer { tap.teardown() }

        // Observe the tap. If capture is denied every sample is zero; if granted
        // we see our sine.
        Thread.sleep(forTimeInterval: observeSeconds)

        let peak = tap.peak()
        return peak > grantedPeakThreshold ? .granted : .denied
    }

    /// Silent revocation-detection path, used by BOTH
    /// `SetupModel.auditRequiredPermissions()` (post-onboarding reactivate/wake
    /// watch) AND `SetupModel.refreshStatuses()` (the onboarding window's own
    /// reactivation refresh — see the ONBOARD-TONE fix): no tone, no tap, no
    /// prompt — just a read of the live TCC decision. `probe()` above
    /// deliberately triggers the audible self-test tone because it's the only
    /// way to distinguish "granted" from "denied" for the explicit "Allow…"
    /// gesture; firing that tone on every reactivate — including a bare Cmd+Tab
    /// away and back while onboarding is still open — would be user-hostile.
    /// The silent read queries the **System Audio Recording Only** bucket
    /// (`kTCCServiceAudioCapture`) directly — NOT `CGPreflightScreenCaptureAccess()`,
    /// which reports the wrong permission on macOS 14.4+ (see the detailed note on
    /// `currentStatusSilently()` below).
    public func currentStatusSilently() -> PermissionStatus? {
        switch Self.systemAudioCaptureAuthorization() {
        case .granted: return .granted
        case .denied:  return .denied
        case .undetermined, .none:
            // Not yet decided, or the private symbol/service is unavailable
            // (pre-14.4, where the tap grant still lived under Screen Recording).
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    /// tccd's authorization values for `TCCAccessPreflight` (private TCC API).
    private enum TCCPreflightResult { case granted, denied, undetermined }

    /// Live authorization for the "System Audio Recording Only" bucket
    /// (`kTCCServiceAudioCapture`), read through the private `TCCAccessPreflight`
    /// symbol. Returns `nil` when the TCC framework or symbol can't be resolved.
    /// See `currentStatusSilently()` for why this private read is necessary.
    private static func systemAudioCaptureAuthorization() -> TCCPreflightResult? {
        typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
        // dyld resolves this from the shared cache even though the file isn't on
        // disk. Intentionally NOT dlclose'd: the framework stays resident (AppKit
        // uses it too) and the handle lives for the process's lifetime.
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else {
            return nil
        }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0:  return .granted        // kTCCAccessPreflightGranted
        case 1:  return .denied         // kTCCAccessPreflightDenied
        default: return .undetermined   // kTCCAccessPreflightUnknown (2)
        }
    }

    // MARK: pid → Core Audio process object (mirrors dev/audiocap CAHelpers)

    /// Translate a Unix pid to its Core Audio process `AudioObjectID`. The pid
    /// rides as the property qualifier on the system object. Throws if the pid
    /// isn't a known audio process (hasn't opened an audio stream yet) — which is
    /// why the caller starts the tone first.
    static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidQualifier = pid
        var objID: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidQualifier,
            &size, &objID)
        guard err == noErr else {
            throw NativeCaptureError.tapCreationFailed(reason: "translate pid \(pid) \(err)")
        }
        return objID
    }
}

// MARK: - Tone player (quiet in-process sine)

/// A minimal AVAudioEngine sine into the default output. It exists only to give
/// the self-test tap something non-silent from THIS process to capture; the tap's
/// `.muted` behavior keeps it off the speakers.
@available(macOS 14.2, *)
private final class TonePlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let amplitude: Float
    private let hz: Double

    init(amplitude: Float, hz: Double) {
        self.amplitude = amplitude
        self.hz = hz
    }

    func start() -> Bool {
        let output = engine.outputNode
        let sampleRate = output.outputFormat(forBus: 0).sampleRate
        guard sampleRate > 0 else { return false }

        // Stereo float source matching the output's sample rate.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return false
        }

        let amplitude = self.amplitude
        let phaseIncrement = Float(2.0 * Double.pi * hz / sampleRate)
        var phase: Float = 0

        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = sinf(phase) * amplitude
                phase += phaseIncrement
                if phase > Float(2.0 * Double.pi) { phase -= Float(2.0 * Double.pi) }
                for buffer in abl {
                    let ptr = buffer.mData?.assumingMemoryBound(to: Float.self)
                    ptr?[frame] = value
                }
            }
            return noErr
        }
        self.sourceNode = source

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    func stop() {
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
    }
}

// MARK: - Self-process tap (peak-only, muted)

/// A process tap of ONLY this process, wrapped in a private aggregate device
/// pinned to the default output — the same recipe ``CoreAudioSystemTap`` uses,
/// but scoped to us, muted, and reduced to "what's the peak level?". No engine
/// sink, no format conversion; the IOProc just tracks the largest |sample| seen.
@available(macOS 14.2, *)
private final class SelfProcessTap: @unchecked Sendable {

    private let processObject: AudioObjectID
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    private let peakLock = NSLock()
    private var _peak: Float = 0

    init(processObject: AudioObjectID) {
        self.processObject = processObject
    }

    func peak() -> Float { peakLock.withLock { _peak } }

    /// Create the muted self-tap + aggregate + IOProc and start it. Returns false
    /// on any failure (the caller then reads `.denied`). A tap that's merely
    /// *denied* still starts fine here and simply reports a zero peak.
    func start() -> Bool {
        // Tap ONLY this process, muted (captured but never sent to hardware).
        // The Swift-refined initializer takes `[AudioObjectID]` directly (it wraps
        // them into the NSArray<NSNumber> the Obj-C API declares).
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
        desc.uuid = UUID()
        desc.muteBehavior = .muted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateProcessTap(desc, &newTapID) == noErr,
              newTapID != kAudioObjectUnknown else {
            return false
        }
        self.tapID = newTapID

        // Aggregate pinned to the default OUTPUT device (never the alert-sound
        // "system output" — the same selector-choice warning as CoreAudioSystemTap).
        guard let outputUID = try? Self.defaultOutputUID() else { return false }
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String:          "SetupProbe-Audiouter",
            kAudioAggregateDeviceUIDKey as String:           aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String:     true,
            kAudioAggregateDeviceIsStackedKey as String:     false,
            kAudioAggregateDeviceTapAutoStartKey as String:  true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [ kAudioSubDeviceUIDKey as String: outputUID ]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: desc.uuid.uuidString
                ]
            ]
        ]
        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID) == noErr,
              newAggregateID != kAudioObjectUnknown else {
            return false
        }
        self.aggregateID = newAggregateID

        // IOProc: track the peak |sample| across delivered Float32 buffers.
        var newProcID: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "com.airplaycontroller.setup.probe", qos: .userInitiated)
        let err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let listPtr = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var localPeak: Float = 0
            for buffer in listPtr {
                guard let base = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = base.assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    let a = abs(samples[i])
                    if a > localPeak { localPeak = a }
                }
            }
            if localPeak > 0 {
                self.peakLock.withLock { if localPeak > self._peak { self._peak = localPeak } }
            }
        }
        guard err == noErr, let procID = newProcID else { return false }
        self.ioProcID = procID

        return AudioDeviceStart(aggregateID, procID) == noErr
    }

    /// Stop + destroy the IOProc, aggregate, and tap (order matters). Idempotent.
    func teardown() {
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// The default OUTPUT device's UID (reuses ``CoreAudioSystemTap``'s proven
    /// reads — same module — so the tap-follows-default-output house rule stays
    /// in exactly one place).
    private static func defaultOutputUID() throws -> String {
        let deviceID = try CoreAudioSystemTap.defaultOutputDeviceID()
        return try CoreAudioSystemTap.readDeviceUID(deviceID)
    }
}

#endif
