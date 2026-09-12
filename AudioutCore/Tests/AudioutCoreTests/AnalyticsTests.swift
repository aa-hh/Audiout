// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 ahh and contributors.

import Foundation
import Testing
@testable import AudioutCore

/// Covers `Analytics` (`Sources/AudioutCore/Analytics.swift`): the no-sink
/// no-op default, the consent gate on `capture(_:_:)` and
/// `captureError(_:_:)`, the separation of the two delivery paths, and
/// `setConsent`'s forwarding to the installed sink's `consentChanged`.
///
/// Nested under `SerializedSharedState` because `Analytics.install`/
/// `setConsent` mutate process-global state that would otherwise race any
/// other test in this parent suite running concurrently — same reasoning as
/// `TelemetryTests`. Every test restores `Analytics.install(nil, consent:
/// false)` before returning so the next test in line starts from the
/// neutral, off state.
extension SerializedSharedState {
    @Suite struct AnalyticsTests {

        @Test func captureWithNoSinkIsASafeNoOp() {
            Analytics.install(nil, consent: true)
            defer { Analytics.install(nil, consent: false) }
            Analytics.capture("test_event", ["k": "v"])
            // No crash, no observable effect — nothing further to assert.
        }

        @Test func installedSinkWithConsentFalseDoesNotCapture() {
            let captured = Captured()
            Analytics.install(Analytics.Sink(capture: { name, props in
                captured.append(name, props)
            }, captureError: { _, _ in }, consentChanged: { _ in }), consent: false)
            defer { Analytics.install(nil, consent: false) }

            Analytics.capture("test_event", ["k": "v"])

            #expect(captured.events().isEmpty)
        }

        @Test func installedSinkWithConsentTrueDeliversNameAndProperties() {
            let captured = Captured()
            Analytics.install(Analytics.Sink(capture: { name, props in
                captured.append(name, props)
            }, captureError: { _, _ in }, consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }

            Analytics.capture("test_event", ["k": "v"])

            let events = captured.events()
            #expect(events.count == 1)
            #expect(events.first?.0 == "test_event")
            #expect(events.first?.1 == ["k": "v"])
        }

        @Test func eventsBeforeConsentAreHeldAndSentInOrderOnceGranted() {
            let captured = Captured()
            let dated = Captured()
            Analytics.install(Analytics.Sink(capture: { name, props in
                captured.append(name, props)
            }, captureError: { _, _ in }, consentChanged: { _ in }, captureAt: { name, props, _ in
                dated.append(name, props)
            }), consent: false)
            defer { Analytics.install(nil, consent: false) }

            Analytics.capture("first", ["step": "audio"])
            Analytics.capture("second", ["step": "local_network"])
            #expect(captured.events().isEmpty)
            #expect(dated.events().isEmpty)

            Analytics.setConsent(true)

            #expect(dated.events().map(\.0) == ["first", "second"])
            #expect(dated.events().first?.1 == ["step": "audio"])
            #expect(captured.events().isEmpty)

            // The buffer is spent: a second grant sends nothing twice.
            Analytics.setConsent(true)
            #expect(dated.events().count == 2)
        }

        @Test func heldEventsFallBackToPlainCaptureWithoutADatedSink() {
            let captured = Captured()
            Analytics.install(Analytics.Sink(capture: { name, props in
                captured.append(name, props)
            }, captureError: { _, _ in }, consentChanged: { _ in }), consent: false)
            defer { Analytics.install(nil, consent: false) }

            Analytics.capture("held")
            Analytics.setConsent(true)

            #expect(captured.events().map(\.0) == ["held"])
        }

        @Test func declinedConsentDropsHeldEvents() {
            let captured = Captured()
            Analytics.install(Analytics.Sink(capture: { name, props in
                captured.append(name, props)
            }, captureError: { _, _ in }, consentChanged: { _ in }), consent: false)
            defer { Analytics.install(nil, consent: false) }

            Analytics.capture("held")
            Analytics.setConsent(false)
            Analytics.setConsent(true)

            #expect(captured.events().isEmpty)
        }

        /// `captureError` carries the same consent gate as `capture` — an
        /// opted-out user's failures must not reach PostHog error tracking
        /// through the back door the crash reporter opened.
        @Test(arguments: [false, true])
        func captureErrorObeysTheConsentGate(consent: Bool) {
            let errors = Captured()
            Analytics.install(Analytics.Sink(capture: { _, _ in },
                                             captureError: { name, props in
                                                 errors.append(name, props)
                                             },
                                             consentChanged: { _ in }), consent: consent)
            defer { Analytics.install(nil, consent: false) }

            Analytics.captureError("capture:whole_system_failed", ["kind": "device_lost"])

            #expect(errors.events().count == (consent ? 1 : 0))
            if consent {
                #expect(errors.events().first?.0 == "capture:whole_system_failed")
                #expect(errors.events().first?.1 == ["kind": "device_lost"])
            }
        }

        /// The two paths are separate deliveries, not one renamed: an event
        /// must never arrive as an exception (it would raise a PostHog issue
        /// for a button press), and a failure must never arrive as a plain
        /// event (it would lose its stack trace).
        @Test func captureAndCaptureErrorDoNotCrossOver() {
            let events = Captured()
            let errors = Captured()
            Analytics.install(Analytics.Sink(capture: { events.append($0, $1) },
                                             captureError: { errors.append($0, $1) },
                                             consentChanged: { _ in }), consent: true)
            defer { Analytics.install(nil, consent: false) }

            Analytics.capture("mixer:device_selected")
            Analytics.captureError("settings:save_failed")

            #expect(events.events().map(\.0) == ["mixer:device_selected"])
            #expect(errors.events().map(\.0) == ["settings:save_failed"])
        }

        @Test func setConsentForwardsToConsentChangedAndGatesSubsequentCaptures() {
            let captured = Captured()
            let consentChanges = ConsentChanges()
            Analytics.install(Analytics.Sink(capture: { name, props in
                captured.append(name, props)
            }, captureError: { _, _ in }, consentChanged: { granted in
                consentChanges.append(granted)
            }), consent: false)
            defer { Analytics.install(nil, consent: false) }

            Analytics.setConsent(true)
            #expect(consentChanges.values() == [true])
            Analytics.capture("after_opt_in")
            #expect(captured.events().count == 1)

            Analytics.setConsent(false)
            #expect(consentChanges.values() == [true, false])
            Analytics.capture("after_opt_out")
            #expect(captured.events().count == 1, "capture must be gated off again after opting out")
        }

        /// `applyLicenseState()` re-syncs consent on every validator answer, so
        /// an unchanged grant reaches `setConsent` repeatedly. Each forward
        /// costs one duplicate launch/location event, so it must forward once.
        @Test func repeatedGrantForwardsToConsentChangedOnlyOnce() {
            let consentChanges = ConsentChanges()
            Analytics.install(Analytics.Sink(capture: { _, _ in },
                                             captureError: { _, _ in },
                                             consentChanged: { consentChanges.append($0) }),
                              consent: false)
            defer { Analytics.install(nil, consent: false) }

            Analytics.setConsent(true)
            Analytics.setConsent(true)
            Analytics.setConsent(true)

            #expect(consentChanges.values() == [true])
        }

        /// `streaming:daily_active` answers "on how many days did audio reach a
        /// real speaker", so it is one event per local day, and only while
        /// something other than this Mac is connected.
        @Test(arguments: [
            (lastDay: nil as String?, connected: 2, local: 0, expected: 2 as Int?),
            (lastDay: "2026-09-12", connected: 2, local: 0, expected: nil),
            (lastDay: "2026-09-11", connected: 2, local: 0, expected: 2),
            (lastDay: nil, connected: 0, local: 1, expected: nil),
        ])
        func dailyActiveLatchFiresOncePerDayAndIgnoresTheMacsOwnOutput(
            row: (lastDay: String?, connected: Int, local: Int, expected: Int?)
        ) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 10))!

            let devices = (0..<row.connected).map { streamingDevice(id: "remote-\($0)", local: false) }
                + (0..<row.local).map { streamingDevice(id: "local-\($0)", local: true) }

            let due = DailyActiveLatch.due(devices: devices,
                                           lastDay: row.lastDay,
                                           now: now,
                                           calendar: calendar)

            #expect(due?.speakerCount == row.expected)
            if row.expected != nil { #expect(due?.day == "2026-09-12") }
        }

        private func streamingDevice(id: String, local: Bool) -> Device {
            Device(id: id,
                   name: id,
                   kind: local ? .localMac : .generic,
                   isLocalDevice: local,
                   connectionState: .connected)
        }
    }
}

/// Captures the (name, properties) pairs a test sink received. `Analytics`
/// calls the sink synchronously on the caller's thread, but a plain array
/// still needs its own lock for tests that assert from a different thread
/// than the capture happened on.
private final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, [String: String])] = []
    func append(_ name: String, _ props: [String: String]) {
        lock.withLock { items.append((name, props)) }
    }
    func events() -> [(String, [String: String])] {
        lock.withLock { items }
    }
}

private final class ConsentChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool] = []
    func append(_ value: Bool) {
        lock.withLock { items.append(value) }
    }
    func values() -> [Bool] {
        lock.withLock { items }
    }
}
