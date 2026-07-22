// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Darwin   // dlopen/dlsym for the private TCC audio-capture status read

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A silent, prompt-free read of the **System Audio Recording** (process-tap)
/// TCC grant — the single source of truth the capture coordinators consult
/// before creating ANY `AudioHardwareCreateProcessTap`.
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
/// ## Where the grant lives
/// macOS keys the process-tap grant to `kTCCServiceAudioCapture` on 14.4+ (read
/// via the private `TCCAccessPreflight`), and to Screen Recording on 14.2–14.3
/// (read via `CGPreflightScreenCaptureAccess`). Both reads are silent — no tap,
/// no tone, no prompt.
public enum SystemAudioCaptureTCC {

    /// tccd's authorization values for `TCCAccessPreflight` (private TCC API).
    enum Preflight { case granted, denied, undetermined }

    /// The live `kTCCServiceAudioCapture` decision (macOS 14.4+), or `nil` when
    /// the private TCC framework/symbol can't be resolved (pre-14.4, where the
    /// tap grant still lives under Screen Recording — read via CGPreflight in
    /// ``isGranted()``).
    static func preflight() -> Preflight? {
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

    /// True ONLY when the grant is positively in place. **Undetermined and
    /// denied both return `false`** — that's the whole point: a caller that
    /// gates tap creation on this never triggers the system prompt, because an
    /// undetermined grant means "not yet granted; the Setup screen must ask, not
    /// us." This is intentionally stricter than the probe's
    /// ``CoreAudioTonePermissionProbe/currentStatusSilently()``, which reports a
    /// status for the UI; this answers the narrower "is it safe to open a tap
    /// without prompting?"
    public static func isGranted() -> Bool {
        switch preflight() {
        case .granted:
            return true
        case .denied, .undetermined:
            return false
        case nil:
            // Pre-14.4: the tap grant lives under Screen Recording, which
            // CGPreflight reads (true ONLY when actually granted — false covers
            // both denied and undetermined, so it's safe to gate on).
            #if canImport(CoreGraphics)
            return CGPreflightScreenCaptureAccess()
            #else
            return false
            #endif
        }
    }
}
