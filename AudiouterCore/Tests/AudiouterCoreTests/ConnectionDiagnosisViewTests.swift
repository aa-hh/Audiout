// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
@testable import AudiouterCore
@testable import AudiouterPopoverUI
import AudiouterSharedUI

/// Structural coverage for the standalone diagnosis panel (brief §7.1). This
/// view has no backend/pasteboard access of its own, so these tests only cover
/// rendering, button enablement, closure firing, and sizing sanity at popover
/// width — the same kind of coverage `PopoverControllerTests` gives the rest
/// of the popover UI.
@MainActor
@Suite struct ConnectionDiagnosisViewTests {

    // MARK: Copy rendering per cause

    @Test func headlineAndSuggestionMatchFailureCopy() {
        let failure = ConnectionFailure(cause: .notResponding)
        let view = ConnectionDiagnosisView(failure: failure, deviceName: "Living Room")
        #expect(view.test_headlineText == failure.headline)
        #expect(view.test_suggestionText == failure.suggestion)
    }

    @Test func allCausesRenderTheirOwnCopy() {
        let causes: [ConnectionFailure.Cause] = [
            .notResponding, .vanished, .refusedOrBusy, .authRequired,
            .droppedMidStream, .timedOut, .unknown,
        ]
        for cause in causes {
            let failure = ConnectionFailure(cause: cause)
            let view = ConnectionDiagnosisView(failure: failure, deviceName: "Kitchen")
            #expect(view.test_headlineText == failure.headline, "headline for \(cause)")
            #expect(view.test_suggestionText == failure.suggestion, "suggestion for \(cause)")
        }
    }

    @Test func applyUpdatesRenderedCopyAndDeviceName() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .timedOut), deviceName: "Office")
        let replaced = ConnectionFailure(cause: .refusedOrBusy, detail: "403 from speaker")
        view.apply(failure: replaced, deviceName: "Office")
        #expect(view.test_headlineText == "Connection refused")
        #expect(view.test_suggestionText == replaced.suggestion)
        #expect(view.test_copyDetailsEnabled)
    }

    // MARK: Button enablement — Copy details iff failure.detail != nil

    @Test func copyDetailsDisabledWhenNoDetail() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .vanished, detail: nil), deviceName: "Bedroom")
        #expect(!view.test_copyDetailsEnabled)
    }

    @Test func copyDetailsEnabledWhenDetailPresent() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .vanished, detail: "No response from Bedroom"),
            deviceName: "Bedroom")
        #expect(view.test_copyDetailsEnabled)
    }

    @Test func copyDetailsEnablementFollowsReappliedFailure() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .unknown, detail: "some evidence"), deviceName: "Den")
        #expect(view.test_copyDetailsEnabled)
        view.apply(failure: ConnectionFailure(cause: .unknown, detail: nil), deviceName: "Den")
        #expect(!view.test_copyDetailsEnabled)
    }

    // MARK: Closure firing — host owns the pasteboard write

    @Test func tapRetryFiresOnRetry() {
        let view = ConnectionDiagnosisView(failure: ConnectionFailure(cause: .timedOut), deviceName: "Patio")
        var fired = false
        view.onRetry = { fired = true }
        view.test_tapRetry()
        #expect(fired)
    }

    @Test func tapCopyDetailsFiresOnCopyDetailsWithoutTouchingPasteboard() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .droppedMidStream, detail: "dropped at 12:00"),
            deviceName: "Garage")
        var fired = false
        view.onCopyDetails = { fired = true }
        let before = NSPasteboard.general.changeCount
        view.test_tapCopyDetails()
        #expect(fired)
        // The view itself never writes the pasteboard (host's job, brief §7.3).
        #expect(NSPasteboard.general.changeCount == before)
    }

    @Test func tapCopyDetailsFiresEvenWhenDisabled() {
        // Programmatic invocation (e.g. via a future keyboard path) should still
        // call through; `isEnabled` only gates real mouse/AX clicks.
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .vanished, detail: nil), deviceName: "Attic")
        var fired = false
        view.onCopyDetails = { fired = true }
        view.test_tapCopyDetails()
        #expect(fired)
    }

    @Test func tapDismissFiresOnDismissExactlyOnce() {
        let view = ConnectionDiagnosisView(failure: ConnectionFailure(cause: .timedOut), deviceName: "Porch")
        var fireCount = 0
        view.onDismiss = { fireCount += 1 }
        view.test_tapDismiss()
        #expect(fireCount == 1)
    }

    @Test func hasDismissButton() {
        let view = ConnectionDiagnosisView(failure: ConnectionFailure(cause: .vanished), deviceName: "Yard")
        #expect(view.test_hasDismissButton)
    }

    // MARK: Appearance adaptivity — the tint is a static CGColor on the layer

    @Test func backgroundTintReResolvesOnAppearanceChange() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .notResponding), deviceName: "Hall")

        view.appearance = NSAppearance(named: .aqua)
        let light = view.test_backgroundTint
        view.appearance = NSAppearance(named: .darkAqua)
        let dark = view.test_backgroundTint

        // The warm tokens resolve to different concrete values per appearance;
        // a tint captured once at build time would be identical across the switch.
        #expect(light?.components != dark?.components,
                "the failure tint must re-resolve on a live light/dark switch")

        // And the re-resolved color is exactly the spec §5.6 treatment — the
        // `panel` seat washed with the failure-exclusive red at ~12% — under
        // the NEW appearance, not some third value.
        var expected: CGColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let seat = Tokens.Color.panel
            expected = (seat.blended(withFraction: 0.12, of: Tokens.Color.failure) ?? seat).cgColor
        }
        #expect(dark?.components == expected?.components)
    }

    // MARK: Sizing sanity at popover width

    @Test func selfSizesToNonZeroHeightAtPopoverWidth() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .refusedOrBusy), deviceName: "Living Room")
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 0)
        view.layoutSubtreeIfNeeded()
        let fittingHeight = view.fittingSize.height
        #expect(fittingHeight > 0)
    }

    @Test func longSuggestionWrapsIntoTallerHeightThanShortOne() {
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
        #expect(long.fittingSize.height > short.fittingSize.height)
    }

    @Test func narrowerWidthWrapsToTallerHeight() {
        let view = ConnectionDiagnosisView(
            failure: ConnectionFailure(cause: .notResponding), deviceName: "Study")
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 0)
        view.layoutSubtreeIfNeeded()
        let wideHeight = view.fittingSize.height

        view.frame = NSRect(x: 0, y: 0, width: 220, height: 0)
        view.layoutSubtreeIfNeeded()
        let narrowHeight = view.fittingSize.height

        #expect(narrowHeight >= wideHeight)
    }
}
