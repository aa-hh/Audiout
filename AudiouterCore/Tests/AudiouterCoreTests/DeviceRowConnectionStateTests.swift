import XCTest
import AudiouterCore
@testable import AudiouterSharedUI

/// Row-focused tests for the connection **halo ring** (Warm Signal v3 §3.2) +
/// the sublabel precedence ladder: the four `ConnectionState` ring renderings
/// (`test_statusKind`/`test_ringForm`/`test_statusText`), the ring's per-state
/// FORM (dashed connecting vs solid connected/failed), the failure-exclusive
/// hues (`ringConnected` vs `failure`) and heavier failed stroke, the VoiceOver
/// spoken equivalent per state, the name-click-toggles-enabled wiring
/// (`test_clickName`) through the checkbox, the routing sublabel composed from
/// `selected` + `routedAppNames`, and that a repeated `apply` cleanly
/// re-derives the ring rather than leaving a stale state.
final class DeviceRowConnectionStateTests: XCTestCase {

    private func makeDevice(connectionState: ConnectionState = .off) -> Device {
        Device(id: "dev-1", name: "Test Speaker", kind: .homePod, connectionState: connectionState)
    }

    // MARK: Four states → four ring renderings (+ failed-only sublabel)

    func testOffShowsNoRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        XCTAssertEqual(row.test_statusKind, .none)
        XCTAssertEqual(row.test_ringForm, .none, "the ring is hidden when .off")
        XCTAssertNil(row.test_statusText)
    }

    func testConnectingShowsConnectingRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        XCTAssertEqual(row.test_statusKind, .connecting)
        XCTAssertEqual(row.test_ringForm, .connecting)
        XCTAssertNil(row.test_statusText, "connecting is single-line (no sublabel)")
    }

    func testReconnectingShowsConnectingRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        XCTAssertEqual(row.test_statusKind, .connecting)
        XCTAssertEqual(row.test_ringForm, .connecting, "reconnecting shares the connecting (pending) ring")
        XCTAssertNil(row.test_statusText, "reconnecting is single-line (no sublabel)")
    }

    func testConnectedShowsConnectedRingAndNoSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        XCTAssertEqual(row.test_statusKind, .connected)
        XCTAssertEqual(row.test_ringForm, .connected)
        XCTAssertNil(row.test_statusText, "connected is single-line (no sublabel)")
    }

    func testFailedShowsFailedRingAndSublabel() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        XCTAssertEqual(row.test_statusKind, .failed)
        XCTAssertEqual(row.test_ringForm, .failed)
        XCTAssertEqual(row.test_statusText, "Couldn't connect", "failed is the only two-line row")
    }

    // MARK: Ring FORM — dashed (pending) vs solid (spec §3.2)
    //
    // FORM carries state, not just color: connecting is DASHED so the pending
    // signal survives Reduce Motion (static dashed); connected and failed are
    // SOLID. This is the resolution of the blocking Reduce-Motion collapse (§8.2).

    func testConnectingRingIsDashed() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        XCTAssertTrue(row.test_ringIsDashed, "the connecting ring's FORM is dashed (incomplete)")
    }

    func testReconnectingRingIsDashed() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        XCTAssertTrue(row.test_ringIsDashed, "reconnecting shares the dashed pending form")
    }

    func testConnectedRingIsSolid() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        XCTAssertFalse(row.test_ringIsDashed, "the connected ring is solid, not dashed")
    }

    func testFailedRingIsSolid() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .vanished))))
        XCTAssertFalse(row.test_ringIsDashed, "the failed ring is solid, not dashed")
    }

    // MARK: Ring HUE + weight — `ringConnected` vs failure-exclusive red (§3.2/R8)
    //
    // Ring colors are stamped as resolved `CGColor`s (the dynamic token resolved
    // against the effective appearance), so they're compared by resolved sRGB
    // components — not by identity against the dynamic token object.

    /// Assert two colors resolve to the same sRGB components.
    private func assertSameHue(_ a: NSColor?, _ b: NSColor?, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else {
            return XCTFail("nil color: \(message)", file: file, line: line)
        }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01, message, file: file, line: line)
    }

    func testConnectingAndConnectedRingsShareTheSameHue() {
        // "Form, not color, carries pending" (spec §3.2): both use `ringConnected`.
        let connecting = DeviceRowView(device: makeDevice(connectionState: .connecting))
        let connected = DeviceRowView(device: makeDevice(connectionState: .connected))
        assertSameHue(connecting.test_ringStrokeColor, connected.test_ringStrokeColor,
                      "connecting and connected rings share the ringConnected hue")
    }

    func testConnectedRingUsesRingConnectedToken() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        assertSameHue(row.test_ringStrokeColor, Tokens.Color.ringConnected,
                      "the connected ring is the ringConnected warm-grey")
    }

    func testFailedRingUsesTheFailureHueNotRingConnected() {
        let failed = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        let connected = DeviceRowView(device: makeDevice(connectionState: .connected))
        assertSameHue(failed.test_ringStrokeColor, Tokens.Color.failure,
                      "the failed ring is the failure-exclusive red")
        // And it must be a DIFFERENT hue from the connected ring.
        let f = failed.test_ringStrokeColor?.usingColorSpace(.sRGB)
        let c = connected.test_ringStrokeColor?.usingColorSpace(.sRGB)
        XCTAssertNotEqual(f?.redComponent, c?.redComponent, "failed red ≠ connected warm-grey")
    }

    func testFailedRingIsHeavierThanConnectedRing() {
        let connected = DeviceRowView(device: makeDevice(connectionState: .connected))
        let failed = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        XCTAssertEqual(connected.test_ringLineWidth, PopoverColumnGrid.haloRingConnectedStroke)
        XCTAssertEqual(failed.test_ringLineWidth, PopoverColumnGrid.haloRingFailedStroke)
        XCTAssertGreaterThan(failed.test_ringLineWidth, connected.test_ringLineWidth,
                             "the failed ring carries redundant extra weight so it wins the scan")
    }

    func testFailedSublabelUsesTheFailureHue() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        assertSameHue(row.test_statusColor, Tokens.Color.failure,
                      "the 'Couldn't connect' sublabel is failure-red, paired with the failed ring (R8)")
    }

    // MARK: VoiceOver — every ring state has a spoken equivalent (spec §4.8)

    func testAccessibilityLabelSpeaksConnectingState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: true)
        XCTAssertEqual(row.test_accessibilityLabel?.hasSuffix(", connecting"), true,
                       "the connecting ring speaks 'connecting'")
    }

    func testAccessibilityLabelSpeaksReconnectingState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .reconnecting))
        row.apply(makeDevice(connectionState: .reconnecting), selected: true)
        XCTAssertEqual(row.test_accessibilityLabel?.hasSuffix(", reconnecting"), true,
                       "the reconnecting ring speaks 'reconnecting'")
    }

    func testAccessibilityLabelSpeaksConnectedState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connected))
        row.apply(makeDevice(connectionState: .connected), selected: true)
        XCTAssertEqual(row.test_accessibilityLabel?.hasSuffix(", connected"), true,
                       "the connected ring speaks 'connected'")
    }

    func testAccessibilityLabelSpeaksFailedState() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .notResponding))))
        row.apply(makeDevice(connectionState: .failed(.init(cause: .notResponding))), selected: false)
        XCTAssertEqual(row.test_accessibilityLabel?.hasSuffix(", couldn't connect"), true,
                       "the failed ring speaks 'couldn't connect'")
    }

    func testAccessibilityLabelOmitsClauseWhenOff() {
        let row = DeviceRowView(device: makeDevice(connectionState: .off))
        row.apply(makeDevice(connectionState: .off), selected: false)
        let label = row.test_accessibilityLabel ?? ""
        XCTAssertFalse(label.contains("connecting"))
        XCTAssertFalse(label.contains("connected"))
        XCTAssertFalse(label.contains("couldn't connect"),
                       "an unringed (.off) row adds no connection clause")
    }

    // MARK: Breathing pulse — connecting animates, gated on Reduce Motion

    func testConnectingRingBreathingMatchesReduceMotionSetting() {
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
        XCTAssertEqual(row.test_ringIsBreathing, !reduceMotion,
                       "the connecting ring breathes iff Reduce Motion is off and it's on screen")
    }

    // MARK: Repeated `apply` cleanly re-derives the ring

    func testRepeatedApplyReDerivesWhenLeavingConnecting() {
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        XCTAssertEqual(row.test_statusKind, .connecting)

        row.apply(makeDevice(connectionState: .connected), selected: true)
        XCTAssertEqual(row.test_statusKind, .connected)
        // Selected + no routed apps → routing sublabel is the bare "System" token
        // (a selected device is always in the routing set). The badge, not the
        // sublabel, is what this test exercises re-deriving.
        XCTAssertEqual(row.test_statusText, "System")
    }

    func testRepeatedApplyClearsSublabelWhenLeavingFailed() {
        let row = DeviceRowView(device: makeDevice(connectionState: .failed(.init(cause: .vanished))))
        XCTAssertEqual(row.test_statusKind, .failed)
        XCTAssertEqual(row.test_statusText, "Couldn't connect")

        row.apply(makeDevice(connectionState: .off), selected: false)
        XCTAssertEqual(row.test_statusKind, .none)
        XCTAssertNil(row.test_statusText, "the failed sublabel cleared on leaving .failed")
    }

    func testSameStateReappliedStaysConsistent() {
        // A re-render for an unrelated reason (e.g. a volume echo) while the
        // state is unchanged must leave the badge/sublabel consistent.
        let row = DeviceRowView(device: makeDevice(connectionState: .connecting))
        row.apply(makeDevice(connectionState: .connecting), selected: false)
        XCTAssertEqual(row.test_statusKind, .connecting)
        XCTAssertNil(row.test_statusText)
    }

    // MARK: Routing sublabel precedence ladder (2026-07-17)
    //
    // failed "Couldn't connect" > "Unavailable" > routing line ("System" +
    // bypassed app names joined by " · ") > no sublabel. Composed from
    // `selected` (the "System" token) + `routedAppNames` (Wiring-supplied).

    func testSourceLineIsSystemOnlyWhenSelectedWithNoRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, routedAppNames: [])
        XCTAssertEqual(row.test_statusText, "System")
    }

    func testSourceLineIsSystemPlusAppsWhenSelectedWithRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true, routedAppNames: ["Music", "Safari"])
        XCTAssertEqual(row.test_statusText, "System · Music · Safari",
                       "System always leads, tokens joined by ' · '")
    }

    func testSourceLineIsBareAppNamesWhenNotSelectedWithRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Spotify"])
        XCTAssertEqual(row.test_statusText, "Spotify",
                       "not selected: no 'System' token, just the bypassed app(s)")
    }

    func testSourceLineIsHiddenWhenNotSelectedWithNoRoutedApps() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: [])
        XCTAssertNil(row.test_statusText, "empty routing set: no sublabel, single-line row")
    }

    func testSourceLineShowsUnavailableWhenDeviceUnreachable() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isAvailable: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, routedAppNames: ["Music"])
        XCTAssertEqual(row.test_statusText, "Unavailable",
                       "unavailable wins over the routing line even with a non-empty routing set")
    }

    func testFailedTakesPrecedenceOverRoutingAndUnavailable() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                            isAvailable: false, connectionState: .failed(.init(cause: .notResponding)))
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, routedAppNames: ["Music", "Safari"])
        XCTAssertEqual(row.test_statusText, "Couldn't connect",
                       "failed is highest precedence, even over unavailable + a non-empty routing set")
    }

    func testSourceLinePreservesRoutedAppNameOrder() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Zebra App", "Alpha App"])
        XCTAssertEqual(row.test_statusText, "Zebra App · Alpha App",
                       "the view doesn't re-sort — it renders routedAppNames in the given order")
    }

    // MARK: Live-streaming precedence (T9 — `liveAppNames` vs `routedAppNames`)
    //
    // `liveAppNames` (CONFIRMED currently streaming, `BackendEvent.routedApps`)
    // takes precedence over `routedAppNames` (routing INTENT/config) in the
    // routing line whenever it's non-empty; an empty `liveAppNames` falls back
    // to the intent-based label so a pending redirect isn't left blank.

    func testLiveAppNamesTakePrecedenceOverRoutedAppNamesWhenNonEmpty() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false,
                  routedAppNames: ["Spotify"], liveAppNames: ["Music"])
        XCTAssertEqual(row.test_statusText, "Music",
                       "the confirmed live set wins over the merely-configured intent set")
    }

    func testEmptyLiveAppNamesFallsBackToRoutedAppNames() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false,
                  routedAppNames: ["Spotify"], liveAppNames: [])
        XCTAssertEqual(row.test_statusText, "Spotify",
                       "nothing confirmed streaming yet: falls back to the intent-based label")
    }

    func testLiveAppNamesStillLeadWithSystemTokenWhenSelected() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: true,
                  routedAppNames: ["Spotify"], liveAppNames: ["Music", "Safari"])
        XCTAssertEqual(row.test_statusText, "System · Music · Safari",
                       "'System' still leads off `selected`; the live set replaces the app tokens")
    }

    func testClearingLiveAppNamesOnReapplyRevertsToRoutedAppNames() {
        let row = DeviceRowView(device: makeDevice())
        row.apply(makeDevice(), selected: false, routedAppNames: ["Spotify"], liveAppNames: ["Music"])
        XCTAssertEqual(row.test_statusText, "Music")

        // The live mapping cleared (e.g. capture stopped) — a repeated apply with
        // an empty liveAppNames must revert to the intent-based label, not go
        // blank or keep showing the stale confirmed name.
        row.apply(makeDevice(), selected: false, routedAppNames: ["Spotify"], liveAppNames: [])
        XCTAssertEqual(row.test_statusText, "Spotify")
    }

    func test_sourceTextHookReportsLivePrecedence() {
        let row = DeviceRowView(device: makeDevice())
        XCTAssertEqual(row.test_sourceText(routedAppNames: ["Spotify"], liveAppNames: ["Music"]), "Music")
        XCTAssertEqual(row.test_sourceText(routedAppNames: ["Spotify"]), "Spotify",
                       "liveAppNames defaults to empty for back-compat callers")
    }

    // MARK: Name-click toggles the checkbox (same delegate path)

    private final class RecordingDelegate: DeviceRowView.Delegate {
        var toggledFor: String?
        var toggledOn: Bool?
        var blockedExplanationRequests = 0
        func deviceRow(_ row: DeviceRowView, didSetVolume volume: Int, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleMute muted: Bool, for id: String) {}
        func deviceRow(_ row: DeviceRowView, didToggleEnabled on: Bool, for id: String) {
            toggledFor = id
            toggledOn = on
        }
        func deviceRowDidRequestBlockedExplanation(_ row: DeviceRowView) {
            blockedExplanationRequests += 1
        }
    }

    func testClickingNameTogglesEnabledOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)   // checkbox OFF, enabled
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertEqual(delegate.toggledFor, "dev-1")
        XCTAssertEqual(delegate.toggledOn, true, "OFF → click → ON via the checkbox's delegate path")
        XCTAssertTrue(row.test_isEnabledOn, "the checkbox flipped ON")
    }

    func testClickingNameOnFailedDeviceRetriesByEnabling() {
        // A failed device's toggle rests OFF; clicking the name re-enables it
        // (= retry) — the intended behaviour.
        let device = makeDevice(connectionState: .failed(.init(cause: .refusedOrBusy)))
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertEqual(delegate.toggledOn, true, "clicking a failed row's name retries (enables)")
    }

    func testClickingNameOnBlockedRowRequestsRefusalExplanation() {
        // S4 (spec §4.6 "a click anywhere on the row body / name / node"): the
        // local-mix block disables the checkbox, so the name-click can't toggle —
        // instead it requests the in-place refusal note through the SAME delegate
        // path the row-body mouseDown uses. It must never toggle membership.
        let device = Device(id: "local", name: "This Mac", kind: .localMac)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, blocked: true, blockReason: "blocked")
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertNil(delegate.toggledFor, "a blocked row's name-click never toggles membership")
        XCTAssertEqual(delegate.blockedExplanationRequests, 1,
                       "…it surfaces the refusal explanation instead (S4)")
    }

    func testClickingNameIsNoOpWhenUnavailable() {
        // A merely-UNAVAILABLE device (checkbox disabled, not blocked) keeps the
        // old behavior: the name-click is a plain no-op — no toggle, no note.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isAvailable: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_clickName()

        XCTAssertNil(delegate.toggledFor, "name-click is a no-op when the toggle is disabled")
        XCTAssertEqual(delegate.blockedExplanationRequests, 0,
                       "unavailable is not blocked — no refusal note request")
    }

    // MARK: Checkbox replaces the switch — old toggle test hooks still pass through it

    func testToggleEnabledHookDrivesDelegateThroughCheckbox() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        let delegate = RecordingDelegate()
        row.delegate = delegate

        row.test_toggleEnabled(true)

        XCTAssertEqual(delegate.toggledFor, "dev-1")
        XCTAssertEqual(delegate.toggledOn, true)
    }

    func testIsEnabledOnReflectsSelectedStateViaCheckbox() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)

        row.apply(device, selected: true)
        XCTAssertTrue(row.test_isEnabledOn, "checkbox reads ON when selected")

        row.apply(device, selected: false)
        XCTAssertFalse(row.test_isEnabledOn, "checkbox reads OFF when not selected")
    }

    func testShowsToggleReflectsCheckboxVisibility() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let topLevelRow = DeviceRowView(device: device, showsToggle: true)
        XCTAssertTrue(topLevelRow.test_showsToggle, "Selected-Devices rows show the checkbox")

        let memberRow = DeviceRowView(device: device, showsToggle: false)
        XCTAssertFalse(memberRow.test_showsToggle, "group-member rows hide the checkbox")
    }

    // MARK: `controllable` — slider/mute enable independent of `selected` (Q2)

    /// A redirect-only device: `selected: false, controllable: true` — the
    /// checkbox stays OFF and there is NO "System" token in the sublabel, but the
    /// slider/mute must be enabled.
    func testRedirectOnlyDeviceHasSliderMuteEnabledCheckboxOffNoSystemToken() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: true, routedAppNames: ["Music"])

        XCTAssertFalse(row.test_isEnabledOn, "checkbox stays OFF — this device isn't in Selected Devices")
        XCTAssertEqual(row.test_statusText, "Music",
                       "no 'System' token: the routing line is bare app names, keyed off `selected`")
    }

    /// `selected: true, controllable: false` documents the back-compat footgun:
    /// omitting `controllable` for an otherwise-selected device disables its
    /// slider/mute even though the checkbox is ON.
    func testSelectedWithoutControllableDisablesSliderMuteButKeepsCheckboxOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: false)

        XCTAssertTrue(row.test_isEnabledOn, "checkbox reflects `selected`, independent of `controllable`")
        XCTAssertEqual(row.test_statusText, "System", "the 'System' token is keyed off `selected`, not `controllable`")
    }

    /// A normal selected + controllable device: checkbox ON, slider/mute
    /// enabled, "System" token present — the ordinary in-Selected-Devices case.
    func testSelectedAndControllableShowsSystemTokenWithCheckboxOn() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true, routedAppNames: ["Safari"])

        XCTAssertTrue(row.test_isEnabledOn)
        XCTAssertEqual(row.test_statusText, "System · Safari")
    }

    // MARK: V1 — mute tint (accent while muted, secondary otherwise)

    func testMuteTintIsAccentWhenMutedViaApply() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        XCTAssertEqual(row.test_muteTintColor, .controlAccentColor, "apply() lands the accent tint while muted")
    }

    func testMuteTintIsSecondaryWhenUnmutedViaApply() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        XCTAssertEqual(row.test_muteTintColor, .secondaryLabelColor, "unmuted reads as the neutral secondary tint")
    }

    func testMuteTintUpdatesInstantlyOnLiveClick() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: false)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)
        XCTAssertEqual(row.test_muteTintColor, .secondaryLabelColor)

        // `test_toggleMute` drives the exact same path a real click does
        // (AppKit's own state flip, then `muteToggled(_:)`'s `updateMuteTint()`)
        // — the tint must update WITHOUT waiting for a host-driven `apply`.
        row.test_toggleMute(true)
        XCTAssertEqual(row.test_muteTintColor, .controlAccentColor, "a live click updates the tint instantly")

        row.test_toggleMute(false)
        XCTAssertEqual(row.test_muteTintColor, .secondaryLabelColor, "toggling back off reverts the tint instantly")
    }

    // MARK: V7 — the `%` readout dims with the slider's disabled state

    func testReadoutDimsWhenSliderDisabled() {
        // Not controllable ⇒ slider disabled ⇒ readout should read tertiary.
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, controllable: false)

        XCTAssertFalse(row.test_isSliderEnabled)
        XCTAssertEqual(row.test_readoutColor, .tertiaryLabelColor, "readout dims alongside a disabled slider")
    }

    func testReadoutIsSecondaryWhenSliderEnabled() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        XCTAssertTrue(row.test_isSliderEnabled)
        XCTAssertEqual(row.test_readoutColor, .secondaryLabelColor, "readout is the normal secondary color when enabled")
    }

    // MARK: S4 (spec §4.6/R5) — blocked keeps NORMAL text, distinct from unavailable

    func testBlockedRowKeepsNormalTextDistinctFromUnavailable() {
        // Supersedes the old V12 name-grey: a BLOCKED row's signature is the
        // greyed bus node + body-click refusal note, with the name at the NORMAL
        // (non-member) treatment. Only UNAVAILABLE dims at the row level — the
        // two "can't" states must never look alike (R5).
        let blocked = Device(id: "local", name: "This Mac", kind: .localMac)
        let blockedRow = DeviceRowView(device: blocked)
        blockedRow.apply(blocked, selected: false, blocked: true, blockReason: "blocked")
        XCTAssertEqual(blockedRow.test_nameColor, .secondaryLabelColor,
                       "a blocked row's name stays at the normal non-member treatment (S4)")
        XCTAssertNil(blockedRow.test_statusText, "…and it carries no sublabel")

        let unavailable = Device(id: "dev-1", name: "Test Speaker", kind: .homePod,
                                 isAvailable: false)
        let unavailableRow = DeviceRowView(device: unavailable)
        unavailableRow.apply(unavailable, selected: false)
        XCTAssertEqual(unavailableRow.test_nameColor, .disabledControlTextColor,
                       "unavailable keeps the row-level text dim")
        XCTAssertEqual(unavailableRow.test_statusText, "Unavailable",
                       "…plus its own sublabel — a distinct negative signature (R5)")
    }

    // MARK: S4 — the blocked row's VoiceOver hint carries the refusal reason

    func testBlockedRowAccessibilityHintCarriesRefusalReason() {
        let device = Device(id: "local", name: "This Mac", kind: .localMac)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, blocked: true,
                  blockReason: "This Mac can't join a mixed set")

        XCTAssertEqual(row.test_accessibilityHint, "This Mac can't join a mixed set",
                       "the refusal reason is spoken as the row's hint (S4 — every visual "
                       + "state ships its VoiceOver equivalent)")

        // Unblocking clears it — the hint never sticks to a normal row.
        row.apply(device, selected: false)
        XCTAssertNil(row.test_accessibilityHint, "a non-blocked repaint clears the hint")
    }

    // MARK: A5 — slider stays live while muted (mute ≠ frozen volume)

    func testSliderStaysEnabledWhileMuted() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod, isMuted: true)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: true, controllable: true)

        XCTAssertTrue(row.test_isSliderEnabled, "a muted device's slider stays draggable")
    }

    // MARK: A1 — selectionDimmed dims the checkbox without disabling it

    func testSelectionDimmedDimsCheckboxButKeepsItInteractive() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false, selectionDimmed: true)

        XCTAssertTrue(row.test_isSelectionDimmed, "the checkbox renders dimmed")
        XCTAssertFalse(row.test_isEnabledOn)

        let delegate = RecordingDelegate()
        row.delegate = delegate
        row.test_toggleEnabled(true)
        XCTAssertEqual(delegate.toggledOn, true, "still fully interactive while dimmed — decision: dim, don't disable")
    }

    func testSelectionNotDimmedByDefault() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)

        XCTAssertFalse(row.test_isSelectionDimmed, "existing callers that omit selectionDimmed are unaffected")
    }

    // MARK: A4 — flashRow(), gated on Reduce Motion

    func testFlashRowMatchesReduceMotionSetting() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device)
        row.apply(device, selected: false)
        XCTAssertFalse(row.test_isFlashing, "no flash before flashRow() is called")

        row.test_flashRow()

        // The guard inside `flashRow()` is `!accessibilityDisplayShouldReduceMotion`
        // — assert the hook's outcome matches that same live system flag, which
        // is exactly the branch under test (no way to force the OS setting from
        // a headless unit test, so this pins the mapping rather than one outcome).
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        XCTAssertEqual(row.test_isFlashing, !reduceMotion,
                       "flashRow() is a no-op under Reduce Motion, and fires otherwise")
    }

    // MARK: Leading VU meter (task T8, extends the T3/T5 shared symbol contract)

    /// `setLevel` on a meter-enabled row reaches the meter and is readable back
    /// via `test_meterLevel`.
    func testSetLevelOnMeterEnabledRowIsReflectedByTestMeterLevel() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: true)
        row.setLevel(0.42)
        XCTAssertEqual(row.test_meterLevel(), 0.42)
    }

    /// `showsMeter: false` (the mixer window/`GroupRowView` default) makes
    /// `setLevel` a no-op — `test_meterLevel` stays 0.
    func testSetLevelOnNonMeterRowIsANoOp() {
        let row = DeviceRowView(device: makeDevice(), showsMeter: false)
        row.setLevel(0.9)
        XCTAssertEqual(row.test_meterLevel(), 0, "a row built without a meter must never report a live level")
    }

    /// `apply(...)` for a device that is no longer "playing" (unavailable,
    /// deselected, or muted) resets the meter to 0 even if a level was pushed
    /// moments before — the stale-bar guard documented at the `apply` call site.
    func testApplyWithNotPlayingDeviceResetsMeterToZero() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device, showsMeter: true)
        row.setLevel(0.75)
        XCTAssertEqual(row.test_meterLevel(), 0.75)

        // Muted ⇒ not playing, even though still selected/available.
        var muted = device
        muted.isMuted = true
        row.apply(muted, selected: true)
        XCTAssertEqual(row.test_meterLevel(), 0, "a muted device's meter must reset, not keep showing the last level")
    }

    func testApplyWithDeselectedDeviceResetsMeterToZero() {
        let device = Device(id: "dev-1", name: "Test Speaker", kind: .homePod)
        let row = DeviceRowView(device: device, showsMeter: true)
        row.apply(device, selected: true)
        row.setLevel(0.6)
        XCTAssertEqual(row.test_meterLevel(), 0.6)

        row.apply(device, selected: false)
        XCTAssertEqual(row.test_meterLevel(), 0, "a deselected device's meter must reset")
    }
}
