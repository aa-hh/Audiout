// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Darwin   // dlopen/dlsym for the private TCC status read

#if canImport(CoreGraphics)
import CoreGraphics   // last-resort survival path only — see combinedStatus()
#endif

/// A silent, prompt-free read of the **System Audio Recording** (process-tap)
/// TCC grant — the single source of truth the capture coordinators consult
/// before creating ANY `AudioHardwareCreateProcessTap`.
///
/// ## ⚠️ THIS FORECLOSES APP STORE DISTRIBUTION — a deliberate, owner-approved choice
/// Apple ships **no public API** for the audio-capture grant, so this file (and
/// the bundled `tcc-probe` helper) resolve the private `TCCAccessPreflight` at
/// runtime via `dlsym`. That is fine for Developer ID + notarization — what this
/// app ships — but the App Store rejects private-symbol use outright. The owner
/// confirmed 2026-07-25 that App Store distribution is not a goal, now or later,
/// and accepted this cost knowingly. **Do not remove the private read to "fix"
/// an App Store concern without re-opening that decision** — the only public
/// alternative is a functional tap test, which is slow and audible and cannot
/// serve a launch-time or menu-bar-click check.
///
/// ## Known, accepted limitation: no mid-session revocation detection
/// The latch below is ONE-WAY — only a confirmed grant is ever recorded, never a
/// revocation, because latching a negative would reintroduce the false-denial
/// bug this file exists to eliminate. If the user revokes permission while the
/// app runs, the app will not notice until the next launch or wake. This is
/// **not a regression**: the previous cached read was equally blind, and a
/// revoked grant fails safe (a refused tap errors; it cannot fire a cold prompt,
/// since only *undetermined* prompts).
///
/// ## Why this is load-bearing
/// Creating a process tap is what surfaces the macOS "…would like to record this
/// computer's audio" prompt. If any automatic path (a restored per-app route
/// applied at launch, the whole-system capture gate, a metering tap) creates a
/// tap while the grant is still undetermined, the OS prompt fires *cold* — with
/// no Setup screen in front of the user. That is exactly the bug this guard
/// exists to prevent: every streaming/metering tap first asks ``isGranted()``,
/// and the ONLY code allowed to trigger the prompt is the Setup screen's
/// explicit "Allow…" probe (``CoreAudioTonePermissionProbe``), which uses its
/// own tap class and is deliberately NOT gated.
///
/// ## Where the grant lives — TWO independent buckets, read and combined
/// macOS answers a TCC query three ways — granted / denied / **undetermined**
/// ("hasn't been asked yet") — and this app can be registered in either of two
/// buckets: `kTCCServiceAudioCapture` (the "System Audio Recording Only" list
/// this app is actually listed under) and `kTCCServiceScreenCapture` (the
/// "Screen & System Audio Recording" list — a broader grant that also covers
/// the tap). The two are genuinely independent: on this machine, Terminal reads
/// `kTCCServiceScreenCapture` as granted while `kTCCServiceAudioCapture` is
/// still undetermined for the same process. Collapsing either bucket's
/// undetermined into denied is the bug this file exists to fix — the app's own
/// telemetry once recorded a functional tone probe PROVING capture worked,
/// followed 55 seconds later by a silent read wrongly declaring it denied.
/// ``combinedStatus()`` reads both buckets via the private `TCCAccessPreflight`
/// and combines them with ``combine(audio:screen:)``. It falls back to the
/// two-valued `CGPreflightScreenCaptureAccess()` ONLY in the narrow case where
/// `TCCAccessPreflight` itself is unresolvable — see the survival-path comment
/// inside ``combinedStatus()`` for why that fallback can only ever rescue a
/// grant, never manufacture a denial. Both reads are silent — no tap, no tone,
/// no prompt.
public enum SystemAudioCaptureTCC {

    /// tccd's authorization values for `TCCAccessPreflight` (private TCC API).
    public enum Preflight: Equatable { case granted, denied, undetermined }

    /// The live TCC decision for one `service` bucket (e.g.
    /// `kTCCServiceAudioCapture`, `kTCCServiceScreenCapture`), or `nil` when the
    /// private TCC framework/symbol can't be resolved at all (no framework to
    /// ask, on any OS version — distinct from a real "undetermined" answer from
    /// a resolved framework).
    ///
    /// A deliberately bogus service name reads back `1` (denied), not `2` —
    /// verified empirically — so a `2` from a real service name genuinely means
    /// "registered, no decision yet," never "TCC doesn't know this bucket."
    static func preflight(service: String) -> Preflight? {
        typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
        // dyld resolves this from the shared cache even though the file isn't on
        // disk. Intentionally NOT dlclose'd: the framework stays resident (AppKit
        // uses it too) and the handle lives for the process's lifetime.
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW),
              let symbol = dlsym(handle, "TCCAccessPreflight") else {
            return nil
        }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        switch preflight(service as CFString, nil) {
        case 0:  return .granted        // kTCCAccessPreflightGranted
        case 1:  return .denied         // kTCCAccessPreflightDenied
        default: return .undetermined   // kTCCAccessPreflightUnknown (2)
        }
    }

    /// The live `kTCCServiceAudioCapture` decision — the bucket this app is
    /// actually registered under. Kept as the no-argument default so existing
    /// call sites (the tone probe's TCC fast-path) read unchanged.
    static func preflight() -> Preflight? {
        preflight(service: "kTCCServiceAudioCapture")
    }

    /// Combine the two independently-read buckets into one three-valued
    /// decision. Pure and `dlopen`-free on purpose — this is the truth table
    /// that matters, and keeping it free of the private TCC call lets it be
    /// unit-tested directly with no TCC dependency at all.
    ///
    /// Truth table (locked): **any bucket granted → granted** (either
    /// registration is enough to open a tap without prompting); **denied ONLY
    /// when BOTH are denied** (one denial doesn't rule out the other bucket
    /// still carrying the grant); **anything else → undetermined** (at least
    /// one bucket hasn't been asked yet, and neither has granted) — so an
    /// undetermined bucket never gets silently read as denied.
    static func combine(audio: Preflight, screen: Preflight) -> Preflight {
        if audio == .granted || screen == .granted {
            return .granted
        }
        if audio == .denied && screen == .denied {
            return .denied
        }
        return .undetermined
    }

    /// The combined three-valued read across both TCC buckets. A bucket whose
    /// private-framework read fails entirely (`nil` — see ``preflight(service:)``)
    /// contributes `.undetermined`, the same fail-safe posture as a genuine
    /// live "not yet asked" answer: neither can grant, and only mutual denial
    /// can deny — UNLESS both reads come back `nil` at once, handled below.
    public static func combinedStatus() -> Preflight {
        let audioRaw = preflight(service: "kTCCServiceAudioCapture")
        let screenRaw = preflight(service: "kTCCServiceScreenCapture")

        // LAST-RESORT SURVIVAL PATH — not the general fallback, do not widen.
        //
        // Both buckets read `nil` only when the private `TCCAccessPreflight`
        // symbol itself is unresolvable (e.g. a future macOS removes/renames
        // it, or `dlopen` fails) — literally zero information from TCC, not a
        // real 0/1/2 answer from either bucket. Left unhandled, that maps both
        // legs to `.undetermined`, `combine` returns `.undetermined`, and
        // `isGranted()` refuses forever with no recovery: the app goes
        // permanently silent for every user, including ones already holding a
        // real Screen Recording grant. `CGPreflightScreenCaptureAccess()` is
        // the pre-TCCAccessPreflight two-valued API this whole file exists to
        // stop relying on (it cannot express undetermined) — but it is safe to
        // consult HERE, specifically because it only ever runs when we have no
        // other signal at all.
        //
        // The asymmetry is deliberate and must not be "simplified" away:
        // `true` → `.granted` (rescues a real grant that would otherwise be
        // lost); `false` → `.undetermined`, NEVER `.denied` — a `false` from a
        // two-valued API can't distinguish "denied" from "not asked yet," and
        // manufacturing a denial from that ambiguity is exactly the collapsing
        // bug this task exists to fix. So this path can only ever RESCUE a
        // grant, never invent a denial.
        if audioRaw == nil && screenRaw == nil {
            #if canImport(CoreGraphics)
            return CGPreflightScreenCaptureAccess() ? .granted : .undetermined
            #else
            return .undetermined
            #endif
        }

        let audio = audioRaw ?? .undetermined
        let screen = screenRaw ?? .undetermined
        return combine(audio: audio, screen: screen)
    }

    // MARK: - Fresh-verdict latch (T13)

    /// Guards ``latchedGrant`` below. A plain `NSLock` — the same primitive
    /// `TCCProbeRunner` already uses for its own cross-thread state — because
    /// this is read from at least three independent execution contexts:
    /// `NativeBackend`'s `captureControlQueue` and `stateQueue` (two different
    /// serial queues, per-app and whole-system capture respectively) and the
    /// main actor (`AppDelegate`'s launch/click checks). A torn read here
    /// would be a real hazard — a caller could observe neither `true` nor
    /// `false` cleanly on some architectures — so this is not optional even
    /// though the payload is a single `Bool`.
    private static let latchLock = NSLock()

    /// One-way latch: `false` until ``recordFreshGrant(source:)`` is called,
    /// then `true` for the rest of this process's life. See that method and
    /// ``effectiveStatus()`` for why this can only ever move false→true.
    private static var latchedGrant = false

    /// Records proof — from a source immune to THIS process's stale TCC
    /// cache — that the grant is actually in place right now. This is the fix
    /// for the trap ``combinedStatus()`` cannot close by itself: live evidence
    /// showed `TCCAccessPreflight` is cached for the lifetime of the CALLING
    /// process, so a grant made after this process launched is invisible to
    /// `combinedStatus()` FOREVER — a freshly-spawned helper process
    /// (`TCCProbeRunner`) read `.granted` in the same instant this process's
    /// own read stayed `.undetermined`, and the `com.apple.tcc.access.changed`
    /// Darwin notification firing at that same moment did NOT refresh the
    /// in-process cache. Without this latch, `isGranted()` would refuse
    /// forever even after a caller proved the grant is real, which is exactly
    /// the trap this task exists to close — every capture coordinator gates
    /// tap creation on `isGranted()`.
    ///
    /// Callers: a `TCCProbeRunner` resolution that came back
    /// `.resolved(.granted)` (a brand-new process, brand-new cache, so its
    /// answer is never stale), or a functional tap that actually moved real
    /// audio (proof stronger than any status read). NEVER call this with a
    /// cached/in-process read — `combinedStatus()`'s own result is
    /// specifically NOT valid proof, since staleness is the bug this exists
    /// to work around, not a source of truth for it. `source` is recorded
    /// only for ``Telemetry``, so a divergence between "why the latch fired"
    /// and what was actually true stays diagnosable.
    ///
    /// **Deliberately one-way — there is no `clear()`.** Two decisions this
    /// method locks in:
    ///
    /// 1. **Only `.granted` is ever latched.** A caller holding a fresh
    ///    `.denied`/`.undetermined` answer must simply not call this — there
    ///    is no parameter that would let it. Latching a fresh `.granted` can
    ///    only ever ENABLE audio the user has actually authorized (proof-only,
    ///    monotonic); latching a fresh negative could re-introduce a false
    ///    denial from this exact call site — the class of bug this whole file
    ///    exists to eliminate, just moved from the cached read to the "fresh"
    ///    one. The two are not symmetric risks and must not be treated as if
    ///    they were.
    /// 2. **A user revoking permission mid-session does not clear this latch.**
    ///    Once a grant is proven, macOS's own tap-creation call still enforces
    ///    the CURRENT real TCC state independently of anything cached here —
    ///    a stale "granted" latch after a genuine revocation means a tap
    ///    creation attempt fails with the OS's own (silent, non-prompting)
    ///    denial, not a cold system prompt, because `.denied` never prompts —
    ///    only `.undetermined` does (see ``isGranted()``). So the failure mode
    ///    of NOT clearing is a benign, already-guarded-against tap-creation
    ///    failure, never the cold-prompt this file exists to prevent. Real
    ///    mid-session revocation is also already the job of a different,
    ///    higher-level subsystem — `AppDelegate.auditRequiredPermissionsIfNeeded`
    ///    — which force-reopens Setup on a sustained "permission turned off"
    ///    finding; adding a second, lower-level clearing path here would fight
    ///    that one's cooldown/audit logic for no benefit. If a later task
    ///    wires the `com.apple.tcc.access.changed` observer to actively
    ///    detect revocation, it can add a deliberate clearing path then, with
    ///    its own reasoning — this task does not preempt that decision.
    public static func recordFreshGrant(source: String) {
        latchLock.lock()
        let wasAlreadyLatched = latchedGrant
        latchedGrant = true
        latchLock.unlock()
        // Log once per actual state change, not on every redundant call (a
        // repeated grant confirmation from the same source would otherwise
        // spam the always-on log with no new information).
        if !wasAlreadyLatched {
            Telemetry.log(.permission, "tcc_latch_set", ["source": source])
        }
    }

    /// Test-only: clear the latch. Mirrors `Telemetry._resetForTesting()`'s
    /// convention (leading underscore = not production API).
    ///
    /// This exists because the latch is deliberately ONE-WAY and process-global,
    /// which makes it untestable without a seam: any test calling
    /// ``recordFreshGrant(source:)`` would otherwise pin ``effectiveStatus()``
    /// to `.granted` for the remainder of the test process and silently corrupt
    /// every later assertion. Production must never call this — clearing a
    /// confirmed grant would reintroduce exactly the false-denial bug this file
    /// exists to eliminate.
    public static func _resetLatchForTesting() {
        latchLock.lock()
        latchedGrant = false
        latchLock.unlock()
    }

    // MARK: - Proven code-identity fingerprint (T8)

    /// Guards ``provenIdentity``. Reuses ``latchLock`` rather than a second
    /// lock — both guard tiny, independent pieces of process-global grant
    /// state read from the same multi-queue callers described on ``latchLock``,
    /// and a second lock here would just be another primitive to keep in sync
    /// for no real isolation benefit.
    ///
    /// The stored fingerprint of the binary identity that last PROVED the
    /// audio-capture grant via ``CoreAudioTonePermissionProbe/probe()``'s
    /// audible functional check (`kSecCodeInfoUnique`, or equivalent — see
    /// that type). This exists because a stale, cdhash-pinned TCC grant can
    /// read `.granted` for a rebuilt binary that macOS will actually refuse to
    /// honor — the whole reason the functional tone probe exists. Skipping
    /// that probe whenever a fast `.granted` read comes back defeats it in
    /// exactly the case it was built for, so `runProbe()` only takes the fast
    /// path when the CURRENT binary's identity matches the one that last
    /// proved the grant out loud.
    private static var provenIdentity: String?

    /// The identity fingerprint that last proved the grant, if any.
    public static func provenCodeIdentity() -> String? {
        latchLock.lock()
        defer { latchLock.unlock() }
        return provenIdentity
    }

    /// Record that `identity` just proved the grant via the audible functional
    /// probe. Called only after `functionalGrantProbe()` actually observed
    /// live audio — never from a bare TCC read, which is precisely the signal
    /// this fingerprint exists to not trust blindly.
    public static func recordProvenCodeIdentity(_ identity: String) {
        latchLock.lock()
        provenIdentity = identity
        latchLock.unlock()
    }

    /// Test-only: clear the stored fingerprint. Same rationale as
    /// ``_resetLatchForTesting()`` — process-global state that would otherwise
    /// leak between tests.
    public static func _resetProvenCodeIdentityForTesting() {
        latchLock.lock()
        provenIdentity = nil
        latchLock.unlock()
    }

    /// The authoritative status for the rest of this process's life: the
    /// fresh latch (``recordFreshGrant(source:)``) if one has EVER been
    /// recorded, otherwise the ordinary — and, per this file's whole reason
    /// for existing, potentially process-stale — ``combinedStatus()`` read.
    /// This is what ``isGranted()`` actually consults.
    public static func effectiveStatus() -> Preflight {
        latchLock.lock()
        let latched = latchedGrant
        latchLock.unlock()
        if latched { return .granted }
        return combinedStatus()
    }

    /// True ONLY when the grant is positively in place. **Undetermined and
    /// denied both return `false`** — that's the whole point: a caller that
    /// gates tap creation on this never triggers the system prompt, because an
    /// undetermined grant means "not yet granted; the Setup screen must ask, not
    /// us." Allowing a tap to open on an undetermined combined read would let
    /// macOS fire its own permission dialog cold, with no Setup screen in front
    /// of the user — precisely the failure this guard exists to prevent, so the
    /// refusal on `.undetermined` is deliberate and must not be loosened. This
    /// is intentionally stricter than the probe's
    /// ``CoreAudioTonePermissionProbe/currentStatusSilently()``, which reports a
    /// status for the UI; this answers the narrower "is it safe to open a tap
    /// without prompting?"
    ///
    /// Built on ``effectiveStatus()``, not ``combinedStatus()`` directly, so a
    /// caller that already proved the grant via the fresh-verdict latch never
    /// refuses on a stale in-process cache read — the same refuse-on-anything-
    /// but-granted semantics apply either way.
    public static func isGranted() -> Bool {
        switch effectiveStatus() {
        case .granted:
            return true
        case .denied, .undetermined:
            return false
        }
    }
}
