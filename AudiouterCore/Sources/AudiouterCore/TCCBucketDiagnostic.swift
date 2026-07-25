// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Darwin           // dlopen/dlsym for the private TCC audio-capture status read
import CoreFoundation   // CFNotificationCenter — the Darwin-notification attribution test below

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Env-gated (`AUDIOUTER_TCC_DIAG=1`), once-per-second ``Telemetry`` poll built
/// to settle a three-way, load-bearing contradiction elsewhere in this
/// codebase about whether the private `TCCAccessPreflight` read is LIVE or
/// CACHED per-process:
/// - `AudioCapturePermissionProbe.swift` claims it "serves a stale in-process
///   cache" (the reason `functionalGrantProbe()` polls a self-tap tone
///   instead of `TCCAccessPreflight` while a prompt is up).
/// - `AppRelaunchCommand.swift` claims the grant is only readable via
///   `CGPreflightScreenCaptureAccess()`, and that it returns "the value
///   cached when the process launched" — the reason the app relaunches at all
///   after a permission change.
/// - A merged memory note claims the opposite: that `TCCAccessPreflight` is
///   "a LIVE read (not launch-cached)".
///
/// Every tick logs the RAW `Int32` `TCCAccessPreflight` returns for the real
/// audio-capture bucket, the Screen Recording bucket, and a deliberately
/// bogus service name (the CONTROL — a bad name must always read back `1`
/// (denied); anything else means the `dlsym` resolution itself is broken and
/// the whole run is void), plus `CGPreflightScreenCaptureAccess()`. A
/// four-phase live run — (A) `open`-launch, poll pre-grant; (B) grant the
/// permission; (C) keep polling the SAME process ≥90s; (D) quit, `open`
/// again, read the new process's first tick — makes the three claims above
/// mutually exclusive to read back from the log:
/// - the audio bucket flips 2→0 during (C) ⇒ no in-process staleness;
/// - it stays 2 through (C) but reads 0 in (D) ⇒ staleness is real;
/// - it stays 2 in (D) while the screen bucket reads 0 ⇒ wrong bucket.
///
/// Reports raw integers, never an interpreted enum — the entire point is to
/// see exactly what macOS returns, not this app's opinion of it.
///
/// Deliberately duplicates ``SystemAudioCaptureTCC``'s `dlopen`/`dlsym`
/// resolution rather than calling it, to stay out of that file entirely while
/// it's under concurrent edit elsewhere.
///
/// ## T14 extension — one user grant, three questions
/// The staleness finding above led to ``TCCProbeRunner``: spawn a fresh helper
/// process (`tcc-probe`) to dodge the per-process cache entirely. This file
/// now answers three more questions in the SAME live-gate run, from the SAME
/// single permission grant:
/// - **(a) Attribution** — every tick's in-process read is now paired, on the
///   SAME telemetry line, with a fresh `tcc-probe` spawn's `helperAudio`/
///   `helperScreen`/`helperControl` fields (+ `helperOutcome` for the
///   interpreted status). PASS = the helper reads `0` (granted) while the
///   in-process fields on that same line still read `2` — proof the helper
///   process is attributed to this app rather than reading its own identity.
/// - **(b) Does the notification fire** — a Darwin notification observer for
///   `com.apple.tcc.access.changed` logs a `tcc_diag_notification_fired` event
///   (with `Telemetry`'s own timestamp) every time tccd posts it.
/// - **(c) Does it refresh the in-process cache** — falls out of (a)'s data
///   for free: since every tick logs both reads regardless, a reader just
///   checks whether ticks AFTER a notification-fired event show the
///   in-process fields finally moving, or whether they keep reading stale
///   while `helperAudio`/etc. already show the truth.
public enum TCCBucketDiagnostic {

    /// Starts the poll loop iff `AUDIOUTER_TCC_DIAG=1`; a no-op otherwise, and
    /// idempotent if called more than once. Call once, early in launch, so
    /// phase (A) of the run above starts capturing before any permission
    /// dialog can appear. The first tick fires synchronously (not after the
    /// first second) so a fresh launch's initial bucket state is never missed.
    public static func startIfEnabled() {
        guard ProcessInfo.processInfo.environment["AUDIOUTER_TCC_DIAG"] == "1" else { return }
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }

        registerNotificationObserver()
        tick()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        source.setEventHandler { tick() }
        source.resume()
        timer = source
    }

    /// Test-only teardown: unregisters the Darwin notification observer and
    /// resets state so a suite can start this diagnostic more than once in
    /// one process without leaking a stale `CFNotificationCenter`
    /// registration — a missing removal here is exactly the dangling-pointer
    /// trap `CFNotificationCenterRemoveObserver`'s contract warns about, and
    /// this is that removal's one call site (this diagnostic otherwise runs
    /// to completion for the process's lifetime — see `timer`'s doc comment
    /// — so production code never needs it).
    static func _stopForTesting() {
        lock.lock()
        let wasStarted = started
        started = false
        tickCount = 0
        lock.unlock()
        guard wasStarted else { return }
        timer?.cancel()
        timer = nil
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(notificationToken).toOpaque(),
            CFNotificationName(rawValue: accessChangedNotificationName),
            nil)
    }

    // MARK: - Implementation

    /// A bad TCC service name — verified, this session, to read back `1`
    /// (denied) rather than `2` (undetermined) or an error. If a run ever logs
    /// anything else here, the `dlsym` path failed and every other field on
    /// that line is meaningless.
    private static let bogusServiceName = "kTCCServiceAudiouterDiagBogusControl"

    private static let pollInterval: TimeInterval = 1.0
    private static let queue = DispatchQueue(label: "com.audiouter.tccdiag")
    private static let processStart = Date()

    /// One fresh-process attribution probe per tick — see the type doc's
    /// question (a). Production spawn (``TCCProbeRunner/productionSpawn``);
    /// single-flighted internally, so a slow/timed-out spawn never piles up
    /// concurrent `tcc-probe` children as ticks keep firing every second.
    private static let probeRunner = TCCProbeRunner()

    private static let lock = NSLock()
    private nonisolated(unsafe) static var started = false
    private nonisolated(unsafe) static var tickCount = 0
    /// Retained for the process's lifetime — this is a run-to-completion
    /// diagnostic, never torn down in production (see ``_stopForTesting()``
    /// for the one place it IS torn down, for test hygiene).
    private nonisolated(unsafe) static var timer: DispatchSourceTimer?

    private static func tick() {
        let isFirstTick: Bool = lock.withLock {
            let first = tickCount == 0
            tickCount += 1
            return first
        }

        let cgGranted: Bool
        #if canImport(CoreGraphics)
        cgGranted = CGPreflightScreenCaptureAccess()
        #else
        cgGranted = false
        #endif

        // Captured now, alongside the helper spawn kicked off below, so the
        // eventual combined telemetry line pairs an in-process read with a
        // helper read from (as close as async spawning allows to) the same
        // moment — see the type doc's question (a).
        let audioCapture = rawString(rawPreflight("kTCCServiceAudioCapture"))
        let screenCapture = rawString(rawPreflight("kTCCServiceScreenCapture"))
        let bogusControl = rawString(rawPreflight(bogusServiceName))
        let uptimeSec = String(format: "%.1f", Date().timeIntervalSince(processStart))
        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        let bundleID = Bundle.main.bundleIdentifier ?? "-"

        probeRunner.requestResolution { result, raw in
            let fields: [String: String] = [
                "audioCapture": audioCapture,
                "screenCapture": screenCapture,
                "bogusControl": bogusControl,
                "cgPreflight": cgGranted ? "true" : "false",
                "uptimeSec": uptimeSec,
                "pid": pid,
                "bundleID": bundleID,
                "helperAudio": raw.map { "\($0.audio)" } ?? "nil",
                "helperScreen": raw.map { "\($0.screen)" } ?? "nil",
                "helperControl": raw.map { "\($0.control)" } ?? "nil",
                "helperOutcome": helperOutcomeString(result),
            ]
            Telemetry.log(.permission, isFirstTick ? "tcc_diag_first_tick" : "tcc_diag_tick", fields)
        }
    }

    /// A short, greppable tag for ``TCCProbeRunner/Result`` — the diagnostic's
    /// "report integers, not opinions" posture (file doc comment) covers the
    /// raw `helperAudio`/`helperScreen`/`helperControl` fields; this field is
    /// the one interpreted value on the line, there purely so a reader doesn't
    /// have to re-derive "was this actually trustworthy" from the three raw
    /// integers by hand.
    private static func helperOutcomeString(_ result: TCCProbeRunner.Result) -> String {
        switch result {
        case .resolved(.granted): return "granted"
        case .resolved(.denied): return "denied"
        case .resolved(.undetermined): return "undetermined"
        case .unresolved(.helperMissing): return "helperMissing"
        case .unresolved(.timedOut): return "timedOut"
        case .unresolved(.spawnFailed): return "spawnFailed"
        case .unresolved(.malformedOutput): return "malformedOutput"
        case .unresolved(.controlMismatch): return "controlMismatch"
        }
    }

    // MARK: - Darwin notification attribution (question (b))

    /// The notification tccd posts when ANY app's TCC decision changes.
    /// Payload-free and coalesced — macOS may deliver several rapid changes
    /// as a single callback — so a firing only ever means "go re-check," and
    /// this file never assumes one firing equals exactly one change.
    private static let accessChangedNotificationName = "com.apple.tcc.access.changed" as CFString

    /// Stable identity for the `CFNotificationCenter` registration. A real
    /// object is required because the bare-C-function-pointer callback below
    /// cannot capture `self` (and this is a static-only enum with no
    /// instances to capture anyway) — the SAME `Unmanaged` pointer built from
    /// this token registers the observer in ``registerNotificationObserver()``
    /// and removes it in ``_stopForTesting()``, per
    /// `CFNotificationCenterAddObserver`'s documented contract.
    private final class NotificationToken {}
    private static let notificationToken = NotificationToken()

    /// A bare C function pointer (`CFNotificationCallback`), NOT a capturing
    /// closure — `notify_register_dispatch`/`notify_register_check` are not
    /// reachable from Swift at all (no module map for `notify.h` without a
    /// bridging header, confirmed by trying), so this `CFNotificationCenter`
    /// path is the one that actually compiles and fires. The closure literal
    /// below captures nothing from its environment (only static/type
    /// references), which is what lets Swift convert it to `@convention(c)`
    /// at all; the `observer` parameter is round-tripped through
    /// `Unmanaged.fromOpaque` purely to demonstrate/exercise the documented
    /// recovery path, since this file has exactly one registration and no
    /// real per-observer state to recover.
    private static let accessChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        _ = Unmanaged<NotificationToken>.fromOpaque(observer).takeUnretainedValue()
        TCCBucketDiagnostic.logNotificationFired()
    }

    private static func registerNotificationObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(notificationToken).toOpaque(),
            accessChangedCallback,
            accessChangedNotificationName,
            nil,
            .deliverImmediately)
    }

    /// Logged as its own event (distinct from `tcc_diag_tick`) so a reader can
    /// see exactly when tccd posted the notification relative to the
    /// surrounding ticks — `Telemetry.log` already stamps every line with an
    /// absolute UTC `ts`; `uptimeSec` here additionally matches the same
    /// process-relative clock the tick lines use, for easy side-by-side
    /// correlation without converting timestamps by hand.
    private static func logNotificationFired() {
        Telemetry.log(.permission, "tcc_diag_notification_fired", [
            "uptimeSec": String(format: "%.1f", Date().timeIntervalSince(processStart)),
        ])
    }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32

    /// Resolves `TCCAccessPreflight` and returns its RAW `Int32` for
    /// `service`, or `nil` if the private framework/symbol can't be resolved
    /// at all (mirrors `SystemAudioCaptureTCC.preflight()`'s resolution,
    /// duplicated rather than shared — see the file doc comment). Not cached
    /// across ticks: dyld already has the image mapped from the first call,
    /// so `dlopen`/`dlsym` here are cheap lookups, not a fresh load each time.
    private static func rawPreflight(_ service: String) -> Int32? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else {
            return nil
        }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        return preflight(service as CFString, nil)
    }

    private static func rawString(_ value: Int32?) -> String {
        guard let value else { return "nil" }
        return "\(value)"
    }
}
