// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
@testable import AudioutedCore
@testable import AudioutedPopoverUI

/// Structural coverage for the standalone diagnosis panel (brief §7.1). This
/// view has no backend/pasteboard access of its own, so these tests only cover
/// rendering, button enablement, closure firing, and sizing sanity at popover
/// width — the same kind of coverage `PopoverControllerTests` gives the rest
/// of the popover UI.
@MainActor
final class ConnectionDiagnosisViewTests: XCTestCase {

    // MARK: Copy rendering per cause

    func testHeadlineAndSuggestionMatchFailureCopy() {
        let failure = ConnectionFailure(cause: .notResponding)
        let view = ConnectionDiagnosisView(failure: failure, deviceName: "Living Room")
        XCTAssertEqual(view.test_headlineText, failure.headline)
        XCTAssertEqual(view.test_suggestionText, failure.suggestion)
    }

    func testAllCausesRenderTheirOwnCopy() {
        let causes: [ConnectionFailure.Cause] = [
            .notResponding, .vanished, .refusedOrBusy, .authRequired,
            .droppedMidStream, .timedOut, .unknown,
        ]
        for cause in causes {
            let failure = ConnectionFailure(cause: cause)
            let view = ConnectionDiagnosisView(failure: failure, deviceName: "Kitchen")
            XCTAssertEqual(view.test_headlineText, failure.headline, "headline for \(cause)")
            XCTAssertEqual(view.test_suggestionText, failure.suggestion, "suggestion for \(cause)")
        }
    }

    func testApplyUpdatesRenderedCopyAndDeviceName() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .timedOut), deviceName: "Office")
        let replaced = ConnectionFailure(cause: .refusedOrBusy, detail: "403 from speaker")
        view.apply(failure: replaced, deviceName: "Office")
        XCTAssertEqual(view.test_headlineText, "Connection refused")
        XCTAssertEqual(view.test_suggestionText, replaced.suggestion)
        XCTAssertTrue(view.test_copyDetailsEnabled)
    }

    // MARK: Button enablement — Copy details iff failure.detail != nil

    func testCopyDetailsDisabledWhenNoDetail() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .vanished, detail: nil), deviceName: "Bedroom")
        XCTAssertFalse(view.test_copyDetailsEnabled)
    }

    func testCopyDetailsEnabledWhenDetailPresent() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .vanished, detail: "No response from Bedroom"),
            deviceName: "Bedroom")
        XCTAssertTrue(view.test_copyDetailsEnabled)
    }

    func testCopyDetailsEnablementFollowsReappliedFailure() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .unknown, detail: "some evidence"), deviceName: "Den")
        XCTAssertTrue(view.test_copyDetailsEnabled)
        view.apply(failure: ConnectionFailure(cause: .unknown, detail: nil), deviceName: "Den")
        XCTAssertFalse(view.test_copyDetailsEnabled)
    }

    // MARK: Closure firing — host owns the pasteboard write

    func testTapRetryFiresOnRetry() {
        let view = ConnectionDiagnosisView(failure: ConnectionFailure(cause: .timedOut), deviceName: "Patio")
        var fired = false
        view.onRetry = { fired = true }
        view.test_tapRetry()
        XCTAssertTrue(fired)
    }

    func testTapCopyDetailsFiresOnCopyDetailsWithoutTouchingPasteboard() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .droppedMidStream, detail: "dropped at 12:00"),
            deviceName: "Garage")
        var fired = false
        view.onCopyDetails = { fired = true }
        let before = NSPasteboard.general.changeCount
        view.test_tapCopyDetails()
        XCTAssertTrue(fired)
        // The view itself never writes the pasteboard (host's job, brief §7.3).
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }

    func testTapCopyDetailsFiresEvenWhenDisabled() {
        // Programmatic invocation (e.g. via a future keyboard path) should still
        // call through; `isEnabled` only gates real mouse/AX clicks.
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .vanished, detail: nil), deviceName: "Attic")
        var fired = false
        view.onCopyDetails = { fired = true }
        view.test_tapCopyDetails()
        XCTAssertTrue(fired)
    }

    // MARK: Appearance adaptivity — the tint is a static CGColor on the layer

    func testBackgroundTintReResolvesOnAppearanceChange() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .notResponding), deviceName: "Hall")

        view.appearance = NSAppearance(named: .aqua)
        let light = view.test_backgroundTint
        view.appearance = NSAppearance(named: .darkAqua)
        let dark = view.test_backgroundTint

        // systemOrange resolves to different concrete values per appearance; a
        // tint captured once at build time would be identical across the switch.
        XCTAssertNotEqual(light?.components, dark?.components,
                          "the warning tint must re-resolve on a live light/dark switch")

        // And the re-resolved color is exactly systemOrange(0.12) under the
        // NEW appearance, not some third value.
        var expected: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            expected = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        }
        XCTAssertEqual(dark?.components, expected?.components)
    }

    // MARK: Sizing sanity at popover width

    func testSelfSizesToNonZeroHeightAtPopoverWidth() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .refusedOrBusy), deviceName: "Living Room")
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 0)
        view.layoutSubtreeIfNeeded()
        let fittingHeight = view.fittingSize.height
        XCTAssertGreaterThan(fittingHeight, 0)
    }

    func testLongSuggestionWrapsIntoTallerHeightThanShortOne() {
        let short = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .authRequired), deviceName: "Loft")
        short.frame = NSRect(x: 0, y: 0, width: 320, height: 0)
        short.layoutSubtreeIfNeeded()

        let long = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .notResponding), deviceName: "Loft")
        long.frame = NSRect(x: 0, y: 0, width: 320, height: 0)
        long.layoutSubtreeIfNeeded()

        // `.notResponding`'s suggestion is the longest copy in the table; a
        // narrower fixed-width row should force it to wrap across more lines
        // than the (shorter) `.authRequired` copy, i.e. a taller fitting height.
        XCTAssertGreaterThan(long.fittingSize.height, short.fittingSize.height)
    }

    func testNarrowerWidthWrapsToTallerHeight() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .notResponding), deviceName: "Study")
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 0)
        view.layoutSubtreeIfNeeded()
        let wideHeight = view.fittingSize.height

        view.frame = NSRect(x: 0, y: 0, width: 220, height: 0)
        view.layoutSubtreeIfNeeded()
        let narrowHeight = view.fittingSize.height

        XCTAssertGreaterThanOrEqual(narrowHeight, wideHeight)
    }
}
