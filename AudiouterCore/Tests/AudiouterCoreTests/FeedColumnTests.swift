// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AppKit
import AudiouterCore
@testable import AudiouterSharedUI

/// Warm Signal v4.1 item 3 — the device row's trailing **FEED** column: the
/// multi-source composite (`DeviceRowView.updateFeedText`), its error override
/// (failed/unavailable), the AP1 micro-tag, the STATIC "+N" overflow, and the
/// split with the sublabel (which now carries only state words on a bus row).
/// Only a BUS row (`showsBus: true`, the popover's real host) mounts a FEED
/// column at all — see `MembershipBusTests`/`DeviceRowConnectionStateTests`
/// for the non-bus host's unchanged legacy sublabel behavior.
@MainActor
final class FeedColumnTests: IsolatedTestCase {

    private func makeDevice(connectionState: ConnectionState = .connected,
                            isAvailable: Bool = true,
                            supportsAirPlay2: Bool = true) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
               isAvailable: isAvailable, supportsAirPlay2: supportsAirPlay2,
               connectionState: connectionState)
    }

    private func makeBusRow(device: Device? = nil) -> DeviceRowView {
        DeviceRowView(device: device ?? makeDevice(), showsToggle: true,
                      paintsSelectionBackground: false, showsMeter: true, showsBus: true)
    }

    // MARK: Multi-source composite — never collapses to one reason

    func testManualMemberAloneShowsSystem() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        XCTAssertEqual(row.test_feedText, "System")
    }

    func testGroupMemberShowsTheGroupNameInsteadOfSystem() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, inActiveTarget: true,
                  mainOutTargetsGroupName: "Downstairs")
        XCTAssertEqual(row.test_feedText, "Downstairs",
                       "the neutral segment's WORD carries manual-vs-group, no extra glyph")
    }

    func testAppRedirectAloneWithNoMainMixMembership() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, controllable: true, routedAppNames: ["Safari"])
        XCTAssertEqual(row.test_feedText, "Safari", "app-only: no main-mix segment at all")
    }

    func testManualMemberPlusOneApp() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        XCTAssertEqual(row.test_feedText, "System · Music")
    }

    func testGroupMemberPlusOneApp() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, routedAppNames: ["Music"],
                  inActiveTarget: true, mainOutTargetsGroupName: "Downstairs")
        XCTAssertEqual(row.test_feedText, "Downstairs · Music")
    }

    func testManualMemberPlusTwoApps() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Music", "Safari"])
        XCTAssertEqual(row.test_feedText, "System · Music · Safari",
                       "never collapses — both redirects show alongside the main-mix segment")
    }

    func testNeitherMainMixNorAppsShowsNothing() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false)
        XCTAssertNil(row.test_feedText)
    }

    func testLiveAppNamesTakePrecedenceOverRoutedAppNamesInFeed() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, controllable: true,
                  routedAppNames: ["Spotify"], liveAppNames: ["Music"])
        XCTAssertEqual(row.test_feedText, "Music",
                       "the FEED column mirrors the same T9 live-over-intent precedence")
    }

    // MARK: Error overrides the feed (failure-red words)

    func testFailedOverridesTheFeedWithCouldntConnect() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, controllable: true, routedAppNames: ["Music"])
        XCTAssertEqual(row.test_feedText, "Couldn't connect",
                       "failure overrides the composite entirely — never both")
        XCTAssertTrue(row.test_feedIsErrorColored)
        XCTAssertNil(row.test_statusText, "the sublabel carries no words for a failed bus row")
    }

    func testUnavailableOverridesTheFeed() {
        let row = makeBusRow()
        row.apply(makeDevice(isAvailable: false), selected: true, routedAppNames: ["Music"])
        XCTAssertEqual(row.test_feedText, "Unavailable")
        XCTAssertTrue(row.test_feedIsErrorColored)
    }

    // MARK: Connecting/reconnecting/muted are NOT shown in the FEED column

    func testConnectingShowsTheMultiSourceCompositeNotAConnectingWord() {
        // The halo ring owns transient connection state; the muted-unconnected
        // rule greys the whole row, but the FEED column itself still composes
        // normally (no "connecting…" word duplicated here).
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        XCTAssertEqual(row.test_feedText, "System")
        XCTAssertFalse(row.test_feedIsErrorColored)
    }

    func testMutedRowsFeedStillShowsTheCompositeMuteLivesOnTheControl() {
        var muted = makeDevice()
        muted.isMuted = true
        let row = makeBusRow()
        row.apply(muted, selected: true, controllable: true, routedAppNames: ["Music"])
        XCTAssertEqual(row.test_feedText, "System · Music",
                       "muted is not represented in the FEED column at all")
        XCTAssertEqual(row.test_statusText, "MUTED", "…it lives on the sublabel/mute-pill instead")
    }

    // MARK: AP1 micro-tag — the one true exception, AP2 never badged

    func testAP1DeviceGetsTheMicroTagPrefix() {
        let row = makeBusRow()
        row.apply(makeDevice(supportsAirPlay2: false), selected: true, controllable: true)
        XCTAssertTrue(row.test_feedHasAP1Tag)
        XCTAssertEqual(row.test_feedText, "AP1 System")
    }

    func testAP2DeviceNeverGetsATag() {
        let row = makeBusRow()
        row.apply(makeDevice(supportsAirPlay2: true), selected: true, controllable: true)
        XCTAssertFalse(row.test_feedHasAP1Tag)
    }

    func testFailedAP1DeviceShowsTheErrorWithNoTag() {
        // The error override takes the WHOLE column — no tag mixed in.
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .vanished)), supportsAirPlay2: false),
                  selected: true, controllable: true)
        XCTAssertEqual(row.test_feedText, "Couldn't connect")
        XCTAssertFalse(row.test_feedHasAP1Tag)
    }

    // MARK: STATIC "+N" overflow — locked, no interactive reveal

    func testManySegmentsOverflowToAStaticPlusN() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Alpha Streaming App", "Bravo Streaming App",
                                   "Charlie Streaming App", "Delta Streaming App",
                                   "Echo Streaming App"])
        XCTAssertTrue(row.test_feedHasOverflow, "a long composite caps visible segments with +N")
        // Never a mid-string ellipsis — a "+N" suffix, not a truncated segment.
        XCTAssertFalse(row.test_feedText?.hasSuffix("…") ?? true)
    }

    func testShortCompositeNeverOverflows() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        XCTAssertFalse(row.test_feedHasOverflow)
    }

    // MARK: Non-bus host — no FEED column at all (mirrors production reality:
    // only the Selected Devices bus rows mount one)

    func testNonBusRowNeverShowsFeedText() {
        let row = DeviceRowView(device: makeDevice())   // default showsBus: false
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        XCTAssertNil(row.test_feedText, "a non-bus host has no free trailing slot to draw into")
    }

    // MARK: Tether-tint + chip (T7, Warm Signal v4.1 CORRECTIONS)

    func testAppSegmentColorUsesTheHostSuppliedTetherTintNotFlatSecondaryLabel() {
        let row = makeBusRow()
        let tint = NSColor(srgbRed: 0.42, green: 0.58, blue: 0.47, alpha: 1)
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"],
                  appTintColors: ["Music": tint])
        XCTAssertEqual(row.test_feedAppSegmentColor(for: "Music"), tint,
                       "T7 rewired this seam to the host-supplied AppTetherColor tint")
        XCTAssertNotEqual(row.test_feedAppSegmentColor(for: "Music"), Tokens.Color.secondaryLabel,
                          "no longer the flat secondaryLabel it was before T7")
    }

    func testAppSegmentColorFallsBackToNeutralTetherWhenUnmapped() {
        let row = makeBusRow()
        XCTAssertEqual(row.test_feedAppSegmentColor(for: "Music"), AppTetherColor.neutralFallback,
                       "an app the host never mapped still reads as a tether tone, not the "
                       + "neutral main-mix secondaryLabel")
    }

    func testAppRedirectSegmentsWearAChipMainMixSegmentDoesNot() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Music", "Safari"],
                  appTintColors: ["Music": .systemGreen, "Safari": .systemTeal])
        XCTAssertEqual(row.test_feedText, "System · Music · Safari")
        XCTAssertEqual(row.test_feedChipCount, 2,
                       "one chip per app segment; the neutral 'System' segment wears none")
    }

    func testAppOnlyRedirectFeedStillWearsItsChip() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, controllable: true, routedAppNames: ["Safari"],
                  appTintColors: ["Safari": .systemTeal])
        XCTAssertEqual(row.test_feedText, "Safari")
        XCTAssertEqual(row.test_feedChipCount, 1)
    }

    func testErrorOverrideFeedNeverWearsAChip() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, controllable: true, routedAppNames: ["Music"],
                  appTintColors: ["Music": .systemGreen])
        XCTAssertEqual(row.test_feedText, "Couldn't connect")
        XCTAssertEqual(row.test_feedChipCount, 0)
    }

    // MARK: VoiceOver — one composed announcement, no double-speaking

    func testAccessibilityLabelSpeaksTheFeedAsATrailingClause() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        let label = row.test_accessibilityLabel ?? ""
        XCTAssertTrue(label.hasSuffix(", feeding System, Music"),
                      "the feed clause trails the rest of the composed announcement")
        XCTAssertEqual(label.components(separatedBy: "feeding").count - 1, 1,
                       "spoken exactly once")
    }

    func testFailedRowNeverSpeaksAFeedClauseSinceTheConnectionClauseAlreadyCoversIt() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, controllable: true, routedAppNames: ["Music"])
        let label = row.test_accessibilityLabel ?? ""
        XCTAssertTrue(label.hasSuffix(", couldn't connect"),
                      "no trailing feed clause — the connection clause already spoke the failure")
        XCTAssertFalse(label.contains("feeding"))
    }

    func testNonBusRowNeverSpeaksAFeedClauseEither() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        XCTAssertFalse((row.test_accessibilityLabel ?? "").contains("feeding"),
                       "a non-bus host has no FEED column, so nothing new to speak")
    }
}
