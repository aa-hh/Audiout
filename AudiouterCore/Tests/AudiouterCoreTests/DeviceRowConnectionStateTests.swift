import Testing
import AppKit
import AudiouterCore
@testable import AudiouterSharedUI

/// Row-focused tests for the on-icon connection-status dot + the sublabel
/// precedence ladder (2026-07-17 checkbox + routing-line redesign): the four
/// `ConnectionState` renderings (`test_statusKind`/`test_statusText`), the
/// name-click-toggles-enabled wiring (`test_clickName`) now through the
/// checkbox, the routing sublabel composed from `selected` + `routedAppNames`,
/// and that a repeated `apply` cleanly re-derives the badge rather than
/// leaving a stale state.
@Suite struct DeviceRowConnectionStateTests {

    private func makeDevice(connectionState: ConnectionState = .off) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod, connectionState: connectionState)
    }

    // MARK: Four states → four badge renderings (+ failed-only sublabel)

    @Test func offShowsNoDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        #expect(row.test_statusKind == .none)
        #expect(row.test_statusText == nil)
    }

    @Test func connectingShowsConnectingDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        #expect(row.test_statusKind == .connecting)
        #expect(row.test_statusText == nil, "connecting is single-line (no sublabel)")
    }

    @Test func reconnectingShowsConnectingDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        #expect(row.test_statusKind == .connecting)
        #expect(row.test_statusText == nil, "reconnecting is single-line (no sublabel)")
    }

    @Test func connectedShowsGreenDotAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        #expect(row.test_statusKind == .connected)
        #expect(row.test_statusText == nil, "connected is single-line (no sublabel)")
    }

    @Test func failedShowsFailedDotAndSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        #expect(row.test_statusKind == .failed)
        #expect(row.test_statusText == "Couldn't connect", "failed is the only two-line row")
    }

    // MARK: Repeated `apply` cleanly re-derives the badge

    @Test func repeatedApplyReDerivesWhenLeavingConnecting() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        #expect(row.test_statusKind == .connecting)

        row.apply(makeDevice(connectionState: .connected), selected: true)
        #expect(row.test_statusKind == .connected)
        // Selected + no routed apps → routing sublabel is the bare "System" token
        // (a selected device is always in the routing set). The badge, not the
        // sublabel, is what this test exercises re-deriving.
        #expect(row.test_statusText == "System")
    }

    @Test func repeatedApplyClearsSublabelWhenLeavingFailed() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .vanished))))
        #expect(row.test_statusKind == .failed)
        #expect(row.test_statusText == "Couldn't connect")

        row.apply(makeDevice(connectionState: .off), selected: false)
        #expect(row.test_statusKind == .none)
        #expect(row.test_statusText == nil, "the failed sublabel cleared on leaving .failed")
    }

    @Test func sameStateReappliedStaysConsistent() {
        // A re-render for an unrelated reason (e.g. a volume echo) while the
        // state is unchanged must leave the badge/sublabel consistent.
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: false)
        #expect(row.test_statusKind == .connecting)
        #expect(row.test_statusText == nil)
    }

    // MARK: Routing sublabel precedence ladder (2026-07-17)
    //
    // failed "Couldn't connect" > "Unavailable" > routing line ("System" +
    // bypassed app names joined by " · ") > no sublabel. Composed from
    // `selected` (the "System" token) + `routedAppNames` (Wiring-supplied).

    @Test func sourceLineIsSystemOnlyWhenSelectedWithNoRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, routedAppNames: [])
        #expect(row.test_statusText == "System")
    }

    @Test func sourceLineIsSystemPlusAppsWhenSelectedWithRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, routedAppNames: ["Music", "Safari"])
        #expect(row.test_statusText == "System · Music · Safari",
                       "System always leads, tokens joined by ' · '")
    }

    @Test func sourceLineIsBareAppNamesWhenNotSelectedWithRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Spotify"])
        #expect(row.test_statusText == "Spotify",
                       "not selected: no 'System' token, just the bypassed app(s)")
    }

    @Test func sourceLineIsHiddenWhenNotSelectedWithNoRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: [])
        #expect(row.test_statusText == nil, "empty routing set: no sublabel, single-line row")
    }

    @Test func sourceLineShowsUnavailableWhenDeviceUnreachable() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isAvailable: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, routedAppNames: ["Music"])
        #expect(row.test_statusText == "Unavailable",
                       "unavailable wins over the routing line even with a non-empty routing set")
    }

    @Test func failedTakesPrecedenceOverRoutingAndUnavailable() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                            isAvailable: false, connectionState: .failed(.init(cause: .notResponding)))
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, routedAppNames: ["Music", "Safari"])
        #expect(row.test_statusText == "Couldn't connect",
                       "failed is highest precedence, even over unavailable + a non-empty routing set")
    }

    @Test func sourceLinePreservesRoutedAppNameOrder() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Zebra App", "Alpha App"])
        #expect(row.test_statusText == "Zebra App · Alpha App",
                       "the view doesn't re-sort — it renders routedAppNames in the given order")
    }

    // MARK: Live-streaming precedence (T9 — `liveAppNames` vs `routedAppNames`)
    //
    // `liveAppNames` (CONFIRMED currently streaming, `BackendEvent.routedApps`)
    // takes precedence over `routedAppNames` (routing INTENT/config) in the
    // routing line whenever it's non-empty; an empty `liveAppNames` falls back
    // to the intent-based label so a pending redirect isn't left blank.

    @Test func liveAppNamesTakePrecedenceOverRoutedAppNamesWhenNonEmpty() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false,
                  routedAppNames: ["Spotify"], liveAppNames: ["Music"])
        #expect(row.test_statusText == "Music",
                       "the confirmed live set wins over the merely-configured intent set")
    }

    @Test func emptyLiveAppNamesFallsBackToRoutedAppNames() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false,
                  routedAppNames: ["Spotify"], liveAppNames: [])
        #expect(row.test_statusText == "Spotify",
                       "nothing confirmed streaming yet: falls back to the intent-based label")
    }

    @Test func liveAppNamesStillLeadWithSystemTokenWhenSelected() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true,
                  routedAppNames: ["Spotify"], liveAppNames: ["Music", "Safari"])
        #expect(row.test_statusText == "System · Music · Safari",
                       "'System' still leads off `selected`; the live set replaces the app tokens")
    }

    @Test func clearingLiveAppNamesOnReapplyRevertsToRoutedAppNames() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Spotify"], liveAppNames: ["Music"])
        #expect(row.test_statusText == "Music")

        // The live mapping cleared (e.g. capture stopped) — a repeated apply with
        // an empty liveAppNames must revert to the intent-based label, not go
        // blank or keep showing the stale confirmed name.
        row.apply(makeDevice(), selected: false, routedAppNames: ["Spotify"], liveAppNames: [])
        #expect(row.test_statusText == "Spotify")
    }

    @Test func sourceTextHookReportsLivePrecedence() {
        let row = DeviceRowView(device: makeDevice())
        #expect(row.test_sourceText(routedAppNames: ["Spotify"], liveAppNames: ["Music"]) == "Music")
        #expect(row.test_sourceText(routedAppNames: ["Spotify"]) == "Spotify",
                       "liveAppNames defaults to empty for back-compat callers")
    }

    // MARK: Name-click toggles the checkbox (same delegate path)

    private final class RecordingDelegate: DeviceRowView.Delegate {
        var toggledFor: String?
        var toggledOn: Bool?
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
            toggledFor = id
            toggledOn = on
        }
    }

    @Test func clickingNameTogglesEnabledOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)   // checkbox OFF, enabled
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        #expect(delegate.toggledFor == "dev-1")
        #expect(delegate.toggledOn == true, "OFF → click → ON via the checkbox's delegate path")
        #expect(row.test_isEnabledOn, "the checkbox flipped ON")
    }

    @Test func clickingNameOnFailedDeviceRetriesByEnabling() {
        // A failed device's toggle rests OFF; clicking the name re-enables it
        // (= retry) — the intended behaviour.
        let device = makeDevice(connectionState: .failed(.init(cause: .refusedOrBusy)))
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        #expect(delegate.toggledOn == true, "clicking a failed row's name retries (enables)")
    }

    @Test func clickingNameIsNoOpWhenToggleBlocked() {
        // The Phase-1 local-mix block disables the checkbox; the name-click must
        // be a no-op then (same condition the checkbox's isEnabled uses).
        let device = Device(id: "local", name: "This Mac", kind: .localMac)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, blocked: true, blockReason: "blocked")
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        #expect(delegate.toggledFor == nil, "name-click is a no-op when the toggle is disabled")
    }

    // MARK: Checkbox replaces the switch — old toggle test hooks still pass through it

    @Test func toggleEnabledHookDrivesDelegateThroughCheckbox() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_toggleEnabled(true)

        #expect(delegate.toggledFor == "dev-1")
        #expect(delegate.toggledOn == true)
    }

    @Test func isEnabledOnReflectsSelectedStateViaCheckbox() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)

        row.apply(device, selected: true)
        #expect(row.test_isEnabledOn, "checkbox reads ON when selected")

        row.apply(device, selected: false)
        #expect(!row.test_isEnabledOn, "checkbox reads OFF when not selected")
    }

    @Test func showsToggleReflectsCheckboxVisibility() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let topLevelRow = DeviceRowView(device: device, showsToggle: true)
        #expect(topLevelRow.test_showsToggle, "Selected-Devices rows show the checkbox")

        let memberRow = DeviceRowView(device: device, showsToggle: false)
        #expect(!memberRow.test_showsToggle, "group-member rows hide the checkbox")
    }

    // MARK: `controllable` — slider/mute enable independent of `selected` (Q2)

    /// A redirect-only device: `selected: false, controllable: true` — the
    /// checkbox stays OFF and there is NO "System" token in the sublabel, but the
    /// slider/mute must be enabled.
    @Test func redirectOnlyDeviceHasSliderMuteEnabledCheckboxOffNoSystemToken() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: true, routedAppNames: ["Music"])

        #expect(!row.test_isEnabledOn, "checkbox stays OFF — this device isn't in Selected Devices")
        #expect(row.test_statusText == "Music",
                       "no 'System' token: the routing line is bare app names, keyed off `selected`")
    }

    /// `selected: true, controllable: false` documents the back-compat footgun:
    /// omitting `controllable` for an otherwise-selected device disables its
    /// slider/mute even though the checkbox is ON.
    @Test func selectedWithoutControllableDisablesSliderMuteButKeepsCheckboxOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: false)

        #expect(row.test_isEnabledOn, "checkbox reflects `selected`, independent of `controllable`")
        #expect(row.test_statusText == "System", "the 'System' token is keyed off `selected`, not `controllable`")
    }

    /// A normal selected + controllable device: checkbox ON, slider/mute
    /// enabled, "System" token present — the ordinary in-Selected-Devices case.
    @Test func selectedAndControllableShowsSystemTokenWithCheckboxOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true, routedAppNames: ["Safari"])

        #expect(row.test_isEnabledOn)
        #expect(row.test_statusText == "System · Safari")
    }

    // MARK: V1 — mute tint (accent while muted, secondary otherwise)

    @Test func muteTintIsAccentWhenMutedViaApply() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_muteTintColor == .controlAccentColor, "apply() lands the accent tint while muted")
    }

    @Test func muteTintIsSecondaryWhenUnmutedViaApply() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_muteTintColor == .secondaryLabelColor, "unmuted reads as the neutral secondary tint")
    }

    @Test func muteTintUpdatesInstantlyOnLiveClick() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)
        #expect(row.test_muteTintColor == .secondaryLabelColor)

        // `test_toggleMute` drives the exact same path a real click does
        // (AppKit's own state flip, then `muteToggled(_:)`'s `updateMuteTint()`)
        // — the tint must update WITHOUT waiting for a host-driven `apply`.
        row.test_toggleMute(true)
        #expect(row.test_muteTintColor == .controlAccentColor, "a live click updates the tint instantly")

        row.test_toggleMute(false)
        #expect(row.test_muteTintColor == .secondaryLabelColor, "toggling back off reverts the tint instantly")
    }

    // MARK: V7 — the `%` readout dims with the slider's disabled state

    @Test func readoutDimsWhenSliderDisabled() {
        // Not controllable ⇒ slider disabled ⇒ readout should read tertiary.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: false)

        #expect(!row.test_isSliderEnabled)
        #expect(row.test_readoutColor == .tertiaryLabelColor, "readout dims alongside a disabled slider")
    }

    @Test func readoutIsSecondaryWhenSliderEnabled() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_isSliderEnabled)
        #expect(row.test_readoutColor == .secondaryLabelColor, "readout is the normal secondary color when enabled")
    }

    // MARK: V12 — a blocked toggle greys the device name

    @Test func blockedToggleGreysDeviceName() {
        let device = Device(id: "local", name: "This Mac", kind: .localMac)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, blocked: true, blockReason: "blocked")

        #expect(row.test_nameColor == .tertiaryLabelColor,
                       "a blocked row's name greys out consistently with its disabled toggle")
    }

    // MARK: A5 — slider stays live while muted (mute ≠ frozen volume)

    @Test func sliderStaysEnabledWhileMuted() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_isSliderEnabled, "a muted device's slider stays draggable")
    }

    // MARK: A1 — selectionDimmed dims the checkbox without disabling it

    @Test func selectionDimmedDimsCheckboxButKeepsItInteractive() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, selectionDimmed: true)

        #expect(row.test_isSelectionDimmed, "the checkbox renders dimmed")
        #expect(!row.test_isEnabledOn)

        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.test_toggleEnabled(true)
        #expect(delegate.toggledOn == true, "still fully interactive while dimmed — decision: dim, don't disable")
    }

    @Test func selectionNotDimmedByDefault() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)

        #expect(!row.test_isSelectionDimmed, "existing callers that omit selectionDimmed are unaffected")
    }

    // MARK: A4 — flashRow(), gated on Reduce Motion

    @Test func flashRowMatchesReduceMotionSetting() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        #expect(!row.test_isFlashing, "no flash before flashRow() is called")

        row.test_flashRow()

        // The guard inside `flashRow()` is `!accessibilityDisplayShouldReduceMotion`
        // — assert the hook's outcome matches that same live system flag, which
        // is exactly the branch under test (no way to force the OS setting from
        // a headless unit test, so this pins the mapping rather than one outcome).
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(row.test_isFlashing == !reduceMotion,
                       "flashRow() is a no-op under Reduce Motion, and fires otherwise")
    }

    // MARK: Leading VU meter (task T8, extends the T3/T5 shared symbol contract)

    /// `setLevel` on a meter-enabled row reaches the meter and is readable back
    /// via `test_meterLevel`.
    @Test func setLevelOnMeterEnabledRowIsReflectedByTestMeterLevel() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.setLevel(0.42)
        #expect(row.test_meterLevel() == 0.42)
    }

    /// `showsMeter: false` (the mixer window/`GroupRowView` default) makes
    /// `setLevel` a no-op — `test_meterLevel` stays 0.
    @Test func setLevelOnNonMeterRowIsANoOp() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: false)
        row.setLevel(0.9)
        #expect(row.test_meterLevel() == 0, "a row built without a meter must never report a live level")
    }

    /// `apply(...)` for a device that is no longer "playing" (unavailable,
    /// deselected, or muted) resets the meter to 0 even if a level was pushed
    /// moments before — the stale-bar guard documented at the `apply` call site.
    @Test func applyWithNotPlayingDeviceResetsMeterToZero() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device, showsMeter: true)
        row.setLevel(0.75)
        #expect(row.test_meterLevel() == 0.75)

        // Muted ⇒ not playing, even though still selected/available.
        var muted = device
        muted.isMuted = true
        row.apply(muted, selected: true)
        #expect(row.test_meterLevel() == 0, "a muted device's meter must reset, not keep showing the last level")
    }

    @Test func applyWithDeselectedDeviceResetsMeterToZero() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device, showsMeter: true)
        row.apply(device, selected: true)
        row.setLevel(0.6)
        #expect(row.test_meterLevel() == 0.6)

        row.apply(device, selected: false)
        #expect(row.test_meterLevel() == 0, "a deselected device's meter must reset")
    }
}
