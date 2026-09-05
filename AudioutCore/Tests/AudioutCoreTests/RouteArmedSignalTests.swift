// SPDX-License-Identifier: GPL-2.0-or-later

import AppKit
import Testing
import AudioutCore
@testable import AudioutSharedUI
@testable import AudioutPopoverUI

/// S2+S3 coverage (Warm Signal v3 §3.3 / §3.5): the **route-armed corner
/// dot**'s normative predicate — walked as a truth table over
/// member × connected × rowMute × masterMute × liveApps — plus the paused
/// test (R3: the dot is pure model state, never RMS), the dot's gold/socket
/// hues and static glow, the arm bloom's gating, the Main Out row's dot, the
/// **mute channel** (engaged pill, ballistic meter drain, MUTED sublabel
/// token with no reflow), the warm meter gradient (ember → gold,
/// NEVER failure red — house rule 8), and the VoiceOver value equivalents
/// shipped with each visual state.
@MainActor
@Suite struct RouteArmedSignalTests {

    private func makeDevice(connectionState: ConnectionState = .connected,
                            isMuted: Bool = false,
                            isAvailable: Bool = true) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
               isAvailable: isAvailable, isMuted: isMuted,
               connectionState: connectionState)
    }

    /// Assert two colors resolve to the same sRGB components (the resolved-
    /// component comparison idiom from `DeviceRowConnectionStateTests`).
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

    // MARK: §3.3 predicate truth table — main-mix branch
    // routeArmed = (member ∧ connected ∧ !rowMute ∧ !masterMute) ∨ liveApps≠∅

    @Test func armedWhenMemberConnectedUnmuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true)
        #expect(row.test_routeArmed, "member ∧ connected ∧ unmuted ∧ master-unmuted ⇒ armed")
    }

    @Test func darkWhenNotMember() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false)
        #expect(!(row.test_routeArmed), "a non-member never arms via the main-mix branch")
    }

    @Test func darkWhenNotConnected() {
        for state: ConnectionState in [.off, .connecting, .reconnecting,
                                       .failed(.init(cause: .notResponding))] {
            let row = DeviceRowView(device: makeDevice(connectionState: state))
            row.apply(makeDevice(connectionState: state), selected: true)
            #expect(!(row.test_routeArmed), "\(state): not yet connected ⇒ dot dark")
        }
    }

    @Test func darkWhenRowMuted() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true)
        #expect(!(row.test_routeArmed), "row mute removes the unmuted condition ⇒ dot dark")
    }

    @Test func darkWhenMasterMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, masterMuted: true)
        #expect(!(row.test_routeArmed), "master mute drains EVERY device dot — no gold lamps on a silent house")
    }

    // MARK: §3.3 predicate — liveApps branch (independent of both mutes)

    @Test func liveAppsArmRegardlessOfMembership() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: ["Spotify"])
        #expect(row.test_routeArmed, "a confirmed live feed lights the dot on an unchecked row")
    }

    @Test func liveAppsArmDespiteMasterMute() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: ["Spotify"], masterMuted: true)
        #expect(row.test_routeArmed, "redirect streams bypass the main-out master — the liveApps branch ignores masterMute")
    }

    @Test func emptyLiveAppsDoNotArmANonMember() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: [])
        #expect(!(row.test_routeArmed))
    }

    // MARK: §3.3 — membership is against the ACTIVE target, not the Selected set

    @Test func groupMemberArmsViaInActiveTargetEvenWhenDeselected() {
        // Group mode: the checked (Selected) set is dormant; a playing group
        // member must still light its dot (resolves the group-mode LED lies).
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, inActiveTarget: true)
        #expect(row.test_routeArmed, "membership is evaluated against the active target")
    }

    @Test func selectedRowOutsideActiveTargetStaysDark() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, inActiveTarget: false)
        #expect(!(row.test_routeArmed), "a checked row outside the active (group) target isn't armed")
    }

    // MARK: R3 — the paused test: the dot is pure model state, NEVER RMS

    @Test func dotIgnoresMeterLevels() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true)
        #expect(row.test_routeArmed)

        row.setLevel(0.9)
        #expect(row.test_routeArmed, "playing: armed (unchanged)")
        row.setLevel(0.0)
        #expect(row.test_routeArmed, "paused/silent: STILL armed — only the meter differs")

        let dark = DeviceRowView(device: makeDevice(), showsMeter: true)
        dark.apply(makeDevice(), selected: false)
        dark.setLevel(0.9)
        #expect(!(dark.test_routeArmed), "RMS can never light a dot the model didn't arm")
    }

    // MARK: Dot rendering — flat gold armed, dark socket at rest

    @Test func armedDotIsGoldWithNoHalo() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true)
        assertSameHue(row.test_dotFillColor, Tokens.Color.gold, "the armed dot is THE gold accent")
        #expect(!(row.test_dotIsBlooming), "no transient on a first render — steady states render settled (spec §6)")
    }

    @Test func unarmedDotIsTheSocket() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false)
        assertSameHue(row.test_dotFillColor, Tokens.Color.socket,
                      "not armed renders the dark/empty socket, not an absence")
    }

    // MARK: Arm bloom — only on a transition INTO armed while visible

    @Test func bloomFiresOnArmTransitionPerReduceMotion() {
        let row = DeviceRowView(device: makeDevice())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.apply(makeDevice(), selected: false)   // settled, dark
        #expect(!(row.test_dotIsBlooming))

        row.apply(makeDevice(), selected: true)    // transition INTO armed, on screen
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(row.test_dotIsBlooming == !reduceMotion, "the ≤450ms ember→gold bloom fires on arm iff Reduce Motion is off (instant otherwise)")
        #expect(row.test_routeArmed, "model state is settled gold regardless of the bloom")
    }

    @Test func noBloomOnFirstApplyEvenWhenArmed() {
        let row = DeviceRowView(device: makeDevice())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.apply(makeDevice(), selected: true)
        // The row's init already ran one internal apply, so this is not the
        // dot's literal first application — but a freshly-built row must not
        // bloom on the popover-open render either way; assert the settled
        // armed state and that a repeated same-state apply never re-blooms.
        row.apply(makeDevice(), selected: true)
        row.apply(makeDevice(), selected: true)
        #expect(row.test_routeArmed)
    }

    // MARK: S3 — engaged mute fill (drawing only)

    @Test func mutePillEngagesViaApply() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(row.test_isMutePillEngaged, "muted: the filled square with white marks")
    }

    @Test func mutePillDisengagesOnUnmute() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(row.test_isMutePillEngaged)

        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        #expect(!(row.test_isMutePillEngaged), "unmuting removes the fill")
        #expect(row.test_muteDrawsRestSymbol)
    }

    @Test func mutePillEngagesInstantlyOnLiveClick() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true)
        #expect(!(row.test_isMutePillEngaged))

        row.test_toggleMute(true)
        #expect(row.test_isMutePillEngaged, "the live click lands the fill without waiting for apply")

        row.test_toggleMute(false)
        #expect(!(row.test_isMutePillEngaged))
    }

    // MARK: S3 — muting DRAINS the meter (ballistics), other causes hard-reset

    @Test func mutingDrainsTheMeterInsteadOfSnapping() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_settleMeterDisplayed(0.8)
        #expect(abs(row.test_meterDisplayed - 0.8) <= 0.001)

        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(row.test_meterTarget == 0, "mute zeroes the ballistics TARGET")
        #expect(row.test_meterLevel() == 0)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            #expect(abs(row.test_meterDisplayed - 0) <= 0.001, "Reduce Motion: an instant state swap, no drain animation")
        } else {
            #expect(row.test_meterDisplayed > 0, "the bar DRAINS through the existing decay path, not an instant snap")
        }
    }

    @Test func masterMuteDrainsTheMeterToo() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_settleMeterDisplayed(0.6)

        row.apply(makeDevice(), selected: true, controllable: true, masterMuted: true)
        #expect(row.test_meterTarget == 0)
        #expect(!(row.test_routeArmed), "master mute darkens the dot alongside the drain")
    }

    @Test func deselectingHardResetsTheMeter() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_settleMeterDisplayed(0.8)

        row.apply(makeDevice(), selected: false)
        #expect(abs(row.test_meterDisplayed - 0) <= 0.001, "a non-mute cause (deselect) keeps the hard reset — no lingering bar")
    }

    @Test func levelPushWhileMutedIsCoercedToZero() {
        let row = DeviceRowView(device: makeDevice(isMuted: true), showsMeter: true)
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        row.setLevel(0.7)
        #expect(row.test_meterLevel() == 0, "a straggling RMS push can never refill a drained (muted) meter")
        #expect(row.test_meterTarget == 0)
    }

    // MARK: S3 — the MUTED sublabel token (§3.5: leading token, never a reflow)

    @Test func mutedRowWithFeedsGainsLeadingMutedToken() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(row.test_statusText == "Muted · System", "the MUTED token leads an EXISTING feed sublabel")
    }

    @Test func mutedRedirectTargetPrependsTokenToFeedList() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: false, controllable: true,
                  routedAppNames: ["Spotify"])
        #expect(row.test_statusText == "Muted · Spotify")
    }

    @Test func mutedRowWithoutFeedsStaysSingleLine() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: false)
        #expect(row.test_statusText == nil, "no standalone MUTED line — a single-line row never grows (R7 no-reflow)")
    }

    @Test func mutedRowKeepsItsTokenUnderMasterMute() {
        // A muted row always says so (owner's call, 2026-08-23) — master mute
        // is realized by muting every member, and each member now labels its
        // own mute instead of deferring to the Main Out pill (the old matrix
        // §3.6 suppression made the label vanish when the muted row was the
        // only member).
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true, masterMuted: true)
        #expect(row.test_statusText == "Muted · System", "a muted row says Muted even under MASTER mute")
    }

    @Test func unmutingRestoresThePlainSublabel() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(row.test_statusText == "Muted · System")

        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        #expect(row.test_statusText == "System", "unmute restores the plain feed line")
    }

    @Test func failureOutranksTheMutedToken() {
        let failed = makeDevice(connectionState: .failed(.init(cause: .notResponding)), isMuted: true)
        let row = DeviceRowView(device: failed)
        row.apply(failed, selected: true, controllable: true)
        #expect(row.test_statusText == "Couldn't connect", "sublabel precedence: failure > MUTED token > feeds (§3.1)")
    }

    // MARK: C3 — warm meter gradient (ember → gold; NEVER failure red)

    @Test func meterGradientIsEmberToGold() {
        let meter = LevelMeterView()
        let colors = meter.test_gradientColors
        #expect(colors.count == 2)
        assertSameHue(colors.first, Tokens.Color.ember, "bottom of the ramp is ember")
        assertSameHue(colors.last, Tokens.Color.gold, "gold is the CEILING")
    }

    @Test func failureRedNeverAppearsInAMeter() {
        // House rule 8: `failure` is failure-exclusive; a loud party can never
        // impersonate a failure. Compare against the failure token resolved in
        // the same (test) appearance context.
        let meter = LevelMeterView()
        guard let failure = Tokens.Color.failure.usingColorSpace(.sRGB) else {
            Issue.record("failure token did not resolve")
            return
        }
        for color in meter.test_gradientColors {
            guard let c = color.usingColorSpace(.sRGB) else { continue }
            let distance = abs(c.redComponent - failure.redComponent)
                + abs(c.greenComponent - failure.greenComponent)
                + abs(c.blueComponent - failure.blueComponent)
            #expect(distance > 0.1, "no meter stop may be the failure red (R8)")
        }
    }

    // MARK: S2/S3 — VoiceOver value equivalents (shipped with the drawing)

    @Test func accessibilityValueSaysArmedForMainMixRoute() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true)
        #expect(row.test_accessibilityValue == "armed")
    }

    @Test func accessibilityValueSaysPlayingHereForLiveFeed() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: ["Spotify"])
        #expect(row.test_accessibilityValue == "playing here", "a confirmed live feed speaks 'playing here' (spec copy)")
    }

    @Test func accessibilityValueSaysMutedWhenRowMuted() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        #expect(row.test_accessibilityValue == "muted")
    }

    @Test func accessibilityValueComposesMutedAndPlayingHere() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: false, controllable: true,
                  liveAppNames: ["Spotify"])
        #expect(row.test_accessibilityValue == "muted, playing here")
    }

    @Test func accessibilityValueEmptyAtRest() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        row.apply(makeDevice(connectionState: .off), selected: false)
        #expect(row.test_accessibilityValue == "", "no state, no clause")
    }

    @Test func muteButtonAXStillReadsCorrectly() {
        // Task item 7: the existing mute AX must survive the new pill drawing.
        let muted = makeDevice(isMuted: true)
        let row = DeviceRowView(device: muted)
        row.apply(muted, selected: true, controllable: true)
        #expect(row.test_membershipAXLabel != nil)   // row AX intact
        // The mute button's label flips with the model, exactly as before.
        // (Reached through the row's accessibility children — the button is a
        // real NSButton; its label was set in apply.)
        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        #expect(row.test_accessibilityValue == "armed", "unmuted+selected+connected reads armed again")
    }

    // MARK: Main Out row — dot, pill, drain, AX

    private func mainOutOptions() -> [MainOutRowView.Option] {
        [.init(title: "Selected Devices", target: .selectedDevices)]
    }

    @Test func mainOutArmedWhenConnectedAndUnmuted() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: false, connectionState: .connected)
        #expect(row.test_routeArmed)
        assertSameHue(row.test_dotFillColor, Tokens.Color.gold, "Main Out's armed dot is gold")
        #expect(row.test_accessibilityValue == "armed")
    }

    @Test func mainOutDarkWhenMasterMuted() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: true, connectionState: .connected)
        #expect(!(row.test_routeArmed), "master mute darkens the Main Out dot")
        #expect(row.test_isMutePillEngaged, "the master mute pill engages")
        #expect(row.test_accessibilityValue == "muted")
    }

    @Test func mainOutDarkWhenNotConnected() {
        for state: ConnectionState in [.off, .connecting] {
            let row = MainOutRowView()
            row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                      isMuted: false, connectionState: state)
            #expect(!(row.test_routeArmed), "\(state): no connected member ⇒ Main Out dot dark")
        }
    }

    @Test func mainOutMasterMuteDrainsItsMeter() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: false, connectionState: .connected)
        row.test_settleMeterDisplayed(0.7)

        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: true, connectionState: .connected)
        #expect(row.test_meterTarget == 0, "master mute zeroes the master meter's target (drain)")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            #expect(abs(row.test_meterDisplayed - 0) <= 0.001)
        } else {
            #expect(row.test_meterDisplayed > 0, "drains with ballistics, not a snap")
        }
        // And a straggling push while muted is coerced to zero.
        row.setLevel(0.9)
        #expect(row.test_meterTarget == 0)
    }

    @Test func mainOutUnmuteRestoresPillAndArming() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: true, connectionState: .connected)
        #expect(row.test_isMutePillEngaged)

        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: false, connectionState: .connected)
        #expect(!(row.test_isMutePillEngaged))
        #expect(row.test_routeArmed)
    }
}
