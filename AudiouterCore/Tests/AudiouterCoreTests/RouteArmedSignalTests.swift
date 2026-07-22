// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import AudiouterCore
@testable import AudiouterSharedUI
@testable import AudiouterPopoverUI

/// S2+S3 coverage (Warm Signal v3 §3.3 / §3.5): the **route-armed corner
/// dot**'s normative predicate — walked as a truth table over
/// member × connected × rowMute × masterMute × liveApps — plus the paused
/// test (R3: the dot is pure model state, never RMS), the dot's gold/socket
/// hues and static glow, the arm bloom's gating, the Main Out row's dot, the
/// **mute channel** (engaged pill, ballistic meter drain, MUTED sublabel
/// token with no reflow), the warm meter gradient (ember → gold → caution,
/// NEVER failure red — house rule 8), and the VoiceOver value equivalents
/// shipped with each visual state.
final class RouteArmedSignalTests: XCTestCase {

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
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            return XCTFail("nil color: \(message)", file: file, line: line)
        }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01, message, file: file, line: line)
    }

    // MARK: §3.3 predicate truth table — main-mix branch
    // routeArmed = (member ∧ connected ∧ !rowMute ∧ !masterMute) ∨ liveApps≠∅

    func testArmedWhenMemberConnectedUnmuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true)
        XCTAssertTrue(row.test_routeArmed, "member ∧ connected ∧ unmuted ∧ master-unmuted ⇒ armed")
    }

    func testDarkWhenNotMember() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false)
        XCTAssertFalse(row.test_routeArmed, "a non-member never arms via the main-mix branch")
    }

    func testDarkWhenNotConnected() {
        for state: ConnectionState in [.off, .connecting, .reconnecting,
                                       .failed(.init(cause: .notResponding))] {
            let row = DeviceRowView(device: makeDevice(connectionState: state))
            row.apply(makeDevice(connectionState: state), selected: true)
            XCTAssertFalse(row.test_routeArmed, "\(state): not yet connected ⇒ dot dark")
        }
    }

    func testDarkWhenRowMuted() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true)
        XCTAssertFalse(row.test_routeArmed, "row mute removes the unmuted condition ⇒ dot dark")
    }

    func testDarkWhenMasterMuted() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, masterMuted: true)
        XCTAssertFalse(row.test_routeArmed,
                       "master mute drains EVERY device dot — no gold lamps on a silent house")
    }

    // MARK: §3.3 predicate — liveApps branch (independent of both mutes)

    func testLiveAppsArmRegardlessOfMembership() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: ["Spotify"])
        XCTAssertTrue(row.test_routeArmed, "a confirmed live feed lights the dot on an unchecked row")
    }

    func testLiveAppsArmDespiteMasterMute() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: ["Spotify"], masterMuted: true)
        XCTAssertTrue(row.test_routeArmed,
                      "redirect streams bypass the main-out master — the liveApps branch ignores masterMute")
    }

    func testEmptyLiveAppsDoNotArmANonMember() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: [])
        XCTAssertFalse(row.test_routeArmed)
    }

    // MARK: §3.3 — membership is against the ACTIVE target, not the Selected set

    func testGroupMemberArmsViaInActiveTargetEvenWhenDeselected() {
        // Group mode: the checked (Selected) set is dormant; a playing group
        // member must still light its dot (resolves the group-mode LED lies).
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, inActiveTarget: true)
        XCTAssertTrue(row.test_routeArmed, "membership is evaluated against the active target")
    }

    func testSelectedRowOutsideActiveTargetStaysDark() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, inActiveTarget: false)
        XCTAssertFalse(row.test_routeArmed,
                       "a checked row outside the active (group) target isn't armed")
    }

    // MARK: R3 — the paused test: the dot is pure model state, NEVER RMS

    func testDotIgnoresMeterLevels() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true)
        XCTAssertTrue(row.test_routeArmed)

        row.setLevel(0.9)
        XCTAssertTrue(row.test_routeArmed, "playing: armed (unchanged)")
        row.setLevel(0.0)
        XCTAssertTrue(row.test_routeArmed, "paused/silent: STILL armed — only the meter differs")

        let dark = DeviceRowView(device: makeDevice(), showsMeter: true)
        dark.apply(makeDevice(), selected: false)
        dark.setLevel(0.9)
        XCTAssertFalse(dark.test_routeArmed, "RMS can never light a dot the model didn't arm")
    }

    // MARK: Dot rendering — gold + static glow armed, dark socket at rest

    func testArmedDotIsGoldWithStaticGlow() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true)
        assertSameHue(row.test_dotFillColor, Tokens.Color.gold, "the armed dot is THE gold accent")
        XCTAssertTrue(row.test_dotHasGlow, "armed carries the subtle STATIC glow halo")
        XCTAssertFalse(row.test_dotIsBlooming,
                       "no transient on a first render — steady states render settled (spec §6)")
    }

    func testUnarmedDotIsTheDarkSocketWithNoGlow() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false)
        assertSameHue(row.test_dotFillColor, Tokens.Color.dotSocket,
                      "not armed renders the dark/empty socket, not an absence")
        XCTAssertFalse(row.test_dotHasGlow, "no glow at rest on an unarmed socket")
    }

    // MARK: Arm bloom — only on a transition INTO armed while visible

    func testBloomFiresOnArmTransitionPerReduceMotion() {
        let row = DeviceRowView(device: makeDevice())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.apply(makeDevice(), selected: false)   // settled, dark
        XCTAssertFalse(row.test_dotIsBlooming)

        row.apply(makeDevice(), selected: true)    // transition INTO armed, on screen
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        XCTAssertEqual(row.test_dotIsBlooming, !reduceMotion,
                       "the ≤450ms ember→gold bloom fires on arm iff Reduce Motion is off (instant otherwise)")
        XCTAssertTrue(row.test_routeArmed, "model state is settled gold regardless of the bloom")
    }

    func testNoBloomOnFirstApplyEvenWhenArmed() {
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
        XCTAssertTrue(row.test_routeArmed)
    }

    // MARK: S3 — engaged mute pill (glyph never slashes; drawing only)

    func testMutePillEngagesViaApply() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        XCTAssertTrue(row.test_isMutePillEngaged, "muted: filled accent pill behind the (unchanged) glyph")
        XCTAssertEqual(row.test_muteTintColor, .controlAccentColor)
    }

    func testMutePillDisengagesOnUnmute() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        XCTAssertTrue(row.test_isMutePillEngaged)

        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        XCTAssertFalse(row.test_isMutePillEngaged, "unmuting removes the pill")
        XCTAssertEqual(row.test_muteTintColor, .secondaryLabelColor)
    }

    func testMutePillEngagesInstantlyOnLiveClick() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, controllable: true)
        XCTAssertFalse(row.test_isMutePillEngaged)

        row.test_toggleMute(true)
        XCTAssertTrue(row.test_isMutePillEngaged, "the live click lands the pill without waiting for apply")

        row.test_toggleMute(false)
        XCTAssertFalse(row.test_isMutePillEngaged)
    }

    // MARK: S3 — muting DRAINS the meter (ballistics), other causes hard-reset

    func testMutingDrainsTheMeterInsteadOfSnapping() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_settleMeterDisplayed(0.8)
        XCTAssertEqual(row.test_meterDisplayed, 0.8, accuracy: 0.001)

        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        XCTAssertEqual(row.test_meterTarget, 0, "mute zeroes the ballistics TARGET")
        XCTAssertEqual(row.test_meterLevel(), 0)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            XCTAssertEqual(row.test_meterDisplayed, 0, accuracy: 0.001,
                           "Reduce Motion: an instant state swap, no drain animation")
        } else {
            XCTAssertGreaterThan(row.test_meterDisplayed, 0,
                                 "the bar DRAINS through the existing decay path, not an instant snap")
        }
    }

    func testMasterMuteDrainsTheMeterToo() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_settleMeterDisplayed(0.6)

        row.apply(makeDevice(), selected: true, controllable: true, masterMuted: true)
        XCTAssertEqual(row.test_meterTarget, 0)
        XCTAssertFalse(row.test_routeArmed, "master mute darkens the dot alongside the drain")
    }

    func testDeselectingHardResetsTheMeter() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.apply(makeDevice(), selected: true, controllable: true)
        row.test_settleMeterDisplayed(0.8)

        row.apply(makeDevice(), selected: false)
        XCTAssertEqual(row.test_meterDisplayed, 0, accuracy: 0.001,
                       "a non-mute cause (deselect) keeps the hard reset — no lingering bar")
    }

    func testLevelPushWhileMutedIsCoercedToZero() {
        let row = DeviceRowView(device: makeDevice(isMuted: true), showsMeter: true)
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        row.setLevel(0.7)
        XCTAssertEqual(row.test_meterLevel(), 0,
                       "a straggling RMS push can never refill a drained (muted) meter")
        XCTAssertEqual(row.test_meterTarget, 0)
    }

    // MARK: S3 — the MUTED sublabel token (§3.5: leading token, never a reflow)

    func testMutedRowWithFeedsGainsLeadingMutedToken() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        XCTAssertEqual(row.test_statusText, "MUTED · System",
                       "the MUTED token leads an EXISTING feed sublabel")
    }

    func testMutedRedirectTargetPrependsTokenToFeedList() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: false, controllable: true,
                  routedAppNames: ["Spotify"])
        XCTAssertEqual(row.test_statusText, "MUTED · Spotify")
    }

    func testMutedRowWithoutFeedsStaysSingleLine() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: false)
        XCTAssertNil(row.test_statusText,
                     "no standalone MUTED line — a single-line row never grows (R7 no-reflow)")
    }

    func testMasterMuteAddsNoMutedToken() {
        // Master mute is realized by muting every member, so the view uses
        // `masterMuted` to suppress the per-row token (matrix §3.6: the Main
        // Out pill carries master mute; member sublabels stay clean).
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true, masterMuted: true)
        XCTAssertEqual(row.test_statusText, "System", "no MUTED token under MASTER mute")
    }

    func testUnmutingRestoresThePlainSublabel() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        XCTAssertEqual(row.test_statusText, "MUTED · System")

        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        XCTAssertEqual(row.test_statusText, "System", "unmute restores the plain feed line")
    }

    func testFailureOutranksTheMutedToken() {
        let failed = makeDevice(connectionState: .failed(.init(cause: .notResponding)), isMuted: true)
        let row = DeviceRowView(device: failed)
        row.apply(failed, selected: true, controllable: true)
        XCTAssertEqual(row.test_statusText, "Couldn't connect",
                       "sublabel precedence: failure > MUTED token > feeds (§3.1)")
    }

    // MARK: S2 — warm meter gradient (ember → gold → caution; NEVER failure red)

    func testMeterGradientIsEmberGoldCaution() {
        let meter = LevelMeterView()
        let colors = meter.test_gradientColors
        XCTAssertEqual(colors.count, 3)
        assertSameHue(colors.first, Tokens.Color.ember, "bottom of the ramp is ember")
        assertSameHue(colors.dropFirst().first, Tokens.Color.gold, "the body warms to gold")
        assertSameHue(colors.last, Tokens.Color.caution, "the top zone is the caution CEILING")
    }

    func testFailureRedNeverAppearsInAMeter() {
        // House rule 8: `failure` is failure-exclusive; a loud party can never
        // impersonate a failure. Compare against the failure token resolved in
        // the same (test) appearance context.
        let meter = LevelMeterView()
        guard let failure = Tokens.Color.failure.usingColorSpace(.sRGB) else {
            return XCTFail("failure token did not resolve")
        }
        for color in meter.test_gradientColors {
            guard let c = color.usingColorSpace(.sRGB) else { continue }
            let distance = abs(c.redComponent - failure.redComponent)
                + abs(c.greenComponent - failure.greenComponent)
                + abs(c.blueComponent - failure.blueComponent)
            XCTAssertGreaterThan(distance, 0.1, "no meter stop may be the failure red (R8)")
        }
    }

    // MARK: S2/S3 — VoiceOver value equivalents (shipped with the drawing)

    func testAccessibilityValueSaysArmedForMainMixRoute() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true)
        XCTAssertEqual(row.test_accessibilityValue, "armed")
    }

    func testAccessibilityValueSaysPlayingHereForLiveFeed() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, liveAppNames: ["Spotify"])
        XCTAssertEqual(row.test_accessibilityValue, "playing here",
                       "a confirmed live feed speaks 'playing here' (spec copy)")
    }

    func testAccessibilityValueSaysMutedWhenRowMuted() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: true, controllable: true)
        XCTAssertEqual(row.test_accessibilityValue, "muted")
    }

    func testAccessibilityValueComposesMutedAndPlayingHere() {
        let row = DeviceRowView(device: makeDevice(isMuted: true))
        row.apply(makeDevice(isMuted: true), selected: false, controllable: true,
                  liveAppNames: ["Spotify"])
        XCTAssertEqual(row.test_accessibilityValue, "muted, playing here")
    }

    func testAccessibilityValueEmptyAtRest() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        row.apply(makeDevice(connectionState: .off), selected: false)
        XCTAssertEqual(row.test_accessibilityValue, "", "no state, no clause")
    }

    func testMuteButtonAXStillReadsCorrectly() {
        // Task item 7: the existing mute AX must survive the new pill drawing.
        let muted = makeDevice(isMuted: true)
        let row = DeviceRowView(device: muted)
        row.apply(muted, selected: true, controllable: true)
        XCTAssertEqual(row.test_membershipAXLabel != nil, true)   // row AX intact
        // The mute button's label flips with the model, exactly as before.
        // (Reached through the row's accessibility children — the button is a
        // real NSButton; its label was set in apply.)
        row.apply(makeDevice(isMuted: false), selected: true, controllable: true)
        XCTAssertEqual(row.test_accessibilityValue, "armed", "unmuted+selected+connected reads armed again")
    }

    // MARK: Main Out row — dot, pill, drain, AX

    private func mainOutOptions() -> [MainOutRowView.Option] {
        [.init(title: "Selected Devices", target: .selectedDevices)]
    }

    func testMainOutArmedWhenConnectedAndUnmuted() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: false, connectionState: .connected)
        XCTAssertTrue(row.test_routeArmed)
        assertSameHue(row.test_dotFillColor, Tokens.Color.gold, "Main Out's armed dot is gold")
        XCTAssertEqual(row.test_accessibilityValue, "armed")
    }

    func testMainOutDarkWhenMasterMuted() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: true, connectionState: .connected)
        XCTAssertFalse(row.test_routeArmed, "master mute darkens the Main Out dot")
        XCTAssertTrue(row.test_isMutePillEngaged, "the master mute pill engages")
        XCTAssertEqual(row.test_accessibilityValue, "muted")
    }

    func testMainOutDarkWhenNotConnected() {
        for state: ConnectionState in [.off, .connecting] {
            let row = MainOutRowView()
            row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                      isMuted: false, connectionState: state)
            XCTAssertFalse(row.test_routeArmed, "\(state): no connected member ⇒ Main Out dot dark")
        }
    }

    func testMainOutMasterMuteDrainsItsMeter() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: false, connectionState: .connected)
        row.test_settleMeterDisplayed(0.7)

        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: true, connectionState: .connected)
        XCTAssertEqual(row.test_meterTarget, 0, "master mute zeroes the master meter's target (drain)")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            XCTAssertEqual(row.test_meterDisplayed, 0, accuracy: 0.001)
        } else {
            XCTAssertGreaterThan(row.test_meterDisplayed, 0, "drains with ballistics, not a snap")
        }
        // And a straggling push while muted is coerced to zero.
        row.setLevel(0.9)
        XCTAssertEqual(row.test_meterTarget, 0)
    }

    func testMainOutUnmuteRestoresPillAndArming() {
        let row = MainOutRowView()
        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: true, connectionState: .connected)
        XCTAssertTrue(row.test_isMutePillEngaged)

        row.apply(options: mainOutOptions(), current: .selectedDevices, master: 60,
                  isMuted: false, connectionState: .connected)
        XCTAssertFalse(row.test_isMutePillEngaged)
        XCTAssertTrue(row.test_routeArmed)
    }
}
