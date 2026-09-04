// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import AppKit
import AudioutCore
@testable import AudioutSharedUI

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
                      showsMeter: true, showsBus: true)
    }

    // MARK: Multi-source composite — never collapses to one reason

    @Test func manualMemberAloneShowsSystem() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(row.test_feedText == "System")
        #expect(!row.test_feedErrorPillHasGlyph, "an ordinary member pill carries no error glyph")
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

    /// A group route paints exactly like a direct one — the speaker carries the
    /// app either way — but VoiceOver says which group brought it there, the
    /// one place that difference is stated.
    @Test func aGroupRoutedAppReadsAsThroughItsGroup() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Music"], appRouteGroupNames: ["Music": "Downstairs"])

        #expect(row.test_feedText == "System · Music", "the pills are unchanged")
        #expect(row.test_accessibilityLabel?.contains("playing System, Music, through Downstairs") == true)
    }

    @Test func aDirectlyRoutedAppNamesNoGroup() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(row.test_accessibilityLabel?.contains("playing System, Music") == true)
        #expect(row.test_accessibilityLabel?.contains("through") != true)
    }

    @Test func manualMemberPlusTwoApps() {
        // Without the colour chips each pill carries text plus its own
        // padding only, so all three values fit: three bare pills measure
        // ~130 pt of the 136 pt `feedColumnWidth` budget. The chips were what
        // used to tip this into the STATIC "+N" overflow.
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true,
                  routedAppNames: ["Music", "Safari"])
        #expect(row.test_feedText == "System · Music · Safari")
        #expect(!(row.test_feedHasOverflow))
        // The tooltip is uncapped (VoiceOver/hover have no viewport to
        // overflow) — every name, no "+N".
        #expect(row.test_feedTooltip == "Playing System, Music, Safari")
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
        #expect(row.test_feedText == "Didn't respond", "failure overrides the composite entirely — never both — with the failure's own headline")
        #expect(row.test_feedIsErrorColored)
        #expect(row.test_statusText == nil, "the sublabel carries no words for a failed bus row")
        #expect(row.test_feedTooltip == nil, "a failed row's tooltip carries no feed names")
        #expect(row.test_feedErrorPillHasGlyph, "an error pill reads by shape, not colour alone (P2-6)")
    }

    @Test func unavailableOverridesTheFeed() {
        let row = makeBusRow()
        row.apply(makeDevice(isAvailable: false), selected: true, routedAppNames: ["Music"])
        #expect(row.test_feedText == "Unavailable")
        #expect(row.test_feedIsErrorColored)
        #expect(row.test_feedErrorPillHasGlyph)
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
        #expect(row.test_statusText == "Muted", "…it lives on the sublabel/mute-pill instead")
    }

    // MARK: No protocol badge — the FEED column shows feeds, never attributes

    /// The retired "Older AirPlay" micro-tag. It read `supportsAirPlay2`,
    /// which is false for Bluetooth, Cast AND the Mac's own row as well as a
    /// genuine AP1 receiver — so it labelled a Chromecast as AirPlay. Alec
    /// dropped it outright rather than narrowing it to real AP1 receivers: the
    /// column carries what a device is PLAYING, and a protocol attribute was
    /// never that.
    @Test func noDeviceGetsAProtocolTagWhateverItsAirPlay2Flag() {
        for supportsAirPlay2 in [true, false] {
            let row = makeBusRow()
            row.apply(makeDevice(supportsAirPlay2: supportsAirPlay2), selected: true, controllable: true)
            #expect(row.test_feedText == "System")
            #expect(row.test_feedTooltip == "Playing System",
                    "the tooltip keeps the feed line and loses the protocol consequence line")
        }
    }

    /// The kinds that shared the flag without being AirPlay at all — the Mac's
    /// own row was the visible casualty, its narrow feed slot truncating
    /// "Older AirPlay System" to a bare "Older".
    @Test func nonAirPlayKindsShowTheirFeedAndNothingElse() {
        let kinds: [(Device.Kind, Bool)] = [(.localMac, true), (.bluetooth, false), (.cast, false)]
        for (kind, isLocal) in kinds {
            let device = Device(id: "dev-\(kind)", name: "Test Speaker", kind: kind,
                                isAvailable: true, supportsAirPlay2: false,
                                isLocalDevice: isLocal, connectionState: .connected)
            let row = makeBusRow(device: device)
            row.apply(device, selected: true, controllable: true)
            #expect(row.test_feedText == "System", "\(kind) shows its feed, unbadged")
            #expect(!(row.test_feedTooltip ?? "").contains("Older AirPlay"))
        }
    }

    @Test func failedDeviceShowsOnlyTheError() {
        // The error override takes the WHOLE column.
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .vanished)), supportsAirPlay2: false),
                  selected: true, controllable: true)
        #expect(row.test_feedText == "Not on the network")
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

    // MARK: Pill tint (D7)

    @Test func mainMixPillIsGoldTextWhileSoundingAndLabel2Otherwise() {
        let live = makeBusRow()
        let device = makeDevice(connectionState: .connected)
        live.apply(device, selected: true, controllable: true)
        assertSameHue(live.test_feedNeutralColor, Tokens.Color.goldText,
                      "the main-mix pill is goldText while the main mix sounds here")

        let idle = makeBusRow(device: makeDevice(connectionState: .off))
        idle.apply(makeDevice(connectionState: .off), selected: true, controllable: true)
        assertSameHue(idle.test_feedNeutralColor, Tokens.Color.label2,
                      "a silent row's main-mix pill is the chrome label2")
    }

    /// Assert two colors resolve to the same sRGB components — `goldText` is a
    /// computed `static var`, so `==` never holds on it.
    private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            Issue.record("nil color: \(message)", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(a.redComponent - b.redComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.greenComponent - b.greenComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
        #expect(abs(a.blueComponent - b.blueComponent) < 0.01, "\(message)", sourceLocation: sourceLocation)
    }

    // MARK: VoiceOver — one composed announcement, no double-speaking

    @Test func accessibilityLabelSpeaksTheFeedAsATrailingClause() {
        let row = makeBusRow()
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        let label = row.test_accessibilityLabel ?? ""
        #expect(label.hasSuffix(", playing System, Music"), "the feed clause trails the rest of the composed announcement")
        #expect(label.components(separatedBy: "playing").count - 1 == 1, "spoken exactly once")
    }

    @Test func failedRowNeverSpeaksAFeedClauseSinceTheConnectionClauseAlreadyCoversIt() {
        let row = makeBusRow()
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))),
                  selected: true, controllable: true, routedAppNames: ["Music"])
        let label = row.test_accessibilityLabel ?? ""
        #expect(label.hasSuffix(", couldn't connect"), "no trailing feed clause — the connection clause already spoke the failure")
        #expect(!(label.contains("playing")))
    }

    @Test func nonBusRowNeverSpeaksAFeedClauseEither() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true, routedAppNames: ["Music"])
        #expect(!((row.test_accessibilityLabel ?? "").contains("playing")), "a non-bus host has no FEED column, so nothing new to speak")
    }
}
