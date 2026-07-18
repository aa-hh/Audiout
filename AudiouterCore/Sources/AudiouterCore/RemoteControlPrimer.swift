// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if canImport(ApplicationServices)
import ApplicationServices
#endif

/// Constructs the production ``RemoteControlPriming``. `ApplicationServices`
/// (home of `AXIsProcessTrustedWithOptions`) ships on every supported macOS; the
/// `#else` exists only so the type compiles where it's absent.
public enum RemoteControlPrimerFactory {
    public static func makeDefault() -> RemoteControlPriming {
        #if canImport(ApplicationServices)
        return RemoteControlPrimer()
        #else
        return NoopRemoteControlPrimer()
        #endif
    }
}

/// No-op fallback (non-ApplicationServices platforms only) — never trusted.
public struct NoopRemoteControlPrimer: RemoteControlPriming {
    public init() {}
    public func prime() {}
    public func isTrusted() -> Bool { false }
}

#if canImport(ApplicationServices)

/// Triggers and reads the macOS **Accessibility** permission.
///
/// - `prime()` opens the prompt via `AXIsProcessTrustedWithOptions([prompt:true])`.
/// - `isTrusted()` reads the LIVE state via `AXIsProcessTrusted()` — a public,
///   synchronous call that does NOT prompt. Polling it (``SetupModel`` does, on
///   every window focus) is how the flow reflects a grant the user makes in System
///   Settings while the app is running, without a relaunch. (The earlier caution
///   that this needed a relaunch conflated *observation* — there's no push
///   notification — with *polling*, which returns the current value each call.)
public final class RemoteControlPrimer: RemoteControlPriming {
    public init() {}

    public func prime() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public func isTrusted() -> Bool {
        let trusted = AXIsProcessTrusted()
        // AIRPLAY_DEBUG_SETUP=1 → log each read, to tell "AX never flips true this
        // process (needs relaunch — the known Accessibility caching)" apart from
        // "flips true but the UI didn't re-check". Opt-in so it's silent by default.
        if ProcessInfo.processInfo.environment["AIRPLAY_DEBUG_SETUP"] == "1" {
            FileHandle.standardError.write(Data("[Audiouter] AXIsProcessTrusted() = \(trusted)\n".utf8))
        }
        return trusted
    }
}

#endif
