// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import SwiftUI
import AudioutProtocol
@testable import AudioutRemote

/// The two Speakers-tab rules that live in the views rather than on the wire:
/// where the Main Out thumb's in-drag echo LIVES, and when a device row's
/// volume/mute are enabled.
///
/// Both were live-caught bugs. The Main Out thumb ignored incoming snapshots
/// because its in-drag echo was hoisted onto the (never-torn-down) tab view;
/// the device rows only ever gated on `isAvailable`, leaving sliders draggable
/// for devices the Mac greys out. Views are `@MainActor` (SwiftUI's `View` is),
/// so these tests are too.
@Suite struct SpeakerRowRulesTests {

    // MARK: - Fixtures

    /// `isMainOutMember` DEFAULTS TO `isSelected`, because that is what the wire
    /// carries whenever Main Out targets Selected Devices: `mainOutMemberIDs`
    /// is the selected set in that branch, so the Mac sends the two fields
    /// equal (`GroupController.isMainOutMember(_:)`). Pass it explicitly to
    /// model the only case where they diverge — Main Out pointed at a group,
    /// where the members are sounding and are not selected, and anything left
    /// in the dormant selected set is selected and is not sounding.
    private func makeDevice(
        id: String = "d1",
        isAvailable: Bool = true,
        isSelected: Bool = false,
        isMainOutMember: Bool? = nil,
        isMuted: Bool = false,
        connectionState: String = "connected"
    ) -> DeviceState {
        let isMainOutMember = isMainOutMember ?? isSelected
        return DeviceState(
            id: id,
            name: "Kitchen Speaker",
            kind: "generic",
            iconSymbolName: "hifispeaker.fill",
            isAvailable: isAvailable,
            supportsAirPlay2: true,
            isLocalDevice: false,
            volume: 50,
            isMuted: isMuted,
            isSelected: isSelected,
            isMainOutMember: isMainOutMember,
            connection: DeviceState.ConnectionInfo(state: connectionState)
        )
    }

    private func makeRoute(kind: String, deviceID: String? = nil) -> AppRouteState {
        AppRouteState(
            bundleID: "com.example.app",
            displayName: "Example",
            destinationKind: kind,
            deviceID: deviceID,
            volume: 100,
            isRunning: true
        )
    }

    /// The names of a view's `@State` storage. SwiftUI owns the values and
    /// won't hand them over without a host, but WHICH VIEW DECLARES the
    /// storage is the exact property the Main Out bug turned on, and a plain
    /// `Mirror` can see that.
    ///
    /// The wrapper's stored form is a SwiftUI implementation detail that has
    /// already changed once (`State<…>` under `_name`, now `LazyState<…>`
    /// under `__name`), so match the type loosely and report the bare
    /// property name.
    @MainActor
    private func stateProperties(of view: some View) -> [String] {
        Mirror(reflecting: view).children.compactMap { child in
            guard let label = child.label,
                  String(describing: type(of: child.value)).contains("State<")
            else { return nil }
            return String(label.drop(while: { $0 == "_" }))
        }
    }

    // MARK: - Main Out thumb

    @MainActor
    @Test func theMainOutDragEchoCannotOutliveTheRowItBelongsTo() {
        // The regression the fix was actually for. It was a LIFETIME bug, not
        // an arithmetic one: the echo lived on `SpeakersView`, which the tab
        // bar keeps alive for the whole process, so a drag whose release
        // callback never arrived stranded it and the thumb ignored every
        // later snapshot. Declared on `MainOutRow` it dies with the list, and
        // the list goes with `session.snapshot` on any disconnect — so
        // pinning WHERE the storage lives pins the fix.
        #expect(stateProperties(of: SpeakersView(session: DemoMacSession())).isEmpty)
        #expect(stateProperties(of: MainOutRow(masterVolume: 40,
                                               isMuted: false,
                                               session: DemoMacSession()))
            .contains("localVolume"))
    }

    @MainActor
    @Test func mainOutThumbShowsTheMacsValueOnceTheEchoIsClear() {
        // The other half of the same fix: with the echo gone, the thumb
        // renders whatever the newest snapshot says, however many arrive.
        #expect(MainOutRow.thumbValue(local: nil, server: 40) == 40)
        #expect(MainOutRow.thumbValue(local: nil, server: 31) == 31)
        #expect(MainOutRow.thumbValue(local: nil, server: 0) == 0)
    }

    @MainActor
    @Test func mainOutThumbShowsTheFingerWhileADragIsInProgress() {
        // A snapshot landing mid-gesture must not fight the user's finger.
        // The same echo now also holds the RELEASED value until the Mac's
        // echo of it lands, which is why the release no longer clears it.
        #expect(MainOutRow.thumbValue(local: 12, server: 40) == 12)
    }

    // MARK: - Device row: volume + mute enablement (Mac parity)

    @MainActor
    @Test func aSelectedAvailableDeviceIsControllable() {
        #expect(DeviceRowView.isControllable(makeDevice(isSelected: true), appRoutes: []))
    }

    @MainActor
    @Test func anAvailableButUnselectedDeviceWithNoRoutesIsNotControllable() {
        // The bug: the phone left this one draggable, and every write bounced.
        #expect(!DeviceRowView.isControllable(makeDevice(isSelected: false), appRoutes: []))
    }

    @MainActor
    @Test func aRedirectTargetIsControllableWithoutBeingSelected() {
        let routes = [makeRoute(kind: "device", deviceID: "d1")]
        #expect(DeviceRowView.isControllable(makeDevice(isSelected: false), appRoutes: routes))
    }

    @MainActor
    @Test func routesPointedSomewhereElseDoNotMakeADeviceControllable() {
        let routes = [
            makeRoute(kind: "device", deviceID: "d2"),
            makeRoute(kind: "currentDevice"),
            makeRoute(kind: "noRedirect"),
        ]
        #expect(!DeviceRowView.isControllable(makeDevice(id: "d1", isSelected: false), appRoutes: routes))
    }

    @MainActor
    @Test func anUnavailableDeviceIsNeverControllable() {
        let routes = [makeRoute(kind: "device", deviceID: "d1")]
        #expect(!DeviceRowView.isControllable(makeDevice(isAvailable: false, isSelected: true), appRoutes: routes))
        #expect(!DeviceRowView.isControllable(makeDevice(isAvailable: false, isSelected: false), appRoutes: routes))
    }

    @MainActor
    @Test func connectionStateNeverGatesTheControls() {
        // Mac parity, over the states this row actually renders controls for:
        // a selected device that's off/connecting/reconnecting keeps draggable
        // controls — the Mac only dims them, and the server's refusal stays
        // the honest signal. "failed" is deliberately not in this list; it
        // renders no controls at all (next test).
        for state in ["off", "connecting", "reconnecting"] {
            #expect(DeviceRowView.isControllable(
                makeDevice(isSelected: true, connectionState: state), appRoutes: []))
            #expect(!DeviceRowView.showsFailureCard(makeDevice(connectionState: state)))
        }
    }

    @MainActor
    @Test func aFailedDeviceRendersTheFailureCardInsteadOfControls() {
        // Where the phone parts from the Mac on purpose (D9): a failed Mac row
        // keeps its slider and mute, desaturated; the phone swaps both for the
        // failure card, so the enablement rule's answer never reaches a
        // control here. The rule itself stays state-blind, as on the Mac.
        let failed = makeDevice(isSelected: true, connectionState: "failed")
        #expect(DeviceRowView.showsFailureCard(failed))
        #expect(DeviceRowView.isControllable(failed, appRoutes: []))
    }

    @MainActor
    @Test func aTapOnAFailureCardNeverTogglesPlay() {
        // Diagnose and Try Again share the row's gesture subtree, and a
        // "failed" device can still be isAvailable — so the tap rule, not the
        // availability rule, is what keeps a Diagnose press from silently
        // starting the speaker.
        #expect(!DeviceRowView.tapTogglesPlay(
            makeDevice(isSelected: true, connectionState: "failed"), mainOut: selectedTarget))
        #expect(!DeviceRowView.tapTogglesPlay(makeDevice(isAvailable: false), mainOut: selectedTarget))
        #expect(DeviceRowView.tapTogglesPlay(makeDevice(), mainOut: selectedTarget))
    }

    // MARK: - Device row: what a tap may do while a group is playing

    private var selectedTarget: MainOutState { MainOutState(kind: "selected") }
    private var groupTarget: MainOutState { MainOutState(kind: "group", groupID: "g1") }

    @MainActor
    @Test func noTapStartsOrStopsASpeakerWhileAGroupIsMainOut() {
        // What plays is the group's membership. The row's tap writes the
        // Selected Devices set, which the Mac holds dormant under a group
        // target — accepted, silent, and changing nothing — so the row would
        // echo a state for two seconds and snap back. It says why instead.
        #expect(!DeviceRowView.tapTogglesPlay(
            makeDevice(isSelected: false, isMainOutMember: true), mainOut: groupTarget))
        #expect(!DeviceRowView.tapTogglesPlay(
            makeDevice(isSelected: true, isMainOutMember: false), mainOut: groupTarget))
        #expect(DeviceRowView.playRefusal(mainOut: groupTarget) != nil)
    }

    @MainActor
    @Test func aSelectedDevicesTargetRefusesNoTap() {
        // The refusal is a property of the TARGET, not of a device: with Main
        // Out on Selected Devices every row's tap means what it says.
        #expect(DeviceRowView.playRefusal(mainOut: selectedTarget) == nil)
        #expect(DeviceRowView.tapTogglesPlay(makeDevice(isSelected: true), mainOut: selectedTarget))
    }

    @MainActor
    @Test func muteNeverFreezesTheLevel() {
        #expect(DeviceRowView.isControllable(makeDevice(isSelected: true, isMuted: true), appRoutes: []))
    }

    @MainActor
    @Test func aGroupMemberIsAdjustableWhileItsGroupIsMainOut() {
        // The live-caught bug: activating a group left every member's level
        // frozen, because the rule read `isSelected` — which a group member
        // isn't. The rule is "you can set the level of a speaker you can
        // hear", and the server takes the write (`setMemberVolume`).
        #expect(DeviceRowView.isControllable(
            makeDevice(isSelected: false, isMainOutMember: true), appRoutes: []))
    }

    @MainActor
    @Test func aDeviceStrandedInTheDormantSelectedSetIsNotAdjustable() {
        // The other direction of the same field, and why `isSounding` is
        // `isMainOutMember` alone rather than an OR: while a group plays, a
        // speaker still ticked in the dormant Selected Devices set is silent,
        // so it has no level to set.
        #expect(!DeviceRowView.isControllable(
            makeDevice(isSelected: true, isMainOutMember: false), appRoutes: []))
    }

    // MARK: - Device row: a disabled control says why

    @MainActor
    @Test func aDisabledControlSpeaksItsReason() {
        // The Mac puts the reason in the row's own composed label; the phone
        // has no row label, so the two disabled controls carry it. An enabled
        // control adds nothing.
        #expect(DeviceRowView.disabledReason(
            for: makeDevice(isSelected: true), controllable: true) == nil)
        // One vocabulary: the screen never says "armed" or "selected", so
        // neither does the reason a control gives for being off.
        #expect(DeviceRowView.disabledReason(
            for: makeDevice(), controllable: false) == "Its level can be set once it's playing.")
        #expect(DeviceRowView.disabledReason(
            for: makeDevice(isAvailable: false), controllable: false) == "This speaker isn't on the network.")
    }

    // MARK: - Device row: the dead drag answers back

    @MainActor
    @Test func aDragOnARowThatCannotBeAdjustedRaisesTheRowsOwnReason() throws {
        // The screen's coach promises "DRAG TO SET LEVEL" on every row, so a
        // row the rule won't adjust owes an answer rather than silence. It is
        // the SAME sentence the disabled control already speaks — one reason,
        // two audiences — and it goes out on the same channel the Mac's own
        // refusals arrive on, so a refused write and a write that never left
        // look alike from the finger's side.
        let center = ToastCenter()
        let ready = makeDevice(isSelected: false)
        #expect(!DeviceRowView.isControllable(ready, appRoutes: []))

        let reason = try #require(DeviceRowView.disabledReason(for: ready, controllable: false))
        center.show(.refusal(reason: reason))
        #expect(center.current?.message == "Its level can be set once it's playing.")

        center.show(.refusal(reason: try #require(
            DeviceRowView.disabledReason(for: makeDevice(isAvailable: false), controllable: false))))
        #expect(center.current?.message == "This speaker isn't on the network.")
    }

    @MainActor
    @Test func aRowThatCanBeAdjustedHasNothingToRefuse() {
        // The other half of the trigger: the toast is raised only where the
        // reason exists, so a live row's drag stays silent and just moves.
        #expect(DeviceRowView.disabledReason(
            for: makeDevice(isSelected: true), controllable: true) == nil)
    }

    @MainActor
    @Test func aLongerRefusalStaysUpLongEnoughToRead() {
        // Three seconds is a glance. The refusals this channel carries are
        // whole sentences — the Mac's own — so the dwell grows with the
        // message, and stops growing before anything can camp on the screen.
        #expect(ToastCenter.displayDuration(for: "Unknown device.")
                < ToastCenter.displayDuration(for: "Its level can be set once it's playing."))
        #expect(ToastCenter.displayDuration(for: "") == .milliseconds(3000))
        #expect(ToastCenter.displayDuration(for: String(repeating: "x", count: 500))
                == .milliseconds(6000))
    }

    // MARK: - Device row: what VoiceOver reads as the value

    @MainActor
    @Test func theRowSpeaksItsPlayingState() {
        // The word on the screen, spoken: the sub-label says PLAYING and the
        // section it sits in is titled PLAYING, so the value cannot say ARMED.
        // Its opposite is READY on screen, so it is "Ready" in the ear too —
        // one word per state, not one per audience.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: true), isSelected: true, isRouted: false) == "Playing")
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: false), isSelected: false, isRouted: false) == "Ready")
    }

    @MainActor
    @Test func theRowSpeaksTheStatesThatReplaceReadyOnScreen() {
        // `subLabel`'s branch order, in the ear: a speaker that is off the
        // network or still connecting says so instead of claiming to be READY,
        // which is specifically the word for a speaker that is fine and idle.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(connectionState: "connecting"), isSelected: false, isRouted: false)
            == "Connecting")
        // The echo can say PLAYING while the connection is still coming up;
        // the screen shows CONNECTING… in that beat, so the value does too.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: true, connectionState: "connecting"),
            isSelected: true, isRouted: false) == "Connecting")
        // A link that dropped is its own news, and it is not PLAYING: the room
        // is silent until it comes back, so the row says so in both channels.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: true, connectionState: "reconnecting"),
            isSelected: true, isRouted: false) == "Reconnecting")
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(connectionState: "reconnecting"), isSelected: false, isRouted: false)
            == "Reconnecting")
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isAvailable: false), isSelected: false, isRouted: false)
            == "Unavailable")
        // Unavailability outranks everything, exactly as it does on screen.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isAvailable: false, isSelected: true, connectionState: "connecting"),
            isSelected: true, isRouted: false) == "Unavailable")
    }

    @MainActor
    @Test func theRowSpeaksTheStatesItOtherwiseShowsInColourAlone() {
        // On screen these are a tinted sub-label and an 11 pt dot on a halo
        // the row hides from VoiceOver — colour and position only. The value
        // is the one place either of them is spoken.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: true, isMuted: true),
            isSelected: true, isRouted: false) == "Playing, Muted")
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: true),
            isSelected: true, isRouted: true) == "Playing, App audio routed here")
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: true, isMuted: true), isSelected: true, isRouted: true)
            == "Playing, Muted, App audio routed here")
        // A route can point at a device nobody started — the value says both.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: false),
            isSelected: false, isRouted: true) == "Ready, App audio routed here")
    }

    // MARK: - Which section a speaker lands in

    @MainActor
    @Test func aSpeakerSectionIsWhatTheSpeakerIsDoing() {
        // The list is cut by state and nothing else, so every device has
        // exactly one address and no row is drawn twice.
        #expect(SpeakerSection.of(makeDevice(isSelected: true)) == .playing)
        #expect(SpeakerSection.of(makeDevice(isSelected: false)) == .ready)
        #expect(SpeakerSection.of(makeDevice(isAvailable: false)) == .unavailable)
    }

    @MainActor
    @Test func aGroupsMembersArePlayingTheMomentTheGroupIs() {
        // The live-caught bug: enabling a group left its speakers sitting in
        // READY while the room they're in played. PLAYING is what Main Out is
        // sending to (`isSounding` = `isMainOutMember`), not what happens to
        // be ticked in the Selected Devices set.
        #expect(SpeakerSection.of(
            makeDevice(isSelected: false, isMainOutMember: true)) == .playing)
        // And the reverse, from the same snapshot: a speaker left in the
        // dormant selected set while the group plays is silent, so it is READY.
        #expect(SpeakerSection.of(
            makeDevice(isSelected: true, isMainOutMember: false)) == .ready)
        // A member that is off the network is still off the network.
        #expect(SpeakerSection.of(
            makeDevice(isAvailable: false, isSelected: false, isMainOutMember: true)) == .unavailable)
        // And a member whose link failed is still a failure card in READY.
        #expect(SpeakerSection.of(
            makeDevice(isSelected: false, isMainOutMember: true, connectionState: "failed")) == .ready)
    }

    @MainActor
    @Test func aFailedSpeakerIsReadyRatherThanPlaying() {
        // The Mac still has it selected, but it is making no sound and its row
        // is a failure card asking to be retried — PLAYING would be a lie the
        // section heading tells before the row can correct it.
        #expect(SpeakerSection.of(
            makeDevice(isSelected: true, connectionState: "failed")) == .ready)
        // Off the network outranks everything, exactly as the sub-label does.
        #expect(SpeakerSection.of(
            makeDevice(isAvailable: false, isSelected: true, connectionState: "failed"))
            == .unavailable)
    }

    @MainActor
    @Test func aConnectingSpeakerStaysInPlayingWhileItComesUp() {
        // Section membership follows the Mac's selection, not the link: a
        // speaker on its way up belongs where it is going, and the row's own
        // sub-label (CONNECTING… / RECONNECTING…) carries the beat it is in.
        for state in ["connecting", "reconnecting", "off"] {
            #expect(SpeakerSection.of(
                makeDevice(isSelected: true, connectionState: state)) == .playing)
        }
    }

    @MainActor
    @Test func theDemoMacStagesAPlayingGroupTheSameWayARealOneDoes() throws {
        // The offline fixture has to be able to produce this list, or the
        // group case can only ever be seen on real hardware.
        let demo = DemoMacSession()
        demo.setMainOut(MainOutState(kind: "group", groupID: "demo-living-room"))
        let devices = try #require(demo.snapshot).devices

        for id in ["demo-sonos-left", "demo-sonos-right"] {
            let member = try #require(devices.first { $0.id == id })
            #expect(member.isMainOutMember && !member.isSelected, "a group member, not a selected one")
            #expect(SpeakerSection.of(member) == .playing)
            #expect(DeviceRowView.isControllable(member, appRoutes: []))
        }
        // The Mac stays ticked in the dormant selected set and is not playing.
        let mac = try #require(devices.first { $0.id == "local-mac" })
        #expect(mac.isSelected && !mac.isMainOutMember)
        #expect(SpeakerSection.of(mac) == .ready)
    }

    // MARK: - Device row: the tap's local echo

    @MainActor
    @Test func aTappedRowShowsTheTapUntilTheMacAnswers() {
        // The tap has to change something on screen before the Mac's snapshot
        // comes back ~100-300ms later, so the row renders the pending value
        // while one is in flight — the same shape as the Main Out thumb's echo.
        #expect(DeviceRowView.selectionEcho(pending: true, server: false))
        #expect(!DeviceRowView.selectionEcho(pending: false, server: true))
    }

    @MainActor
    @Test func aRowWithNoTapInFlightShowsTheMacsAnswer() {
        // Both bounds land here: the snapshot that confirms the tap clears the
        // echo, and so does the two-second timeout behind a refused write —
        // after either, the row is back on the Mac's own state.
        #expect(DeviceRowView.selectionEcho(pending: nil, server: true))
        #expect(!DeviceRowView.selectionEcho(pending: nil, server: false))
    }

    @MainActor
    @Test func theSpokenValueFollowsTheEchoRatherThanTheSnapshot() {
        // What the screen shows and what VoiceOver says are the same state,
        // pending or not — which is why the flag is a parameter.
        #expect(DeviceRowView.spokenValue(
            for: makeDevice(isSelected: false), isSelected: true, isRouted: false) == "Playing")
    }

    // MARK: - The fader rail (the boundary tick's trigger)

    @Test func aFaderOnlyReportsARailWhileAFingerIsOnIt() {
        // The tick marks the end of the travel, so it needs a finger doing the
        // travelling: a snapshot that happens to arrive at 0 or 100 is not a
        // rail hit, and the resting rows must never buzz.
        #expect(WarmSignal.faderRail(0, dragging: false) == nil)
        #expect(WarmSignal.faderRail(100, dragging: false) == nil)
        #expect(WarmSignal.faderRail(0, dragging: true) == 0)
        #expect(WarmSignal.faderRail(100, dragging: true) == 100)
    }

    @Test func theMiddleOfADragIsNeverARail() {
        // The rail trigger is the ends and nothing else — the middle of the
        // track belongs to ``WarmSignal/FaderDetents``, at its own strength.
        for value in [1, 25, 50, 75, 99] {
            #expect(WarmSignal.faderRail(value, dragging: true) == nil)
        }
    }

    @Test func theTwoRailsAreDistinctSoCrossingTheTrackTicksTwice() {
        // The trigger is the rail's identity, not a flag: dragging 0 → 100
        // changes it nil → 0 → nil → 100, so both ends are felt. A Bool would
        // have gone true → false → true and said the same thing at both ends.
        #expect(WarmSignal.faderRail(0, dragging: true) != WarmSignal.faderRail(100, dragging: true))
    }

    // MARK: - The fader detents (the drag's clicks)

    /// A clock instant far enough past the last one that the rate limit never
    /// interferes — every test below that isn't ABOUT thinning uses it.
    private func unhurried(_ start: ContinuousClock.Instant, _ steps: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(200 * steps))
    }

    @Test func aDragClicksOncePerDetentCrossedGoingUp() {
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 20)
        // 20 → 40 crosses 25, 30, 35 and 40: four notches, four clicks.
        for (i, v) in [23, 25, 29, 31, 36, 40].enumerated() {
            detents.advance(to: v, now: unhurried(t0, i + 1))
        }
        #expect(detents.ticks == 4)
    }

    @Test func aDragClicksTheSameGoingDown() {
        // The notch is a position, not a direction: 40 → 20 crosses the same
        // four, so a level walked back feels like the walk out.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 40)
        for (i, v) in [37, 35, 31, 29, 24, 20].enumerated() {
            detents.advance(to: v, now: unhurried(t0, i + 1))
        }
        #expect(detents.ticks == 4)
    }

    @Test func standingStillIsSilent() {
        // A finger held on the track is not adjusting anything.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 50)
        for i in 1...10 { detents.advance(to: 50, now: unhurried(t0, i)) }
        #expect(detents.ticks == 0)
    }

    @Test func aJitteringFingerInsideOneNotchIsSilent() {
        // 51-54 is all the same notch as 50. Sub-detent wobble is the finger,
        // not the value, and it must not machine-gun.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 50)
        for (i, v) in [51, 53, 52, 54, 51].enumerated() {
            detents.advance(to: v, now: unhurried(t0, i + 1))
        }
        #expect(detents.ticks == 0)
    }

    @Test func oneFastJumpAcrossManyDetentsIsOneClick() {
        // A flick that lands 60 units away crossed twelve notches in one drag
        // tick. The hand made ONE movement, so it gets one click — twelve
        // queued behind it would arrive after the finger had already stopped.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 10)
        detents.advance(to: 70, now: unhurried(t0, 1))
        #expect(detents.ticks == 1)
    }

    @Test func aFastSwipeIsThinnedRatherThanQueued() {
        // The whole track in 250 ms: 20 notches, which unthinned is 80 clicks
        // a second and reads as a buzz. At a 50 ms floor that quarter second
        // can yield at most five.
        var now = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 1)
        for v in stride(from: 5, through: 99, by: 5) {
            now = now.advanced(by: .milliseconds(250 / 20))
            detents.advance(to: v, now: now)
        }
        #expect(detents.ticks <= 5)
        #expect(detents.ticks >= 4)   // and it is not silent either
    }

    @Test func theRailsOwnTheirOwnEnds() {
        // 0 and 100 are multiples of the step, so without the guard the stop
        // would fire a detent click on top of ``faderRail``'s stronger one.
        // Arriving somewhere and passing through have to feel different.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 10)
        detents.advance(to: 0, now: unhurried(t0, 1))
        #expect(detents.ticks == 0)

        var top = WarmSignal.FaderDetents()
        top.begin(at: 90)
        top.advance(to: 100, now: unhurried(t0, 1))
        #expect(top.ticks == 0)
    }

    @Test func leavingARailClicksAtTheFirstNotchAndNotBefore() {
        // The suppressed rail still records where the finger was, so pushing
        // off 0 doesn't fire a stale click at 1 — and 6 (the first crossing of
        // 5) does fire.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 0)
        detents.advance(to: 3, now: unhurried(t0, 1))
        #expect(detents.ticks == 0)
        detents.advance(to: 6, now: unhurried(t0, 2))
        #expect(detents.ticks == 1)
    }

    @Test func aNewGestureStartsFromWhereTheFingerLands() {
        // Where the finger already is was never crossed. A drag that begins
        // at 47 and moves to 48 has passed nothing.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        detents.begin(at: 47)
        detents.advance(to: 48, now: unhurried(t0, 1))
        #expect(detents.ticks == 0)
    }

    @Test func theTickCountOnlyEverRisesSoTheTriggerAlwaysFires() {
        // `.sensoryFeedback(trigger:)` fires on CHANGE. A counter that reset
        // per gesture would eventually hand it a value it had already seen,
        // and that click would be silently swallowed.
        let t0 = ContinuousClock.now
        var detents = WarmSignal.FaderDetents()
        var seen: [Int] = []
        for gesture in 0..<3 {
            detents.begin(at: 20)
            detents.advance(to: 30, now: unhurried(t0, gesture * 2 + 1))
            seen.append(detents.ticks)
        }
        #expect(seen == [1, 2, 3])
    }

    @Test func theDetentStaysTheWeakerOfTheTwoClicks() {
        // The rails fire at full strength for their weight, so a notch that
        // reached 1.0 would make running out of track and crossing a detent
        // feel like the same event. The strength itself was settled by thumb;
        // this is the bound that any future retune has to stay inside.
        #expect(WarmSignal.FaderDetents.intensity < 1)
    }

    @Test func theDetentStepMatchesTheSpokenAdjustableStep() {
        // One notch means one thing whether it is felt or spoken: the rows'
        // `accessibilityAdjustableAction` moves by 5 too.
        #expect(WarmSignal.FaderDetents.step == 5)
    }

    // MARK: - The level's one coordinate

    @Test func fingerTravelAndTheLightsEdgeAgreeAcrossTheWholeRow() {
        // The rule the whole row rests on: the light's edge, the line on it,
        // the rail that fades in under it and the finger that moves it all
        // take the same fraction of the same row width. Give any one of them
        // its own track — an inset rail, say — and the fill lands a few points
        // off the finger, which at the exact spot the user is looking is the
        // one error that cannot hide.
        let row: CGFloat = 365
        for target in [0, 10, 25, 50, 65, 90, 100] {
            let travel = CGFloat(target) / 100 * row
            let value = WarmSignal.faderValue(start: 0, translationWidth: travel, trackWidth: row)
            #expect(value == target)
            #expect(abs(CGFloat(value) / 100 * row - travel) < 0.5 * row / 100)
        }
    }

    @Test func aDragAcrossTheRowCoversTheWholeRange() {
        // Both rails are reachable inside one gesture, which is what makes the
        // row's ends and the fader's ends the same ends.
        let row: CGFloat = 365
        #expect(WarmSignal.faderValue(start: 0, translationWidth: row, trackWidth: row) == 100)
        #expect(WarmSignal.faderValue(start: 100, translationWidth: -row, trackWidth: row) == 0)
    }

    @Test func aRowWithNoWidthYetHoldsItsValueRatherThanZeroingIt() {
        // First layout pass reports 0. Dividing by it would send the level to
        // NaN and the light with it.
        #expect(WarmSignal.faderValue(start: 65, translationWidth: 40, trackWidth: 0) == 65)
    }

    // MARK: - The one-time gesture coach

    @Test func theCoachStaysUntilBothGesturesHaveBeenUsed() {
        // One gesture is no evidence for the other: a user who has tapped a
        // row still has no way of knowing the row is also a fader.
        #expect(SpeakerCoach.isVisible(learnedTap: false, learnedDrag: false))
        #expect(SpeakerCoach.isVisible(learnedTap: true, learnedDrag: false))
        #expect(SpeakerCoach.isVisible(learnedTap: false, learnedDrag: true))
        #expect(!SpeakerCoach.isVisible(learnedTap: true, learnedDrag: true))
    }

    @Test func learningAGestureAndDismissingBothPersist() throws {
        let suite = "SpeakerCoachTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SpeakerCoach.learned(.tap, in: defaults)
        #expect(defaults.bool(forKey: SpeakerCoach.Gesture.tap.rawValue))
        #expect(!defaults.bool(forKey: SpeakerCoach.Gesture.drag.rawValue))

        // GOT IT is the user saying they know both, so it has to answer the
        // rule the same way using both gestures would.
        SpeakerCoach.dismiss(in: defaults)
        #expect(!SpeakerCoach.isVisible(
            learnedTap: defaults.bool(forKey: SpeakerCoach.Gesture.tap.rawValue),
            learnedDrag: defaults.bool(forKey: SpeakerCoach.Gesture.drag.rawValue)))
    }
}
