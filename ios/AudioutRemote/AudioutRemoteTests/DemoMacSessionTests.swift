// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing
import AudioutProtocol
@testable import AudioutRemote

/// T13 tests: `DemoMacSession`'s in-memory fleet simulation. No network, no
/// `ConnectionController` — every test drives the session's `MacSessionProtocol`
/// methods directly and reads back `session.snapshot`/`session.toasts`.
@Suite struct DemoMacSessionTests {

    private func device(_ snapshot: Snapshot, _ id: String) -> DeviceState {
        snapshot.devices.first { $0.id == id }!
    }

    // MARK: - Identity

    @MainActor
    @Test func isDemoTrueAndConnectionStatusIsLive() {
        let session = DemoMacSession()
        #expect(session.isDemo)
        #expect(session.connectionStatus == .live)
        #expect(session.snapshot != nil)
    }

    // MARK: - Selection floor + auto-swap

    @MainActor
    @Test func selectingAnAirPlayDeviceWhileOnlyLocalIsSelectedAutoSwapsLocalOff() {
        let session = DemoMacSession()
        let before = try! #require(session.snapshot)
        #expect(device(before, "local-mac").isSelected)

        session.setDeviceSelected(id: "demo-homepod", selected: true)

        let after = try! #require(session.snapshot)
        #expect(!device(after, "local-mac").isSelected)
        #expect(device(after, "demo-homepod").isSelected)
        #expect(session.toasts.current?.kind == .autoSwap)
    }

    @MainActor
    @Test func deselectingTheLastDeviceFloorsBackToLocalWithAToast() {
        let session = DemoMacSession()
        session.setDeviceSelected(id: "demo-homepod", selected: true) // auto-swaps local off
        session.toasts.dismiss(session.toasts.current!.id)

        session.setDeviceSelected(id: "demo-homepod", selected: false)

        let after = try! #require(session.snapshot)
        #expect(device(after, "local-mac").isSelected, "selection must never go empty")
        #expect(!device(after, "demo-homepod").isSelected)
        #expect(session.toasts.current?.kind == .autoSwap)
    }

    @MainActor
    @Test func deselectingTheLocalDeviceItselfIsANoOpBounceWithNoToast() {
        let session = DemoMacSession()
        session.setDeviceSelected(id: "local-mac", selected: false)

        let after = try! #require(session.snapshot)
        #expect(device(after, "local-mac").isSelected, "the floor re-adds local; toggling local off is a no-op")
        #expect(session.toasts.current == nil)
    }

    @MainActor
    @Test func addingASecondAirPlayDeviceOnceAlreadyMixedDoesNotAutoSwap() {
        let session = DemoMacSession()
        session.setDeviceSelected(id: "demo-homepod", selected: true) // local sole -> auto-swap
        session.toasts.dismiss(session.toasts.current!.id)

        session.setDeviceSelected(id: "demo-sonos-left", selected: true)

        let after = try! #require(session.snapshot)
        #expect(device(after, "demo-homepod").isSelected)
        #expect(device(after, "demo-sonos-left").isSelected)
        #expect(session.toasts.current == nil, "no further auto-swap once the Mac is already out of the set")
    }

    // MARK: - Main Out master — its own gain stage (volume decoupling)

    @MainActor
    @Test func mainOutMasterIsItsOwnValueAndNeverRewritesMemberLevels() {
        let session = DemoMacSession()
        session.setDeviceSelected(id: "demo-homepod", selected: true)     // volume 40, local auto-swapped off
        session.setDeviceSelected(id: "demo-sonos-left", selected: true)  // volume 55

        session.setMainOutMasterVolume(20, isFinal: false)
        session.setMainOutMasterVolume(80, isFinal: true)

        let after = try! #require(session.snapshot)
        #expect(after.mainOutMasterVolume == 80, "Main is a stored value of its own")
        #expect(device(after, "demo-homepod").volume == 40,
                "moving Main never touches a member's own level")
        #expect(device(after, "demo-sonos-left").volume == 55,
                "moving Main never touches a member's own level")
    }

    @MainActor
    @Test func localRowDrivesMainInPassthrough() {
        let session = DemoMacSession()
        // Out-of-the-box state: Selected Devices = {local-mac} = passthrough,
        // so the Mac's own row IS Main (GroupController.setMemberVolume's one
        // documented exception).
        let macVolumeBefore = device(try! #require(session.snapshot), "local-mac").volume

        session.setDeviceVolume(id: "local-mac", volume: 30, isFinal: true)

        let after = try! #require(session.snapshot)
        #expect(after.mainOutMasterVolume == 30, "in passthrough the Mac's row moves Main")
        #expect(device(after, "local-mac").volume == macVolumeBefore,
                "the Mac's own stored fader survives untouched")
    }

    // MARK: - Mute stash/restore

    @MainActor
    @Test func mutingADeviceStashesItsVolumeAndUnmutingRestoresIt() {
        let session = DemoMacSession()
        let original = device(try! #require(session.snapshot), "demo-homepod").volume // 40

        session.setDeviceMuted(id: "demo-homepod", muted: true)
        #expect(device(try! #require(session.snapshot), "demo-homepod").volume == 0)
        #expect(device(try! #require(session.snapshot), "demo-homepod").isMuted)

        session.setDeviceMuted(id: "demo-homepod", muted: false)
        let restored = device(try! #require(session.snapshot), "demo-homepod")
        #expect(restored.volume == original)
        #expect(!restored.isMuted)
    }

    @MainActor
    @Test func reMutingAnAlreadyMutedDeviceDoesNotOverwriteTheStash() {
        let session = DemoMacSession()
        session.setDeviceMuted(id: "demo-homepod", muted: true)
        session.setDeviceVolume(id: "demo-homepod", volume: 5, isFinal: true) // simulate drift while muted (real UI wouldn't, but the stash must not care)
        session.setDeviceMuted(id: "demo-homepod", muted: true) // re-mute: no edge, must not re-stash 0/5

        session.setDeviceMuted(id: "demo-homepod", muted: false)
        #expect(device(try! #require(session.snapshot), "demo-homepod").volume == 40, "original pre-mute level, not whatever it was set to while muted")
    }

    @MainActor
    @Test func mainOutMuteMutesEveryCurrentMemberTogether() {
        let session = DemoMacSession()
        session.setDeviceSelected(id: "demo-homepod", selected: true)
        session.setDeviceSelected(id: "demo-sonos-left", selected: true)

        session.setMainOutMuted(true)

        let after = try! #require(session.snapshot)
        #expect(device(after, "demo-homepod").isMuted)
        #expect(device(after, "demo-sonos-left").isMuted)
        #expect(after.mainOutMuted)
    }

    // MARK: - Group CRUD

    @MainActor
    @Test func creatingAGroupWithNoMembersIsRefusedWithAToast() {
        let session = DemoMacSession()
        session.createGroup(name: "Empty", memberIDs: [], iconSymbolName: nil)

        #expect(session.toasts.current?.message == "A group needs at least one device.")
        #expect(try! #require(session.snapshot).groups.count == 1, "still just the seeded Living Room group")
    }

    @MainActor
    @Test func creatingAGroupThatDuplicatesAnExistingMemberSetDoesNotAddACopy() {
        let session = DemoMacSession()
        let before = try! #require(session.snapshot).groups.count

        session.createGroup(name: "Duplicate", memberIDs: ["demo-sonos-left", "demo-sonos-right"], iconSymbolName: nil)

        #expect(try! #require(session.snapshot).groups.count == before)
    }

    @MainActor
    @Test func updatingAGroupToEmptyMembershipIsRefused() {
        let session = DemoMacSession()
        let group = try! #require(session.snapshot).groups.first { $0.id == "demo-living-room" }!

        var edited = group
        edited.memberIDs = []
        session.updateGroup(edited)

        #expect(session.toasts.current?.message == "A group needs at least one device.")
        let unchanged = try! #require(session.snapshot).groups.first { $0.id == "demo-living-room" }!
        #expect(!unchanged.memberIDs.isEmpty)
    }

    @MainActor
    @Test func deletingTheActiveGroupFallsMainOutBackToSelectedDevices() {
        let session = DemoMacSession()
        session.setMainOut(MainOutState(kind: "group", groupID: "demo-living-room"))
        #expect(try! #require(session.snapshot).mainOut.kind == "group")
        #expect(try! #require(session.snapshot).activeGroupID == "demo-living-room")

        session.deleteGroup(id: "demo-living-room")

        let after = try! #require(session.snapshot)
        #expect(after.mainOut.kind == "selected")
        #expect(after.activeGroupID == nil)
        #expect(after.groups.isEmpty)
    }

    @MainActor
    @Test func deletingAnInactiveGroupLeavesMainOutAlone() {
        let session = DemoMacSession()
        session.setDeviceSelected(id: "demo-homepod", selected: true)
        #expect(try! #require(session.snapshot).mainOut.kind == "selected")

        session.deleteGroup(id: "demo-living-room")

        #expect(try! #require(session.snapshot).mainOut.kind == "selected")
    }

    @MainActor
    @Test func activatingAGroupAppliesItsRememberedMemberVolumes() {
        let session = DemoMacSession()
        session.setMainOut(MainOutState(kind: "group", groupID: "demo-living-room"))

        let after = try! #require(session.snapshot)
        #expect(device(after, "demo-sonos-left").volume == 55)
        #expect(device(after, "demo-sonos-right").volume == 55)
    }

    // MARK: - Refusal toasts (unknown ids / invalid buffer)

    @MainActor
    @Test func settingMainOutToAnUnknownGroupIsRefusedAndLeavesMainOutUnchanged() {
        let session = DemoMacSession()
        let before = try! #require(session.snapshot).mainOut

        session.setMainOut(MainOutState(kind: "group", groupID: "no-such-group"))

        #expect(session.toasts.current?.message == "Unknown group.")
        #expect(try! #require(session.snapshot).mainOut == before)
    }

    @MainActor
    @Test func routingAnAppToAnUnknownDeviceIsRefused() {
        let session = DemoMacSession()
        session.addAppRoute(bundleID: "com.demo.video", displayName: "Demo Video")

        session.setAppDestination(bundleID: "com.demo.video", kind: "device", deviceID: "no-such-device")

        #expect(session.toasts.current?.message == "Unknown device.")
        let route = try! #require(session.snapshot).appRoutes.first { $0.bundleID == "com.demo.video" }!
        #expect(route.destinationKind == "noRedirect", "the refused change must not have applied")
    }

    @MainActor
    @Test func settingAnInvalidStartBufferIsRefused() {
        let session = DemoMacSession()
        let before = try! #require(session.snapshot).settings.startBufferMs

        session.setStartBufferMs(999)

        #expect(session.toasts.current?.message == "999 ms is not one of the available buffer sizes.")
        #expect(try! #require(session.snapshot).settings.startBufferMs == before)
    }

    @MainActor
    @Test func aValidStartBufferIsApplied() {
        let session = DemoMacSession()
        session.setStartBufferMs(1500)
        #expect(try! #require(session.snapshot).settings.startBufferMs == 1500)
    }

    // MARK: - Apps

    @MainActor
    @Test func seedsTwoFakeRoutedAppsAndOneAddableApp() {
        let session = DemoMacSession()
        let snapshot = try! #require(session.snapshot)
        #expect(snapshot.appRoutes.map(\.displayName).sorted() == ["Demo Browser", "Demo Music"])
        #expect(snapshot.addableApps.map(\.displayName) == ["Demo Video"])
    }

    @MainActor
    @Test func addingThenRemovingAnAppRouteRoundTripsThroughAddableApps() {
        let session = DemoMacSession()
        session.addAppRoute(bundleID: "com.demo.video", displayName: "Demo Video")
        var snapshot = try! #require(session.snapshot)
        #expect(snapshot.appRoutes.contains { $0.bundleID == "com.demo.video" })
        #expect(!snapshot.addableApps.contains { $0.bundleID == "com.demo.video" })

        session.removeAppRoute(bundleID: "com.demo.video")
        snapshot = try! #require(session.snapshot)
        #expect(!snapshot.appRoutes.contains { $0.bundleID == "com.demo.video" })
        #expect(snapshot.addableApps.contains { $0.bundleID == "com.demo.video" })
    }

    // MARK: - Offline device / retry

    @MainActor
    @Test func theSeededOfflineDeviceStartsFailedAndRetryClearsIt() {
        let session = DemoMacSession()
        let before = device(try! #require(session.snapshot), "demo-office")
        #expect(!before.isAvailable)
        #expect(before.connection.state == "failed")
        #expect(before.connection.failureHeadline == "Not on the network")

        session.retryConnection(id: "demo-office")

        let after = device(try! #require(session.snapshot), "demo-office")
        #expect(after.isAvailable)
        #expect(after.connection.state == "off", "available but not selected/routed yet")
    }

    // MARK: - Snapshot consistency after a command burst

    @MainActor
    @Test func snapshotStaysInternallyConsistentAfterAMixedCommandBurst() {
        let session = DemoMacSession()

        session.setDeviceSelected(id: "demo-homepod", selected: true)
        session.setDeviceSelected(id: "demo-sonos-left", selected: true)
        session.setDeviceMuted(id: "demo-homepod", muted: true)
        session.setMainOutMasterVolume(70, isFinal: false)
        session.setMainOutMasterVolume(90, isFinal: true)
        session.createGroup(name: "Burst Group", memberIDs: ["demo-homepod", "demo-sonos-left"], iconSymbolName: "star.fill")
        session.addAppRoute(bundleID: "com.demo.video", displayName: "Demo Video")
        session.setAppDestination(bundleID: "com.demo.video", kind: "device", deviceID: "demo-sonos-left")
        session.setConnectVolume(60, isFinal: true)
        session.setStartBufferMs(2250)
        session.retryConnection(id: "demo-office")

        let snapshot = try! #require(session.snapshot)

        // Main is its own stored value (volume decoupling): the last set
        // sticks, independent of any member's level.
        #expect(snapshot.mainOutMasterVolume == 90)

        // Every device referenced by a group/appRoute must exist in `devices`.
        let deviceIDs = Set(snapshot.devices.map(\.id))
        for group in snapshot.groups {
            for member in group.memberIDs { #expect(deviceIDs.contains(member)) }
        }
        for route in snapshot.appRoutes where route.destinationKind == "device" {
            #expect(deviceIDs.contains(route.deviceID!))
        }

        #expect(snapshot.settings.connectVolume == 60)
        #expect(snapshot.settings.startBufferMs == 2250)
        #expect(snapshot.groups.contains { $0.name == "Burst Group" })
        #expect(device(snapshot, "demo-office").isAvailable)
    }
}
