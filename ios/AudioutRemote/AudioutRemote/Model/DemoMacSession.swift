// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import AudioutProtocol

/// An in-memory simulated Mac, standing in for a real ``RemoteSession`` when
/// no Mac is reachable. Re-implements the visually-significant slice of
/// `GroupController`/`AppRoutingController`/`AppSettings` (AudioutCore,
/// Mac-side) small enough to fit here — selection floor + auto-swap, Main
/// Out as its own stored gain (the volume-decoupling model: `Main × Group ×
/// Device`, so moving Main never rewrites a member's level), mute
/// stash/restore, group CRUD with the delete-while-active Main Out fallback,
/// and the buffer/device-id refusals `CompanionCommandDispatcher` surfaces.
/// No network, no persistence, no real audio.
///
/// **Reachable ONLY by explicit construction.** This type is never a
/// fallback for a failed/absent connection — the "Demo system" row (T17a) is
/// the one call site that ever makes one. Nothing here, in ``RemoteSession``,
/// or in the connection layer constructs a `DemoMacSession` automatically.
///
/// One trap worth naming: the four sliders' `isFinal` flag is honored nowhere
/// in this file, on purpose. On the real Mac, `CompanionCommandDispatcher`
/// never sees `isFinal` either — the ≤20 Hz coalescing happens entirely on
/// the phone side (`RemoteSession`/`CommandSender`) before a command is even
/// sent. A conformer standing in for "the Mac" has nothing to coalesce; every
/// call just applies.
@MainActor
@Observable
final class DemoMacSession: MacSessionProtocol {

    private(set) var snapshot: Snapshot?
    let connectionStatus: MacConnectionState = .live
    let isDemo = true
    let toasts = ToastCenter()

    // MARK: Simulated fleet (mirrors GroupController.Device/ConnectionState)

    private struct DeviceRecord {
        let id: String
        let name: String
        let kind: String
        let iconSymbolName: String
        var isAvailable: Bool
        let supportsAirPlay2: Bool
        let isLocalDevice: Bool
        var volume: Int
        /// Sticky failure card (GroupController.swift's "sticky-failed" rule) —
        /// present only for the fleet's offline fixture until `retryConnection`
        /// clears it.
        var failure: DeviceState.ConnectionInfo?
    }

    /// Mirrors `GroupController.MemberState` — mute is volume-based: muting
    /// stashes the pre-mute volume and zeroes it, unmuting restores the stash.
    private struct MemberMute {
        var explicitMute = false
        var priorVolume: Int?
    }

    private var devices: [DeviceRecord]
    private var selectedDeviceIDs: Set<String>
    private var mainOut: MainOutState
    private var groups: [GroupState]
    private var activeGroupID: String?
    private var appRoutes: [AppRouteState]
    private var addableApps: [Snapshot.AddableApp]
    private var muteState: [String: MemberMute] = [:]
    /// The Main Out master gain — its OWN value, mirroring
    /// `GroupController.mainOutMasterVolume` (never an average of members).
    private var mainOutMasterVolume: Int

    private var connectVolume: Int
    private let connectVolumeMin: Int
    private let connectVolumeMax: Int
    private var startBufferMs: Int
    private let startBufferOptionsMs: [Int]

    init() {
        devices = Self.seedFleet()
        // Out-of-the-box default (GroupController.ensureDefaultSelection):
        // Current Device only, Main Out = Selected Devices ⇒ passthrough.
        // Main seeds from the Mac's system output volume, like the real
        // controller's launch adoption.
        mainOutMasterVolume = 65
        selectedDeviceIDs = ["local-mac"]
        mainOut = MainOutState(kind: "selected")
        groups = [
            GroupState(
                id: "demo-living-room",
                name: "Living Room",
                memberIDs: ["demo-sonos-left", "demo-sonos-right"],
                memberVolumes: ["demo-sonos-left": 55, "demo-sonos-right": 55],
                iconSymbolName: "sofa.fill",
                isMuted: false
            ),
        ]
        appRoutes = [
            AppRouteState(bundleID: "com.demo.music", displayName: "Demo Music",
                          destinationKind: "noRedirect", volume: 100, isRunning: true),
            AppRouteState(bundleID: "com.demo.browser", displayName: "Demo Browser",
                          destinationKind: "noRedirect", volume: 100, isRunning: true),
        ]
        addableApps = [Snapshot.AddableApp(bundleID: "com.demo.video", displayName: "Demo Video")]
        // AppSettings.swift's real defaults, mirrored so the phone's slider
        // ranges/options match what a real Mac would report.
        connectVolume = 35     // AppSettings.defaultConnectVolume
        connectVolumeMin = 5   // AppSettings.minConnectVolume
        connectVolumeMax = 100 // AppSettings.maxConnectVolume
        startBufferMs = 1000   // AppSettings.defaultStartBufferMs
        startBufferOptionsMs = [1000, 1500, 2250] // AppSettings.startBufferOptionsMs
        rebuildSnapshot()
    }

    /// A believable small fleet: this Mac + a HomePod + a stereo Sonos pair
    /// (pre-grouped as "Living Room" above, so the Groups tab isn't empty on
    /// first launch) + one offline fixture so the failure-status UI is
    /// demoable without touching a control.
    private static func seedFleet() -> [DeviceRecord] {
        [
            DeviceRecord(id: "local-mac", name: "This Mac", kind: "localMac",
                         iconSymbolName: "laptopcomputer", isAvailable: true,
                         supportsAirPlay2: false, isLocalDevice: true, volume: 65, failure: nil),
            DeviceRecord(id: "demo-homepod", name: "Kitchen HomePod", kind: "homePod",
                         iconSymbolName: "homepod.fill", isAvailable: true,
                         supportsAirPlay2: true, isLocalDevice: false, volume: 40, failure: nil),
            DeviceRecord(id: "demo-sonos-left", name: "Sonos One (Left)", kind: "sonos",
                         iconSymbolName: "hifispeaker.fill", isAvailable: true,
                         supportsAirPlay2: true, isLocalDevice: false, volume: 55, failure: nil),
            DeviceRecord(id: "demo-sonos-right", name: "Sonos One (Right)", kind: "sonos",
                         iconSymbolName: "hifispeaker.fill", isAvailable: true,
                         supportsAirPlay2: true, isLocalDevice: false, volume: 55, failure: nil),
            // Text mirrors ConnectionFailure.Cause.vanished's real headline/suggestion
            // (Device/ConnectionState.swift) so the demo failure card reads exactly
            // like the live one.
            DeviceRecord(id: "demo-office", name: "Office Speaker", kind: "generic",
                         iconSymbolName: "hifispeaker.fill", isAvailable: false,
                         supportsAirPlay2: true, isLocalDevice: false, volume: 50,
                         failure: DeviceState.ConnectionInfo(
                             state: "failed",
                             failureHeadline: "Not on the network",
                             failureSuggestion: "The speaker is no longer visible on the network. Check that it's powered on and on the same Wi-Fi, then try again."
                         )),
        ]
    }

    // MARK: Devices

    func setDeviceSelected(id: String, selected: Bool) {
        guard let d = devices.first(where: { $0.id == id }) else { return }
        if selected {
            guard !selectedDeviceIDs.contains(id) else { return }
            // Auto-swap: an AirPlay device turning ON while the local device is
            // the sole selected member drops the local device (GroupController
            // .setDeviceSelected).
            var autoSwapped = false
            if !d.isLocalDevice, let local = localDeviceID, selectedDeviceIDs == [local] {
                selectedDeviceIDs.remove(local)
                autoSwapped = true
            }
            selectedDeviceIDs.insert(id)
            if autoSwapped { toasts.show(.autoSwap) }
        } else {
            guard selectedDeviceIDs.contains(id) else { return }
            selectedDeviceIDs.remove(id)
            // Selection floor: never zero-selected — deselecting the last
            // device re-selects the local device.
            var autoSwapped = false
            if selectedDeviceIDs.isEmpty, let local = localDeviceID {
                selectedDeviceIDs.insert(local)
                autoSwapped = !d.isLocalDevice
            }
            if autoSwapped { toasts.show(.autoSwap) }
        }
        rebuildSnapshot()
    }

    func retryConnection(id: String) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[idx].isAvailable = true
        devices[idx].failure = nil
        rebuildSnapshot()
    }

    func setMainOut(_ state: MainOutState) {
        switch state.kind {
        case "selected":
            mainOut = MainOutState(kind: "selected")
            activeGroupID = nil
            muteState.removeAll()
        case "group":
            guard let groupID = state.groupID, let group = groups.first(where: { $0.id == groupID }) else {
                toasts.show(.refusal(reason: "Unknown group."))
                return
            }
            mainOut = MainOutState(kind: "group", groupID: groupID)
            activeGroupID = groupID
            muteState.removeAll()
            applyGroupMemberVolumes(group)
        default:
            toasts.show(.refusal(reason: "Unknown Main Out kind: \(state.kind)."))
            return
        }
        rebuildSnapshot()
    }

    func setDeviceVolume(id: String, volume: Int, isFinal: Bool) {
        // localRowDrivesMain parity (GroupController.setMemberVolume): with no
        // non-local Main Out member, the Mac's own row IS Main — the write
        // moves Main and leaves the Mac's stored fader untouched.
        if devices.first(where: { $0.id == id })?.isLocalDevice == true,
           !mainOutMemberIDs.contains(where: { $0 != localDeviceID }) {
            setMainOutMasterVolume(volume, isFinal: isFinal)
            return
        }
        setVolumeInternal(id, volume)
        rebuildSnapshot()
    }

    func setDeviceMuted(id: String, muted: Bool) {
        applyMute(muted, to: id)
        rebuildSnapshot()
    }

    // MARK: Main Out master

    /// Stateless, like the real `GroupController.setMainOutMasterVolume`:
    /// Main is its own gain stage, so no member's stored level moves.
    func setMainOutMasterVolume(_ volume: Int, isFinal: Bool) {
        mainOutMasterVolume = clampVolume(volume)
        rebuildSnapshot()
    }

    func setMainOutMuted(_ muted: Bool) {
        for id in mainOutMemberIDs { applyMute(muted, to: id) }
        rebuildSnapshot()
    }

    // MARK: Groups

    func createGroup(name: String, memberIDs: [String], iconSymbolName: String?) {
        guard !memberIDs.isEmpty else {
            toasts.show(.refusal(reason: "A group needs at least one device."))
            return
        }
        // Dedup by member set (GroupController.createGroup): resolve to the
        // existing group silently rather than making a copy.
        guard groups.first(where: { Set($0.memberIDs) == Set(memberIDs) }) == nil else { return }
        let volumes = Dictionary(uniqueKeysWithValues: memberIDs.compactMap { id in
            volume(for: id).map { (id, $0) }
        })
        groups.append(GroupState(id: UUID().uuidString, name: name, memberIDs: memberIDs,
                                  memberVolumes: volumes, iconSymbolName: iconSymbolName, isMuted: false))
        rebuildSnapshot()
    }

    func updateGroup(_ group: GroupState) {
        guard !group.memberIDs.isEmpty else {
            toasts.show(.refusal(reason: "A group needs at least one device."))
            return
        }
        if let idx = groups.firstIndex(where: { $0.id == group.id }) {
            groups[idx] = group
        } else {
            groups.append(group)
        }
        rebuildSnapshot()
    }

    func deleteGroup(id: String) {
        guard groups.contains(where: { $0.id == id }) else { return }
        if activeGroupID == id { activeGroupID = nil }
        // GroupController.deleteGroup: Main Out never dangles at a deleted
        // group — it falls back to Selected Devices.
        if mainOut.kind == "group", mainOut.groupID == id {
            mainOut = MainOutState(kind: "selected")
        }
        groups.removeAll { $0.id == id }
        rebuildSnapshot()
    }

    func setGroupMuted(id: String, muted: Bool) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        for memberID in group.memberIDs { applyMute(muted, to: memberID) }
        rebuildSnapshot()
    }

    // MARK: Apps

    func addAppRoute(bundleID: String, displayName: String) {
        guard !appRoutes.contains(where: { $0.bundleID == bundleID }) else { return }
        appRoutes.append(AppRouteState(bundleID: bundleID, displayName: displayName,
                                        destinationKind: "noRedirect", volume: 100, isRunning: true))
        addableApps.removeAll { $0.bundleID == bundleID }
        rebuildSnapshot()
    }

    func removeAppRoute(bundleID: String) {
        guard let idx = appRoutes.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        let removed = appRoutes.remove(at: idx)
        if !addableApps.contains(where: { $0.bundleID == bundleID }) {
            addableApps.append(Snapshot.AddableApp(bundleID: removed.bundleID, displayName: removed.displayName))
        }
        rebuildSnapshot()
    }

    func setAppDestination(bundleID: String, kind: String, deviceID: String?) {
        guard let idx = appRoutes.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        switch kind {
        case "noRedirect":
            appRoutes[idx].destinationKind = "noRedirect"
            appRoutes[idx].deviceID = nil
        case "currentDevice":
            appRoutes[idx].destinationKind = "currentDevice"
            appRoutes[idx].deviceID = nil
        case "device":
            guard let deviceID, devices.contains(where: { $0.id == deviceID }) else {
                toasts.show(.refusal(reason: "Unknown device."))
                return
            }
            appRoutes[idx].destinationKind = "device"
            appRoutes[idx].deviceID = deviceID
        default:
            toasts.show(.refusal(reason: "Unknown destination kind: \(kind)."))
            return
        }
        rebuildSnapshot()
    }

    func setAppVolume(bundleID: String, volume: Int, isFinal: Bool) {
        guard let idx = appRoutes.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        appRoutes[idx].volume = clampVolume(volume)
        rebuildSnapshot()
    }

    // MARK: Settings

    func setConnectVolume(_ volume: Int, isFinal: Bool) {
        connectVolume = min(max(volume, connectVolumeMin), connectVolumeMax)
        rebuildSnapshot()
    }

    func setStartBufferMs(_ ms: Int) {
        guard startBufferOptionsMs.contains(ms) else {
            toasts.show(.refusal(reason: "\(ms) ms is not one of the available buffer sizes."))
            return
        }
        startBufferMs = ms
        rebuildSnapshot()
    }

    // MARK: Shared helpers (mirror GroupController's private math)

    private var localDeviceID: String? { devices.first(where: \.isLocalDevice)?.id }

    private func volume(for id: String) -> Int? {
        devices.first(where: { $0.id == id })?.volume
    }

    private func clampVolume(_ value: Int) -> Int { min(max(value, 0), 100) }

    private func setVolumeInternal(_ id: String, _ value: Int) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[idx].volume = clampVolume(value)
    }

    /// The device ids the Main Out master/mute/mirror actually target —
    /// Selected Devices, or the active group's members (GroupController
    /// .mainOutMemberIDs).
    private var mainOutMemberIDs: [String] {
        switch mainOut.kind {
        case "group":
            return groups.first(where: { $0.id == mainOut.groupID })?.memberIDs ?? []
        default:
            return Array(selectedDeviceIDs)
        }
    }

    /// Applies a group's remembered per-member volumes on activation
    /// (GroupController.activateGroup), skipping the local device — its
    /// "volume" is the Mac's own system output, never replayed from a group.
    private func applyGroupMemberVolumes(_ group: GroupState) {
        for id in group.memberIDs {
            guard let idx = devices.firstIndex(where: { $0.id == id }), !devices[idx].isLocalDevice else { continue }
            if let vol = group.memberVolumes[id] {
                devices[idx].volume = clampVolume(vol)
            }
        }
    }

    private func applyMute(_ muted: Bool, to id: String) {
        guard devices.contains(where: { $0.id == id }) else { return }
        var state = muteState[id] ?? MemberMute()
        let wasSilent = state.explicitMute
        state.explicitMute = muted
        if muted != wasSilent {
            if muted {
                state.priorVolume = volume(for: id)
                setVolumeInternal(id, 0)
            } else {
                let restored = state.priorVolume ?? volume(for: id) ?? 0
                state.priorVolume = nil
                setVolumeInternal(id, restored)
            }
        }
        muteState[id] = state
    }

    private func connectionInfo(for record: DeviceRecord) -> DeviceState.ConnectionInfo {
        if !record.isAvailable, let failure = record.failure { return failure }
        if record.isLocalDevice { return DeviceState.ConnectionInfo(state: "connected") }
        return mainOutMemberIDs.contains(record.id)
            ? DeviceState.ConnectionInfo(state: "connected")
            : DeviceState.ConnectionInfo(state: "off")
    }

    /// App names currently routed to each device, for `Snapshot.liveRoutedAppNames`.
    private func computeLiveRoutedAppNames() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for route in appRoutes where route.isRunning && route.destinationKind == "device" {
            if let deviceID = route.deviceID {
                map[deviceID, default: []].append(route.displayName)
            }
        }
        return map
    }

    /// Rebuilds the whole snapshot from current state and republishes it.
    /// Called at the end of every mutating method above, so the published
    /// snapshot is always internally consistent — never a partial update.
    private func rebuildSnapshot() {
        let memberIDs = mainOutMemberIDs
        let deviceStates = devices.map { record in
            DeviceState(
                id: record.id,
                name: record.name,
                kind: record.kind,
                iconSymbolName: record.iconSymbolName,
                isAvailable: record.isAvailable,
                supportsAirPlay2: record.supportsAirPlay2,
                isLocalDevice: record.isLocalDevice,
                volume: record.volume,
                isMuted: muteState[record.id]?.explicitMute ?? false,
                isSelected: selectedDeviceIDs.contains(record.id),
                isMainOutMember: memberIDs.contains(record.id),
                connection: connectionInfo(for: record)
            )
        }
        let groupStates = groups.map { group in
            GroupState(
                id: group.id,
                name: group.name,
                memberIDs: group.memberIDs,
                memberVolumes: group.memberVolumes,
                iconSymbolName: group.iconSymbolName,
                isMuted: !group.memberIDs.isEmpty && group.memberIDs.allSatisfy { muteState[$0]?.explicitMute ?? false },
                masterVolume: group.masterVolume
            )
        }
        snapshot = Snapshot(
            serverName: "Demo Mac",
            devices: deviceStates,
            mainOut: mainOut,
            mainOutMasterVolume: mainOutMasterVolume,
            mainOutMuted: !memberIDs.isEmpty && memberIDs.allSatisfy { muteState[$0]?.explicitMute ?? false },
            groups: groupStates,
            activeGroupID: activeGroupID,
            appRoutes: appRoutes,
            liveRoutedAppNames: computeLiveRoutedAppNames(),
            addableApps: addableApps,
            localFallbackActive: false,
            takeoverStatus: nil,
            settings: SettingsState(
                connectVolume: connectVolume,
                connectVolumeMin: connectVolumeMin,
                connectVolumeMax: connectVolumeMax,
                startBufferMs: startBufferMs,
                startBufferOptionsMs: startBufferOptionsMs
            )
        )
    }
}
