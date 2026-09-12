// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation

/// Anonymous per-install usage-analytics facade (PRODUCT.md Data
/// Collection stream 1). On by default through the free trial; a paid install
/// is asked once before anything is collected, and the Settings toggle can
/// turn it off at any time. Foundation-only by design: PostHog is deliberately
/// linked ONLY to the `AudioutApp` executable (`AudioutCore/Package.swift`),
/// so UI/library modules must never import it — every capture call in this
/// package routes through here instead, and `AppDelegate` is the one place
/// that installs a real ``Sink`` wrapping the PostHog SDK.
///
/// Callable from any thread but NEVER from the real-time IOProc/render path
/// (the same rule as ``Telemetry``).
///
/// Consent itself is decided in ``AppSettings`` — `telemetryEnabled`, which
/// combines the user's stored answer with the trial-phase default; this type
/// only holds the in-memory flag that gates ``capture(_:_:)`` and forwards
/// changes to the installed sink's `consentChanged` so it can opt the
/// underlying SDK in or out.
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
        /// `capture` with the moment the event really happened. Only the
        /// pre-consent buffer flush uses it (see ``capture(_:_:)``); a sink
        /// that leaves it nil sends those events stamped at flush time.
        public let captureAt: (@Sendable (String, [String: String], Date) -> Void)?

        public init(capture: @escaping @Sendable (String, [String: String]) -> Void,
                    captureError: @escaping @Sendable (String, [String: String]) -> Void,
                    consentChanged: @escaping @Sendable (Bool) -> Void,
                    captureAt: (@Sendable (String, [String: String], Date) -> Void)? = nil) {
            self.capture = capture
            self.captureError = captureError
            self.consentChanged = consentChanged
            self.captureAt = captureAt
        }
    }

    /// Replaces the installed sink and sets the consent flag. Does NOT call
    /// `consentChanged` — this is setup (e.g. at launch, restoring the
    /// persisted `AppSettings.telemetryOptIn`), not a user decision.
    public static func install(_ sink: Sink?, consent: Bool) {
        state.withLock { s in
            s.sink = sink
            s.consent = consent
            s.pending.removeAll()
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
    ///
    /// Granting consent also sends everything ``capture(_:_:)`` held back
    /// while it was off, in order and with their original times,
    /// so the first-run steps that happen BEFORE the usage-statistics card
    /// still reach the onboarding funnel. A decline drops them.
    public static func setConsent(_ granted: Bool) {
        let (sink, held): (Sink?, [Held]) = state.withLock { s in
            // No change, nothing to tell the sink. `applyLicenseState()` re-syncs
            // consent on every licence answer; without this an unchanged grant
            // would re-fire `consentChanged` and send a duplicate launch/location
            // event each time. A repeated "off" still drops what was held: no
            // consent means nothing kept, whether or not the value moved.
            guard s.consent != granted else {
                if !granted { s.pending.removeAll() }
                return (nil, [])
            }
            s.consent = granted
            defer { s.pending.removeAll() }
            return (s.sink, granted ? s.pending : [])
        }
        guard let sink else { return }
        sink.consentChanged(granted)
        for h in held {
            if let captureAt = sink.captureAt { captureAt(h.event, h.properties, h.at) }
            else { sink.capture(h.event, h.properties) }
        }
    }

    /// No-op without a sink. With a sink and consent, calls the sink's
    /// `capture` synchronously on the caller's thread. With a sink but no
    /// consent yet, holds the event in memory — never on disk, never sent —
    /// so a consent granted before the app quits can send it (``setConsent``).
    /// Quitting drops the buffer; so does a decline.
    public static func capture(_ event: StaticString, _ properties: [String: String] = [:]) {
        let snapshot: Sink? = state.withLock { s in
            guard s.sink != nil else { return nil }
            guard s.consent else {
                // razor: a flat cap; the buffer only has to outlive first-run setup.
                if s.pending.count < pendingCap {
                    s.pending.append(Held(event: event.description, properties: properties, at: Date()))
                }
                return nil
            }
            return s.sink
        }
        snapshot?.capture(event.description, properties)
    }

    /// Events held while consent was off. A first run is a few dozen; the
    /// cap exists so a session that never opts in cannot grow unbounded.
    private static let pendingCap = 200

    private struct Held: Sendable {
        let event: String
        let properties: [String: String]
        let at: Date
    }

    /// Report a failure the user actually felt — audio that stopped, a
    /// settings file that would not save — to PostHog error tracking, so the
    /// stream of what breaks in the field is visible next to what gets used.
    /// No sink or no consent, no send.
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
    ///
    /// One difference from ``capture(_:_:)``: a failure that happens before
    /// the user answers the consent ask is dropped, not held for a later
    /// grant. Only events are buffered.
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
        var pending: [Held] = []
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

/// Decides whether today's `streaming:daily_active` event is still owed.
///
/// One event per local-calendar day on which audio actually reached a real
/// speaker, so the answer needs both the day already spent and the fleet.
/// Pure: the caller persists the returned day.
public enum DailyActiveLatch {

    /// `nil` when today is already spent or nothing is streaming; otherwise the
    /// number of connected non-local speakers and the day string to store.
    public static func due(devices: [Device],
                           lastDay: String?,
                           now: Date = Date(),
                           calendar: Calendar = .current) -> (speakerCount: Int, day: String)? {
        let today = day(of: now, calendar: calendar)
        guard today != lastDay else { return nil }
        // The Mac's own output is not a speaker Audiout sent audio to.
        let count = devices.filter { $0.connectionState == .connected && !$0.isLocalDevice }.count
        guard count > 0 else { return nil }
        return (count, today)
    }

    /// `yyyy-MM-dd` in the given calendar — built from components rather than a
    /// `DateFormatter` so no locale can reshape it.
    static func day(of date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
