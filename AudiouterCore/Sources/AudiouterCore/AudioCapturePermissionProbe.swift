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
/// 1. Read the live TCC decision first (the private `TCCAccessPreflight` behind
///    ``SystemAudioCaptureTCC/preflight()``, macOS 14.4+). Already **granted** or
///    **denied** → report it immediately — nothing to prove, and no surprise beep
///    when the user re-confirms an existing grant.
/// 2. **Undetermined** (or pre-14.4, where TCC has no readable audio-capture
///    bucket) → play a quiet sine **in this process** and open a muted tap of
///    **only this process** (`CATapDescription(stereoMixdownOfProcesses:)`,
///    `muteBehavior = .muted`). Creating that tap surfaces the system prompt.
///    Tapping only ourselves keeps it off everyone else's audio (a global tap
///    would capture ambient audio, risking a false "granted" and contradicting
///    the app's whole privacy promise).
/// 3. Keep the tap OPEN and WATCH for our tone to come through it. A denied tap
///    delivers exact zeros; a granted one delivers our sine — so a peak above the
///    floor is a FUNCTIONAL read of the LIVE grant that flips true the instant the
///    user allows. This is deliberately NOT a poll of `TCCAccessPreflight`: that
///    read serves a stale in-process cache, so after the user granted it kept
///    saying "undetermined" and the probe hung the whole timeout then reported
///    **denied** (and an earlier version that judged from a fixed ~300 ms window
///    raced the user the other way). The tone stops the moment the grant is
///    detected; an ignored prompt (or an explicit TCC `denied`, which
///    short-circuits) ends in **denied** at ``promptAnswerTimeout``.
/// 4. Tear the tone + tap down on exit, so no lingering system tap, no lingering
///    beep, no muted state.
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
    /// How long to wait for the user to answer the system prompt (14.4+ path)
    /// before giving up and reporting not-granted. The prompt is modal and
    /// usually answered in seconds; this only bounds the "walked away" case so
    /// the probe — and the row's spinner — can't hang forever.
    private let promptAnswerTimeout: TimeInterval = 60
    /// How often to re-check the tap for our tone (and for an explicit TCC
    /// denial) while the prompt is up.
    private let pollInterval: TimeInterval = 0.15

    public init() {}

    /// T5: logs the final granted/denied/... verdict this file's audible
    /// ``probe()`` or silent ``currentStatusSilently()`` produced, and HOW it
    /// was determined. `site` distinguishes the two callers; `method`
    /// distinguishes a direct single-bucket `TCCAccessPreflight` read (fast,
    /// no tone, no tap beyond a possible cold prompt, used by `probe()`'s
    /// `runProbe()`) from the audible self-tap tone fallback
    /// (`functionalGrantProbe()`) and from `currentStatusSilently()`'s
    /// latch-aware ``SystemAudioCaptureTCC/effectiveStatus()`` read. These are
    /// genuinely different checks of "is audio capture allowed" that are not
    /// guaranteed to agree — logging which one answered is exactly the kind
    /// of asymmetry T5 exists to make visible, alongside
    /// ``SetupModel``'s reported-vs-actual comparison and the real
    /// `SystemAudioCaptureTCC.isGranted()` gate the capture coordinators
    /// actually key tap creation on.
    private func logVerdict(site: String, _ status: PermissionStatus, method: String) {
        Telemetry.log(.permission, "probe_verdict", [
            "site": site,
            "verdict": status.telemetryDescription,
            "method": method,
        ])
    }

    public func probe() async -> PermissionStatus {
        // All Core Audio + the observation sleep run off the main actor.
        await withCheckedContinuation { (continuation: CheckedContinuation<PermissionStatus, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.runProbe())
            }
        }
    }

    /// Report the REAL outcome, triggering the prompt first if the grant is
    /// undecided. Runs on a background queue. An already-decided grant is read
    /// straight from TCC (fast, no tone); an undecided one (or pre-14.4, where
    /// TCC has no readable audio-capture bucket) goes through the functional
    /// tone probe below.
    private func runProbe() -> PermissionStatus {
        switch SystemAudioCaptureTCC.preflight() {
        case .granted?:
            logVerdict(site: "CoreAudioTonePermissionProbe.probe", .granted, method: "tcc_preflight")
            return .granted
        case .denied?:
            logVerdict(site: "CoreAudioTonePermissionProbe.probe", .denied, method: "tcc_preflight")
            return .denied
        case .undetermined?, nil:
            let result = functionalGrantProbe()
            logVerdict(site: "CoreAudioTonePermissionProbe.probe", result, method: "self_tap_tone")
            return result
        }
    }

    /// Fire the prompt (creating the tap does that) and then WATCH for our known
    /// tone to actually come through the tap.
    ///
    /// This is the fix for BOTH the original race (a fixed ~300 ms window elapsed
    /// before the user answered, so a fresh grant read `.denied`) AND the failure
    /// that replaced it (polling `TCCAccessPreflight` never flipped to granted —
    /// it serves a stale in-process cache, so the spinner hung the full timeout
    /// and then said Denied). A denied tap delivers exact zeros and a granted one
    /// delivers our sine, so a peak above the floor is a FUNCTIONAL read of the
    /// LIVE grant: it goes true the instant the user allows, cache or no cache.
    ///
    /// The tap is kept OPEN across the whole wait (not torn down after a beat) so
    /// the system prompt stays up until the user answers; the tone stops the
    /// moment we detect the grant. Bounded by ``promptAnswerTimeout`` — an ignored
    /// prompt, or an explicit TCC `denied` (14.4+, which short-circuits), ends in
    /// `.denied`.
    private func functionalGrantProbe() -> PermissionStatus {
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

        // Creating the tap surfaces the prompt on an undecided grant. Keep it
        // OPEN for the whole wait so the prompt stays up and, once the user
        // allows, our tone starts flowing through it.
        let tap = SelfProcessTap(processObject: processObject)
        guard tap.start() else { return .denied }
        defer { tap.teardown() }

        let deadline = Date().addingTimeInterval(promptAnswerTimeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            // Our tone came through ⇒ capture is live ⇒ granted. The peak is a
            // running max, so once the user allows it stays above the floor.
            if tap.peak() > grantedPeakThreshold { return .granted }
            // An explicit TCC denial (14.4+) ends the wait early; a stale
            // "undetermined"/unavailable read just keeps us watching the tone.
            if case .denied? = SystemAudioCaptureTCC.preflight() { return .denied }
        }
        return .denied
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
    ///
    /// The silent read is ``SystemAudioCaptureTCC/effectiveStatus()``: the
    /// fresh-verdict LATCH if one has been recorded this session (a grant proved
    /// out-of-process by `TCCProbeRunner`/`PermissionStateObserver`, which this
    /// process's own permanently-cached `TCCAccessPreflight` read can never
    /// see), otherwise ``SystemAudioCaptureTCC/combinedStatus()``. Reading
    /// through the latch matters HERE specifically because this is the
    /// reactivate/wake revocation audit's input: without it, a user who granted
    /// mid-session would keep auditing as `.unknown` for the rest of the run
    /// even after the app had proven the grant. `combinedStatus()` itself — it
    /// consults BOTH buckets this app can be registered under
    /// (`kTCCServiceAudioCapture`, the "System Audio Recording Only" list this
    /// app is actually listed under, and `kTCCServiceScreenCapture`) and
    /// combines them: any bucket granted wins; denied only when BOTH are
    /// denied; anything else (including either bucket merely undetermined) is
    /// `.undetermined`, which maps to ``PermissionStatus/unknown`` below —
    /// **never** `.denied`.
    ///
    /// An earlier version of this method asked only
    /// `CGPreflightScreenCaptureAccess()` — the "Screen & System Audio
    /// Recording" list, a genuinely separate list this app never appears in —
    /// whenever the audio bucket read `.undetermined`, and mapped a `false`
    /// from that call straight to `.denied`. Because this app is never in that
    /// list, the call could only ever read `false`, so that fallback could
    /// only ever manufacture a denial and could never rescue a real grant. The
    /// app's own telemetry showed the damage: 17 verdicts came through that
    /// path, every one of them `.denied`, including one that contradicted a
    /// functional tone probe that had proven capture was working 55 seconds
    /// earlier. `combinedStatus()` replaces it — it can still recover a stale
    /// Screen-Recording-only grant as a last resort (see its own doc comment),
    /// but that recovery path can only ever turn `nil` into `.granted`, never
    /// into `.denied`.
    public func currentStatusSilently() -> PermissionStatus? {
        let site = "CoreAudioTonePermissionProbe.currentStatusSilently"
        switch SystemAudioCaptureTCC.effectiveStatus() {
        case .granted:
            logVerdict(site: site, .granted, method: "tcc_effective")
            return .granted
        case .denied:
            logVerdict(site: site, .denied, method: "tcc_effective")
            return .denied
        case .undetermined:
            // "Don't know yet" must never become a denial — .unknown is the
            // existing calm/no-alarm status (SetupModel renders it as a plain
            // "Allow…" row, not a "your permission was turned off" banner).
            logVerdict(site: site, .unknown, method: "tcc_effective")
            return .unknown
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
