// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

/// Opt-in, anonymous per-install usage-analytics facade (PRODUCT.md Data
/// Collection stream 1). Foundation-only by design: PostHog is deliberately
/// linked ONLY to the `AudioutApp` executable (`AudioutCore/Package.swift`),
/// so UI/library modules must never import it — every capture call in this
/// package routes through here instead, and `AppDelegate` is the one place
/// that installs a real ``Sink`` wrapping the PostHog SDK.
///
/// Callable from any thread but NEVER from the real-time IOProc/render path
/// (the same rule as ``Telemetry``).
///
/// Consent itself is persisted in ``AppSettings`` (`telemetryOptIn`); this
/// type only holds the in-memory flag that gates ``capture(_:_:)`` and
/// forwards changes to the installed sink's `consentChanged` so it can
/// opt the underlying SDK in or out.
///
/// A `nil` sink is the off state — no queue, no disk, no `HeadlessRuntime`
/// read. Only `AppDelegate` and tests ever install one.
public enum Analytics {

    /// A capture destination: `capture` receives the event name and
    /// properties, `captureError` receives a failure name and properties,
    /// `consentChanged` receives the new consent value whenever
    /// ``setConsent(_:)`` is called.
    ///
    /// `captureError` has no default. A sink that quietly dropped failures
    /// would be indistinguishable from a build where nothing ever failed, so
    /// every sink has to say what it does with them.
    public struct Sink: Sendable {
        public let capture: @Sendable (String, [String: String]) -> Void
        public let captureError: @Sendable (String, [String: String]) -> Void
        public let consentChanged: @Sendable (Bool) -> Void

        public init(capture: @escaping @Sendable (String, [String: String]) -> Void,
                    captureError: @escaping @Sendable (String, [String: String]) -> Void,
                    consentChanged: @escaping @Sendable (Bool) -> Void) {
            self.capture = capture
            self.captureError = captureError
            self.consentChanged = consentChanged
        }
    }

    /// Replaces the installed sink and sets the consent flag. Does NOT call
    /// `consentChanged` — this is setup (e.g. at launch, restoring the
    /// persisted `AppSettings.telemetryOptIn`), not a user decision.
    public static func install(_ sink: Sink?, consent: Bool) {
        state.withLock { s in
            s.sink = sink
            s.consent = consent
        }
    }

    /// Whether a capture destination is installed at all — independent of
    /// consent. The Setup window's usage-statistics step reads it: a build
    /// with no sink (run-from-source, `swift run`, headless) has nothing to
    /// opt in to, so the ask must not appear there at all.
    public static var isAvailable: Bool {
        state.withLock { $0.sink != nil }
    }

    /// Updates the consent flag, then forwards the new value to the
    /// installed sink's `consentChanged` — the user's actual opt-in/out
    /// decision (Settings › General toggle, or the one-time ask).
    public static func setConsent(_ granted: Bool) {
        let sink: Sink? = state.withLock { s in
            s.consent = granted
            return s.sink
        }
        sink?.consentChanged(granted)
    }

    /// No-op unless a sink is installed AND consent is true; otherwise calls
    /// the sink's `capture` synchronously on the caller's thread.
    public static func capture(_ event: StaticString, _ properties: [String: String] = [:]) {
        let snapshot: Sink? = state.withLock { s in
            guard s.consent else { return nil }
            return s.sink
        }
        snapshot?.capture(event.description, properties)
    }

    /// Report a failure the user actually felt — audio that stopped, a
    /// settings file that would not save — to PostHog error tracking, so the
    /// stream of what breaks in the field is visible next to what gets used.
    /// Gated exactly like ``capture(_:_:)``: no sink or no consent, no send.
    ///
    /// `name` is a `StaticString` for the same reason event names are: it can
    /// only ever be a literal written into this repo, so no runtime value can
    /// reach PostHog as the failure's identity. `properties` carry the same
    /// fence as every other event (PRODUCT.md Data Collection) — counts,
    /// enum-like strings and booleans, never a speaker name, a user's bundle
    /// id, a file path, or anything typed. Cocoa error descriptions are the
    /// trap here: `localizedDescription` routinely embeds a full local path,
    /// so send the domain and the code instead.
    ///
    /// Name failures `category:object_failed` in snake_case, matching
    /// ``capture(_:_:)``'s event naming.
    ///
    /// Crashes need no call: the SDK's own `errorTrackingConfig.autoCapture`
    /// (set in `AppDelegate.configurePostHog()`) reports the unhandled ones.
    /// This is for the handled failures, which nothing else would ever see.
    public static func captureError(_ name: StaticString, _ properties: [String: String] = [:]) {
        let snapshot: Sink? = state.withLock { s in
            guard s.consent else { return nil }
            return s.sink
        }
        snapshot?.captureError(name.description, properties)
    }

    // MARK: - Implementation

    private struct State: Sendable {
        var sink: Sink?
        var consent = false
    }

    /// Minimal `NSLock`-guarded box — same pattern as ``Telemetry``'s
    /// `Locked<Value>` in this package.
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private static let state = Locked(State())
}
