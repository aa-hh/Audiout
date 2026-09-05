import Testing
import AppKit
import AudioutCore
@testable import AudioutSharedUI

/// Row-focused tests for the connection **halo ring** (Warm Signal v3 §3.2) +
/// the sublabel precedence ladder: the four `ConnectionState` ring renderings
/// (`test_statusKind`/`test_ringForm`/`test_statusText`), the ring's per-state
/// FORM (dashed connecting vs solid connected/failed), the per-state hues
/// (`ring` connecting, `rim` connected, `failure`) and heavier failed stroke, the VoiceOver
/// spoken equivalent per state, the name-click-toggles-enabled wiring
/// (`test_clickName`) through the checkbox, the routing sublabel composed from
/// `selected` + `routedAppNames`, and that a repeated `apply` cleanly
/// re-derives the ring rather than leaving a stale state.
// `@MainActor` is load-bearing, not decoration: this suite builds and drives
// AppKit views, and every `NSView`-family API is main-actor-only. XCTest ran
// each test method on the main thread, so the annotation was never needed;
// swift-testing schedules non-isolated `@Test` bodies on the cooperative
// pool, where the same calls trip AppKit's "modifications to layout engine
// from a background thread" exception and take the whole process down
// (observed in `AppRowViewTests` during this migration). Do not remove it.
@MainActor
@Suite struct DeviceRowConnectionStateTests {

    private func makeDevice(connectionState: ConnectionState = .off) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod, connectionState: connectionState)
    }

    // MARK: Four states → four ring renderings (+ failed-only sublabel)

    @Test func offShowsNoRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        #expect(row.test_statusKind == .none)
        #expect(row.test_ringForm == .none, "the ring is hidden when .off")
        #expect(row.test_statusText == nil)
    }

    @Test func connectingShowsConnectingRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        #expect(row.test_statusKind == .connecting)
        #expect(row.test_ringForm == .connecting)
        #expect(row.test_statusText == nil, "connecting is single-line (no sublabel)")
    }

    @Test func reconnectingShowsConnectingRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        #expect(row.test_statusKind == .connecting)
        #expect(row.test_ringForm == .connecting, "reconnecting shares the connecting (pending) ring")
        #expect(row.test_statusText == nil, "reconnecting is single-line (no sublabel)")
    }

    @Test func connectedShowsConnectedRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        #expect(row.test_statusKind == .connected)
        #expect(row.test_ringForm == .connected)
        #expect(row.test_statusText == nil, "connected is single-line (no sublabel)")
    }

    @Test func failedShowsFailedRingAndSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        #expect(row.test_statusKind == .failed)
        #expect(row.test_ringForm == .failed)
        #expect(row.test_statusText == "Couldn't connect", "failed is the only two-line row")
    }

    // MARK: Ring FORM — dashed (pending) vs solid (spec §3.2)
    //
    // FORM carries state, not just color: connecting is DASHED so the pending
    // signal survives Reduce Motion (static dashed); connected and failed are
    // SOLID. This is the resolution of the blocking Reduce-Motion collapse (§8.2).

    @Test func connectingRingIsDashed() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        #expect(row.test_ringIsDashed, "the connecting ring's FORM is dashed (incomplete)")
    }

    @Test func reconnectingRingIsDashed() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        #expect(row.test_ringIsDashed, "reconnecting shares the dashed pending form")
    }

    @Test func connectedRingIsSolid() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        #expect(!row.test_ringIsDashed, "the connected ring is solid, not dashed")
    }

    @Test func failedRingIsSolid() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .vanished))))
        #expect(!row.test_ringIsDashed, "the failed ring is solid, not dashed")
    }

    // MARK: Ring HUE + weight — `ring` / `rim` vs failure-exclusive red (§3.2/R8)
    //
    // Ring colors are stamped as resolved `CGColor`s (the dynamic token resolved
    // against the effective appearance), so they're compared by resolved sRGB
    // components — not by identity against the dynamic token object.

    /// Assert two colors resolve to the same sRGB components.
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

    @Test func connectingRingIsRingAndConnectedRingIsRim() {
        // The connecting form now carries colour as well as dash.
        let connecting = DeviceRowView(device: makeDevice(connectionState: .connecting))
        let connected = DeviceRowView(device: makeDevice(connectionState: .connected))
        assertSameHue(connecting.test_ringStrokeColor, Tokens.Color.ring,
                      "the connecting ring is the steel-blue ring token")
        assertSameHue(connected.test_ringStrokeColor, Tokens.Color.rim,
                      "the connected ring is the cool rim")
        let a = connecting.test_ringStrokeColor?.usingColorSpace(.sRGB)
        let b = connected.test_ringStrokeColor?.usingColorSpace(.sRGB)
        #expect(a?.blueComponent != b?.blueComponent, "connecting ≠ connected")
    }

    @Test func connectedRingUsesRimToken() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        assertSameHue(row.test_ringStrokeColor, Tokens.Color.rim,
                      "the connected ring is the cool rim")
    }

    @Test func failedRingUsesTheFailureHueNotRim() {
        let failed = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        let connected = DeviceRowView(device: makeDevice(connectionState: .connected))
        assertSameHue(failed.test_ringStrokeColor, Tokens.Color.failure,
                      "the failed ring is the failure-exclusive red")
        // And it must be a DIFFERENT hue from the connected ring.
        let f = failed.test_ringStrokeColor?.usingColorSpace(.sRGB)
        let c = connected.test_ringStrokeColor?.usingColorSpace(.sRGB)
        #expect(f?.redComponent != c?.redComponent, "failed red ≠ the connected rim")
    }

    @Test func failedRingIsHeavierThanConnectedRing() {
        let connected = DeviceRowView(device: makeDevice(connectionState: .connected))
        let failed = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        #expect(connected.test_ringLineWidth == PopoverColumnGrid.haloRingConnectedStroke)
        #expect(failed.test_ringLineWidth == PopoverColumnGrid.haloRingFailedStroke)
        #expect(failed.test_ringLineWidth > connected.test_ringLineWidth,
                "the failed ring carries redundant extra weight so it wins the scan")
    }

    @Test func failedSublabelUsesTheFailureHue() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        assertSameHue(row.test_statusColor, Tokens.Color.failure,
                      "the 'Couldn't connect' sublabel is failure-red, paired with the failed ring (R8)")
    }

    // MARK: VoiceOver — every ring state has a spoken equivalent (spec §4.8)

    @Test func accessibilityLabelSpeaksConnectingState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: true)
        #expect(row.test_accessibilityLabel?.hasSuffix(", connecting") == true,
                "the connecting ring speaks 'connecting'")
    }

    @Test func accessibilityLabelSpeaksReconnectingState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        row.apply(makeDevice(connectionState: .reconnecting), selected: true)
        #expect(row.test_accessibilityLabel?.hasSuffix(", reconnecting") == true,
                "the reconnecting ring speaks 'reconnecting'")
    }

    @Test func accessibilityLabelSpeaksConnectedState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        row.apply(makeDevice(connectionState: .connected), selected: true)
        #expect(row.test_accessibilityLabel?.hasSuffix(", connected") == true,
                "the connected ring speaks 'connected'")
    }

    @Test func accessibilityLabelSpeaksFailedState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))), selected: false)
        #expect(row.test_accessibilityLabel?.hasSuffix(", couldn't connect") == true,
                "the failed ring speaks 'couldn't connect'")
    }

    @Test func accessibilityLabelOmitsClauseWhenOff() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        row.apply(makeDevice(connectionState: .off), selected: false)
        let label = row.test_accessibilityLabel ?? ""
        #expect(!label.contains("connecting"))
        #expect(!label.contains("connected"))
        #expect(!label.contains("couldn't connect"),
                "an unringed (.off) row adds no connection clause")
    }

    // MARK: Breathing pulse — connecting animates, gated on Reduce Motion

    @Test func connectingRingBreathingMatchesReduceMotionSetting() {
        // The pulse only installs when the view is in a window AND Reduce Motion
        // is off; a headless test can't force the OS setting, so this pins the
        // mapping (present iff !reduceMotion) rather than one fixed outcome. The
        // DASHED form (asserted above) is what survives when the pulse is gated.
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(row)
        row.apply(makeDevice(connectionState: .connecting), selected: true)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(row.test_ringIsBreathing == !reduceMotion,
                "the connecting ring breathes iff Reduce Motion is off and it's on screen")
    }

    // MARK: Repeated `apply` cleanly re-derives the ring

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

    @Test func failedUnavailableSelectedRowStaysDeselectable() {
        // Live bug (2026-08-06, the deselect dead-end): the native backend's
        // failure paths pair `.failed` with `isAvailable = false` while the
        // user's selection intent stays true. The checkbox renders that intent
        // (ON) and must stay OPERABLE — enablement is intent-derived
        // (`isAvailable || selected`), because an intent control that shows ON
        // but can never be turned OFF strands the user in the failure episode:
        // every deselect affordance (checkbox hit-test, name click, node click,
        // keyboard/VoiceOver) funnels through this one enabled flag.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                            isAvailable: false,
                            connectionState: .failed(.init(cause: .notResponding)))
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true)
        #expect(row.test_isEnabledOn, "the checkbox renders INTENT: ON while selected, even failed+unavailable")

        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.test_clickName()

        #expect(delegate.toggledFor == "dev-1",
                "the deselect path is live on a failed+unavailable SELECTED row")
        #expect(delegate.toggledOn == false, "…and the click expresses the deselect (OFF)")
    }

    @Test func clickingNameIsNoOpWhenUnavailable() {
        // A merely-UNAVAILABLE device (checkbox disabled) keeps the old
        // behavior: the name-click is a plain no-op — no toggle.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isAvailable: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
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

    // MARK: V1 — the mute mark (filled square while muted, outline otherwise)

    @Test func muteDrawsTheFilledSquareWhenMutedViaApply() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_mutePillIsMutedHue,
                "apply() must land the filled square in the reserved muted hue")
    }

    @Test func muteDrawsTheOutlineSquareWhenUnmutedViaApply() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_muteDrawsRestSymbol, "unmuted reads as the outline square")
    }

    @Test func muteMarkUpdatesInstantlyOnLiveClick() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)
        #expect(row.test_muteDrawsRestSymbol)

        // `test_toggleMute` drives the exact same path a real click does
        // (AppKit's own state flip, then `muteToggled(_:)`'s `updateMuteTint()`)
        // — the mark must update WITHOUT waiting for a host-driven `apply`.
        row.test_toggleMute(true)
        #expect(row.test_mutePillIsMutedHue, "a live click swaps the symbol instantly")

        row.test_toggleMute(false)
        #expect(row.test_muteDrawsRestSymbol, "toggling back off reverts the symbol instantly")
    }

    // MARK: V7 — the `%` readout dims with the slider's disabled state

    @Test func readoutDimsToLabelCool2WhenSliderDisabled() {
        // Not controllable ⇒ slider disabled ⇒ readout takes the cool dim ink.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: false)

        #expect(!row.test_isSliderEnabled)
        #expect(row.test_readoutColor == Tokens.Color.labelCool2, "readout dims alongside a disabled slider")
    }

    @Test func readoutIsEmberTextWhenEnabledAndIdle() {
        // `.off`, so the row is not armed: the readout holds a stored level.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_isSliderEnabled)
        assertSameHue(row.test_readoutColor, Tokens.Color.emberText,
                      "an enabled but silent row's readout is emberText")
    }

    @Test func readoutIsGoldTextWhenLive() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                            connectionState: .connected)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        assertSameHue(row.test_readoutColor, Tokens.Color.goldText,
                      "a sounding row's readout is goldText")
    }

    // MARK: R5 — unavailable dims the row-level text

    @Test func unavailableRowDimsTextAndCarriesSublabel() {
        let unavailable = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                                 isAvailable: false)
        let unavailableRow = DeviceRowView(device: unavailable)
        unavailableRow.apply(unavailable, selected: false)
        // The cool dim ink, not `.disabledControlTextColor`: that is black at
        // 24.7% alpha, so it composites to 1.80:1 on this row's ground — under
        // half the 4.5:1 body floor. `labelCool2` is also what this row's own
        // "Unavailable" sublabel already draws in, so the name and the word
        // naming its state speak at one level.
        #expect(unavailableRow.test_nameColor == Tokens.Color.labelCool2,
                "unavailable keeps the row-level text dim, in the cool ink")
        #expect(unavailableRow.test_statusText == "Unavailable",
                "…plus its own sublabel — a distinct negative signature (R5)")
    }

    // MARK: Name ink follows liveness (D1)

    @Test func liveRowNameIsLabelAndIdleRowNameIsLabelCool() {
        let live = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                          connectionState: .connected)
        let liveRow = DeviceRowView(device: live)
        liveRow.apply(live, selected: true)
        #expect(liveRow.test_nameColor == Tokens.Color.label,
                "a sounding row's name is the warm label")

        let idle = Device(id: "dev-2", name: "Other Speaker", kind: .homePod)
        let idleRow = DeviceRowView(device: idle)
        idleRow.apply(idle, selected: true)
        #expect(idleRow.test_nameColor == Tokens.Color.labelCool,
                "a silent row's name is the cool labelCool")
    }

    // MARK: A5 — slider stays live while muted (mute ≠ frozen volume)

    @Test func sliderStaysEnabledWhileMuted() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        #expect(row.test_isSliderEnabled, "a muted device's slider stays draggable")
    }

    // MARK: P1-9 — a non-mouse slider change never wedges the drag flag

    @Test func keyboardShapedSliderChangeNeverWedgesTheDragFlag() {
        // `test_fireSliderAction` fires the slider's real target/action with a
        // nil `NSApp.currentEvent` — the keyboard/scroll/AX-shaped path, which
        // must never set `isDraggingSlider`. Before the fix, ANY change set the
        // flag unconditionally and only a coincident `.leftMouseUp` cleared it,
        // so this left the row permanently ignoring model pushes.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        row.test_fireSliderAction(settingValueTo: 30)

        var updated = device
        updated.volume = 55
        row.apply(updated, selected: true, controllable: true)

        #expect(row.test_sliderValue == 55,
                "a non-mouse change must not wedge isDraggingSlider and block the model push")
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

    /// `showsMeter: false` (the mixer window default) makes
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
