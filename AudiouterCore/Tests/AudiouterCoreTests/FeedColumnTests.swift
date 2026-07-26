// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
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
@Suite final class FeedColumnTests: IsolatedSuite {

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

    @Test func manualMemberAloneShowsSystem() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_feedText == "System")
    }

    @Test func groupMemberShowsTheGroupNameInsteadOfSystem() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, inActiveTarget: true,
                  mainOutTargetsGroupName: "Downstairs")
        #expect(row.test_feedText == "Downstairs", "the neutral segment's WORD carries manual-vs-group, no extra glyph")
    }

    @Test func appRedirectAloneWithNoMainMixMembership() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, controllable: true, routedAppNames: ["Safari"])
        #expect(row.test_feedText == "Safari", "app-only: no main-mix segment at all")
    }

    @Test func manualMemberPlusOneApp() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(row.test_feedText == "System · Music")
    }

    @Test func groupMemberPlusOneApp() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, routedAppNames: ["Music"],
                  inActiveTarget: true, mainOutTargetsGroupName: "Downstairs")
        #expect(row.test_feedText == "Downstairs · Music")
    }

    @Test func manualMemberPlusTwoApps() {
        // Pre-pill this fit at the same `feedColumnWidth` as one packed
        // string; each value now carries its own bordered-pill chrome
        // (padding + border + inter-pill gap), so three short values plus
        // two chips no longer fit in the same reserved width and the
        // STATIC "+N" overflow correctly kicks in one segment sooner. The
        // "never collapses to one reason" behavior is unchanged — it just
        // shows 2 pills + "+1" instead of 3 pills at this exact width; see
        // `testManualMemberPlusOneApp`/`testGroupMemberPlusOneApp` for the
        // still-uncapped two-pill case.
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Music", "Safari"])
        #expect(row.test_feedText == "System · Music · +1")
        #expect(row.test_feedHasOverflow)
    }

    @Test func neitherMainMixNorAppsShowsNothing() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false)
        #expect(row.test_feedText == nil)
    }

    @Test func liveAppNamesTakePrecedenceOverRoutedAppNamesInFeed() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, controllable: true,
                  routedAppNames: ["Spotify"], liveAppNames: ["Music"])
        #expect(row.test_feedText == "Music", "the FEED column mirrors the same T9 live-over-intent precedence")
    }

    // MARK: Error overrides the feed (failure-red words)

    @Test func failedOverridesTheFeedWithCouldntConnect() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(row.test_feedText == "Couldn't connect", "failure overrides the composite entirely — never both")
        #expect(row.test_feedIsErrorColored)
        #expect(row.test_statusText == nil, "the sublabel carries no words for a failed bus row")
    }

    @Test func unavailableOverridesTheFeed() {
        let row = makeBusRow()
        row.apply(makeDevice(isAvailable: false), selected: true, routedAppNames: ["Music"])
        #expect(row.test_feedText == "Unavailable")
        #expect(row.test_feedIsErrorColored)
    }

    // MARK: Connecting/reconnecting/muted are NOT shown in the FEED column

    @Test func connectingShowsTheMultiSourceCompositeNotAConnectingWord() {
        // The halo ring owns transient connection state; the muted-unconnected
        // rule greys the whole row, but the FEED column itself still composes
        // normally (no "connecting…" word duplicated here).
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .connecting), selected: true, controllable: true)
        #expect(row.test_feedText == "System")
        #expect(!(row.test_feedIsErrorColored))
    }

    @Test func mutedRowsFeedStillShowsTheCompositeMuteLivesOnTheControl() {
        var muted = makeDevice()
        muted.isMuted = true
        let row = makeBusRow()
        row.apply(muted, selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(row.test_feedText == "System · Music", "muted is not represented in the FEED column at all")
        #expect(row.test_statusText == "MUTED", "…it lives on the sublabel/mute-pill instead")
    }

    // MARK: AP1 micro-tag — the one true exception, AP2 never badged

    @Test func aP1DeviceGetsTheMicroTagPrefix() {
        let row = makeBusRow()
        row.apply(makeDevice(supportsAirPlay2: false), selected: true, controllable: true)
        #expect(row.test_feedHasAP1Tag)
        #expect(row.test_feedText == "AP1 System")
    }

    @Test func aP2DeviceNeverGetsATag() {
        let row = makeBusRow()
        row.apply(makeDevice(supportsAirPlay2: true), selected: true, controllable: true)
        #expect(!(row.test_feedHasAP1Tag))
    }

    @Test func failedAP1DeviceShowsTheErrorWithNoTag() {
        // The error override takes the WHOLE column — no tag mixed in.
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .vanished)), supportsAirPlay2: false),
                  selected: true, controllable: true)
        #expect(row.test_feedText == "Couldn't connect")
        #expect(!(row.test_feedHasAP1Tag))
    }

    // MARK: STATIC "+N" overflow — locked, no interactive reveal

    @Test func manySegmentsOverflowToAStaticPlusN() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Alpha Streaming App", "Bravo Streaming App",
                                   "Charlie Streaming App", "Delta Streaming App",
                                   "Echo Streaming App"])
        #expect(row.test_feedHasOverflow, "a long composite caps visible segments with +N")
        // Never a mid-string ellipsis — a "+N" suffix, not a truncated segment.
        #expect(!(row.test_feedText?.hasSuffix("…") ?? true))
    }

    @Test func shortCompositeNeverOverflows() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(!(row.test_feedHasOverflow))
    }

    // MARK: Non-bus host — no FEED column at all (mirrors production reality:
    // only the Selected Devices bus rows mount one)

    @Test func nonBusRowNeverShowsFeedText() {
        let row = DeviceRowView(device: makeDevice())   // default showsBus: false
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(row.test_feedText == nil, "a non-bus host has no free trailing slot to draw into")
    }

    // MARK: Tether-tint + chip (T7, Warm Signal v4.1 CORRECTIONS)

    @Test func appSegmentColorUsesTheHostSuppliedTetherTintNotFlatSecondaryLabel() {
        let row = makeBusRow()
        let tint = NSColor(srgbRed: 0.42, green: 0.58, blue: 0.47, alpha: 1)
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"],
                  appTintColors: ["Music": tint])
        #expect(row.test_feedAppSegmentColor(for: "Music") == tint, "T7 rewired this seam to the host-supplied AppTetherColor tint")
        #expect(row.test_feedAppSegmentColor(for: "Music") != Tokens.Color.secondaryLabel, "no longer the flat secondaryLabel it was before T7")
    }

    @Test func appSegmentColorFallsBackToNeutralTetherWhenUnmapped() {
        let row = makeBusRow()
        #expect(row.test_feedAppSegmentColor(for: "Music") == AppTetherColor.neutralFallback,
                "an app the host never mapped still reads as a tether tone, not the neutral main-mix secondaryLabel")
    }

    @Test func appRedirectSegmentsWearAChipMainMixSegmentDoesNot() {
        // Three pills' worth of bordered chrome (System + 2 app pills, 2 of
        // them chipped) no longer fits `feedColumnWidth` at this exact width
        // — see the note on `testManualMemberPlusTwoApps` — so Safari's pill
        // overflows to the static "+1" here too. The chip-per-segment rule
        // this test exists to pin is still exercised on the VISIBLE pills:
        // "System" (no chip) and "Music" (chip); `testAppOnlyRedirectFeedStillWearsItsChip`
        // separately covers a chip surviving as the SOLE visible app pill.
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Music", "Safari"],
                  appTintColors: ["Music": .systemGreen, "Safari": .systemTeal])
        #expect(row.test_feedText == "System · Music · +1")
        #expect(row.test_feedChipCount == 1, "one chip per VISIBLE app segment; the neutral 'System' segment wears none")
    }

    @Test func appOnlyRedirectFeedStillWearsItsChip() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: false, controllable: true, routedAppNames: ["Safari"],
                  appTintColors: ["Safari": .systemTeal])
        #expect(row.test_feedText == "Safari")
        #expect(row.test_feedChipCount == 1)
    }

    @Test func errorOverrideFeedNeverWearsAChip() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, controllable: true, routedAppNames: ["Music"],
                  appTintColors: ["Music": .systemGreen])
        #expect(row.test_feedText == "Couldn't connect")
        #expect(row.test_feedChipCount == 0)
    }

    // MARK: VoiceOver — one composed announcement, no double-speaking

    @Test func accessibilityLabelSpeaksTheFeedAsATrailingClause() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        let label = row.test_accessibilityLabel ?? ""
        #expect(label.hasSuffix(", feeding System, Music"), "the feed clause trails the rest of the composed announcement")
        #expect(label.components(separatedBy: "feeding").count - 1 == 1, "spoken exactly once")
    }

    @Test func failedRowNeverSpeaksAFeedClauseSinceTheConnectionClauseAlreadyCoversIt() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, controllable: true, routedAppNames: ["Music"])
        let label = row.test_accessibilityLabel ?? ""
        #expect(label.hasSuffix(", couldn't connect"), "no trailing feed clause — the connection clause already spoke the failure")
        #expect(!(label.contains("feeding")))
    }

    @Test func nonBusRowNeverSpeaksAFeedClauseEither() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(!((row.test_accessibilityLabel ?? "").contains("feeding")), "a non-bus host has no FEED column, so nothing new to speak")
    }
}
