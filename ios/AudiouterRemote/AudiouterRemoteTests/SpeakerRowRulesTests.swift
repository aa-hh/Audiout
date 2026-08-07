// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
import SwiftUI
import AudiouterProtocol
@testable import AudiouterRemote

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

    private func makeDevice(
        id: String = "d1",
        isAvailable: Bool = true,
        isSelected: Bool = false,
        isMainOutMember: Bool = false,
        isMuted: Bool = false,
        connectionState: String = "connected"
    ) -> DeviceState {
        DeviceState(
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

    @MainActor
    @Test func zzDebugDump() {
        let row = Mirror(reflecting: MainOutRow(masterVolume: 40, isMuted: false, session: DemoMacSession()))
        let rowDesc = row.children.map { "\($0.label ?? "nil")::\(type(of: $0.value))" }.joined(separator: " | ")
        let sv = Mirror(reflecting: SpeakersView(session: DemoMacSession()))
        let svDesc = sv.children.map { "\($0.label ?? "nil")::\(type(of: $0.value))" }.joined(separator: " | ")
        #expect(Bool(false), "ROW[\(rowDesc)] SPEAKERS[\(svDesc)]")
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
    @Test func muteNeverFreezesTheLevel() {
        #expect(DeviceRowView.isControllable(makeDevice(isSelected: true, isMuted: true), appRoutes: []))
    }

    @MainActor
    @Test func groupMembershipAloneDoesNotMakeADeviceControllable() {
        // `isMainOutMember` is not part of the Mac's rule: a member of a
        // group-targeted Main Out that isn't also selected comes out disabled.
        #expect(!DeviceRowView.isControllable(
            makeDevice(isSelected: false, isMainOutMember: true), appRoutes: []))
    }

    // MARK: - Device row: a disabled control says why

    @MainActor
    @Test func aDisabledControlSpeaksItsReason() {
        // The Mac puts the reason in the row's own composed label; the phone
        // has no row label, so the two disabled controls carry it. An enabled
        // control adds nothing.
        #expect(DeviceRowView.disabledReason(
            for: makeDevice(isSelected: true), controllable: true) == nil)
        #expect(DeviceRowView.disabledReason(
            for: makeDevice(), controllable: false) == "not selected for Main Out")
        #expect(DeviceRowView.disabledReason(
            for: makeDevice(isAvailable: false), controllable: false) == "unavailable")
    }
}
