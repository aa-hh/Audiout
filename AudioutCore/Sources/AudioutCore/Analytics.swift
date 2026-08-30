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
    /// properties, `consentChanged` receives the new consent value whenever
    /// ``setConsent(_:)`` is called.
    public struct Sink: Sendable {
        public let capture: @Sendable (String, [String: String]) -> Void
        public let consentChanged: @Sendable (Bool) -> Void

        public init(capture: @escaping @Sendable (String, [String: String]) -> Void,
                    consentChanged: @escaping @Sendable (Bool) -> Void) {
            self.capture = capture
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
