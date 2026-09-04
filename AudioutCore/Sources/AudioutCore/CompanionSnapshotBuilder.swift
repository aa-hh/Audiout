// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AudioutProtocol

/// Pure mapper from the existing controllers' live state to the wire
/// `AudioutProtocol.Snapshot` the companion iPhone app renders
/// (PLAN-COMPANION-APP.md T3). No AppKit import — `AudioutCore` stays
/// AppKit-free (see `AudioutCore/AGENTS.md`); anything that would otherwise
/// need `NSImage`/`DeviceIconController` (AppKit-importing, lives in
/// `AudioutSharedUI`) is taken as the injected `iconFor` closure instead.
///
/// `build(...)` never mutates anything it's handed — it only reads. The
/// coordinating layer (`AppDelegate`, T7) calls this after any change that
/// could affect the snapshot and broadcasts the result.
public enum CompanionSnapshotBuilder {

    // MARK: Size ceilings (FIX-A handoff — snapshot bounding is builder-side)
    //
    // The iOS client caps inbound frames at 1 MB (`CompanionServer.
    // iosInboundCapBytes`); an over-cap snapshot deterministically kills the
    // phone's connection, which then reconnect-loops on the same snapshot.
    // Everything else in the snapshot is bounded by reality (device fleet) or
    // by the dispatcher's input caps — only these two lists scale with the
    // Mac's running-app count, so they get documented ceilings. Truncation is
    // deterministic (sorted prefix / stable prefix), so a capped snapshot
    // still compares Equatable-identical between rebuilds and the server's
    // identical-snapshot suppression keeps working.

    /// Ceiling on `Snapshot.addableApps` — applied AFTER the bundleID sort,
    /// so which apps survive the cut is stable. ~100 bytes per entry keeps
    /// even the cap far under the frame budget; no real Mac runs anywhere
    /// near this many `.regular` apps.
    public static let maxAddableApps = 100

    /// Ceiling on names per device in `Snapshot.liveRoutedAppNames`
    /// (stable prefix of the backend's confirmed-streaming list).
    public static let maxLiveRoutedAppNamesPerDevice = 20

    /// - Parameters:
    ///   - devices: the live device list (already resolved by the caller —
    ///     this mapper never talks to a backend directly).
    ///   - groupController: source of truth for every group/Main-Out/mute
    ///     query below. **Trap:** `DeviceState.isSelected`/`isMainOutMember`/
    ///     `isMuted` MUST read `groupController.isSpeakerSelected(_:)` /
    ///     `.isMainOutMember(_:)` / `.isMuted(_:)` — never the passthrough
    ///     `Device.isSelected`/`Device.isMuted`, which the backend seam
    ///     leaves at their construction-time defaults and which disagree with
    ///     the controller-level notion (see `GroupController.swift`'s doc
    ///     comments on `isSpeakerSelected`/`isMainOutMember`/`setMuted`).
    ///     `DeviceState.volume` is the raw `Device.volume` with ONE overlay —
    ///     the Mac's own row under `localRowDrivesMain` reads the master (see
    ///     `deviceState(for:groupController:iconFor:)`).
    ///   - appRouting: source of the per-app redirect table.
    ///   - excludedBundleIDs: apps on the exclusion denylist
    ///     (`ExcludedAppsController.excludedBundleIDs`). **Trap:** an excluded
    ///     bundle ID must never appear in the returned `addableApps` or
    ///     `appRoutes`, even if the caller's raw `addableApps`/`appRouting`
    ///     input still names it (the coordinating layer is expected to prune
    ///     routes on exclusion, but this is the last-line guarantee).
    ///   - iconFor: resolves a device's display icon, including any Mac-side
    ///     override (`DeviceIconController.symbolName(for:)` on the caller's
    ///     side) — injected because that type imports AppKit.
    ///   - addableApps: candidate running apps the phone may offer to add a
    ///     route for (already computed by the caller from the running-app
    ///     list minus already-routed apps); this function still filters
    ///     `excludedBundleIDs` out of it. Plain `(bundleID, displayName)`
    ///     tuples rather than the wire `Snapshot.AddableApp` type, so this
    ///     file is the only place in `AudioutCore` that needs to
    ///     `import AudioutProtocol` (the test target doesn't otherwise).
    ///   - runningRouted: bundle IDs of ALREADY-ROUTED apps that are
    ///     currently running, backing each `AppRouteState.isRunning`.
    ///   - liveRoutedAppNames: passthrough to `Snapshot.liveRoutedAppNames`.
    ///   - localFallbackActive: passthrough to `Snapshot.localFallbackActive`.
    ///   - takeoverStatus: passthrough to `Snapshot.takeoverStatus`.
    ///   - systemDefaultIsAirPlayActive: passthrough to
    ///     `Snapshot.systemDefaultIsAirPlayActive` (FIX-B2 finding 7a — the
    ///     caller caches it from `BackendEvent.systemDefaultIsAirPlayActive`
    ///     like `localFallbackActive`).
    ///   - knownDeviceNames: last-known display name per `Device.id`,
    ///     INCLUDING devices no longer discovered (FIX-B2 finding 7b — the
    ///     caller keeps names across `deviceRemoved`). Backs each
    ///     `GroupState.memberNames` so the phone can label an offline group
    ///     member; the live `devices` list's names win over this map.
    ///   - serverName: passthrough to `Snapshot.serverName`.
    ///   - connectVolume/connectVolumeMin/connectVolumeMax/startBufferMs/
    ///     startBufferOptionsMs: the Mac-authoritative settings slice —
    ///     passed through as-is so the phone always renders the Mac's
    ///     current range/options (`Snapshot.settings`).
    ///   - alignmentFor: how fresh a Bluetooth device's stored sync
    ///     calibration is (`BTAlignmentFreshness.report(uid:hasStoreEntry:)`
    ///     on the caller's side, because the store and the connect edges live
    ///     in the backend). `nil` — the default, and every non-native backend
    ///     — leaves `DeviceState.alignment` unset, which the phone reads as
    ///     "not reported". The reference half of that wire struct is NOT
    ///     injected: it is a function of the whole live device list, so
    ///     ``alignmentReferenceID(forTarget:among:isAudible:)`` computes it
    ///     here and the phone's CTA and the Mac's staging can never disagree
    ///     about which speaker a run would measure against.
    public static func build(
        devices: [Device],
        groupController: GroupController,
        appRouting: AppRoutingController,
        excludedBundleIDs: Set<String>,
        iconFor: (Device) -> String,
        addableApps: [(bundleID: String, displayName: String)],
        runningRouted: Set<String>,
        liveRoutedAppNames: [String: [String]],
        localFallbackActive: Bool,
        takeoverStatus: String?,
        systemDefaultIsAirPlayActive: Bool = false,
        knownDeviceNames: [String: String] = [:],
        serverName: String,
        connectVolume: Int,
        connectVolumeMin: Int,
        connectVolumeMax: Int,
        startBufferMs: Int,
        startBufferOptionsMs: [Int],
        alignmentFor: (Device) -> BTAlignmentReport? = { _ in nil }
    ) -> Snapshot {
        let deviceStates = devices.map { device in
            deviceState(for: device, groupController: groupController, iconFor: iconFor,
                        alignment: alignmentState(for: device, among: devices,
                                                  groupController: groupController,
                                                  alignmentFor: alignmentFor))
        }

        // Live names win over the caller's last-known map — a rename arriving
        // via `deviceUpdated` must not be shadowed by a stale cached name.
        var deviceNames = knownDeviceNames
        for device in devices { deviceNames[device.id] = device.name }

        let groupStates = groupController.groups.map { group in
            GroupState(
                id: group.id,
                name: group.name,
                memberIDs: group.memberIDs,
                memberVolumes: group.memberVolumes,
                iconSymbolName: group.iconSymbolName,
                isMuted: groupController.isGroupMuted(group.id),
                // FIX-B2 finding 7b: names for members that are NOT currently
                // discovered come from `knownDeviceNames`; a member with no
                // known name at all is simply absent from the map.
                memberNames: Dictionary(uniqueKeysWithValues: group.memberIDs.compactMap { id in
                    deviceNames[id].map { (id, $0) }
                }),
                // The group's own gain stage (volume decoupling): a stored
                // value, not derived from members.
                masterVolume: group.masterVolume
            )
        }

        let appRouteStates = appRouting.appRoutes
            .filter { !excludedBundleIDs.contains($0.bundleID) }
            .map { route -> AppRouteState in
                let (kind, deviceID) = destination(route.destination)
                return AppRouteState(
                    bundleID: route.bundleID,
                    displayName: route.displayName,
                    destinationKind: kind,
                    deviceID: deviceID,
                    volume: route.volume,
                    isRunning: runningRouted.contains(route.bundleID)
                )
            }

        return Snapshot(
            serverName: serverName,
            devices: deviceStates,
            mainOut: mainOutState(groupController.mainOut),
            mainOutMasterVolume: groupController.mainOutMasterVolume,
            mainOutMuted: groupController.isMainOutMuted,
            groups: groupStates,
            activeGroupID: groupController.activeGroupID,
            appRoutes: appRouteStates,
            liveRoutedAppNames: liveRoutedAppNames.mapValues {
                $0.count > maxLiveRoutedAppNamesPerDevice
                    ? Array($0.prefix(maxLiveRoutedAppNamesPerDevice)) : $0
            },
            // Sorted by bundleID (FIX-B2 finding 3): `runningApplications`
            // order is documented as unspecified, and array order is part of
            // `Snapshot`'s Equatable — an order flap would defeat the
            // server's identical-snapshot suppression AND reshuffle the
            // phone's add-app list under the user's finger.
            addableApps: addableApps
                .filter { !excludedBundleIDs.contains($0.bundleID) }
                .sorted { $0.bundleID < $1.bundleID }
                .prefix(maxAddableApps)
                .map { Snapshot.AddableApp(bundleID: $0.bundleID, displayName: $0.displayName) },
            localFallbackActive: localFallbackActive,
            takeoverStatus: takeoverStatus,
            systemDefaultIsAirPlayActive: systemDefaultIsAirPlayActive,
            settings: SettingsState(
                connectVolume: connectVolume,
                connectVolumeMin: connectVolumeMin,
                connectVolumeMax: connectVolumeMax,
                startBufferMs: startBufferMs,
                startBufferOptionsMs: startBufferOptionsMs
            )
        )
    }

    /// The speaker a sync-calibration run for `targetID` would be measured
    /// against, or `nil` when there is nothing usable — which is what turns
    /// the phone's "Fix timing" CTA off.
    ///
    /// Mirrors the Mac wizard's own ordering
    /// (`PopoverController.btWizardDefaultReference`): the Mac's own output
    /// first (always present, always in step, nothing to set up), then any
    /// other non-Bluetooth speaker, then a Bluetooth one. Cast is never
    /// offered — a Cast receiver plays seconds behind live, which no
    /// ±500 ms correction can resolve against.
    ///
    /// Restricted to devices the user currently has audio on: a reference that
    /// is not playing makes no sound for the phone's microphone to hear, so
    /// offering it would stage a run that cannot produce a measurement.
    /// `isAudible` must be `GroupController.isMainOutMember(_:)` — the
    /// group-aware read; `isSpeakerSelected(_:)` is blind to group membership
    /// and would drop every member of an active group from the candidates.
    public static func alignmentReferenceID(
        forTarget targetID: String,
        among devices: [Device],
        isAudible: (String) -> Bool
    ) -> String? {
        let candidates = devices.filter {
            $0.id != targetID && $0.isAvailable && !$0.isCast && isAudible($0.id)
        }
        if let local = candidates.first(where: \.isLocalDevice) { return local.id }
        if let wired = candidates.first(where: { !$0.isBluetooth }) { return wired.id }
        return candidates.first?.id
    }

    /// The wire alignment struct for one device: the caller's freshness report
    /// plus the reference this builder computes. `nil` for every non-Bluetooth
    /// device, and for a Bluetooth one the caller has no report for.
    private static func alignmentState(
        for device: Device,
        among devices: [Device],
        groupController: GroupController,
        alignmentFor: (Device) -> BTAlignmentReport?
    ) -> DeviceState.AlignmentState? {
        guard device.kind == .bluetooth, let report = alignmentFor(device) else { return nil }
        return DeviceState.AlignmentState(
            status: report.status.rawValue,
            staleReason: report.staleReason,
            referenceID: alignmentReferenceID(
                forTarget: device.id, among: devices,
                isAudible: groupController.isMainOutMember),
            settleRemainingSeconds: report.settleRemainingSeconds,
            clockState: report.clockState.rawValue)
    }

    private static func deviceState(
        for device: Device,
        groupController: GroupController,
        iconFor: (Device) -> String,
        alignment: DeviceState.AlignmentState?
    ) -> DeviceState {
        DeviceState(
            id: device.id,
            name: device.name,
            kind: device.kind.rawValue,
            iconSymbolName: iconFor(device),
            isAvailable: device.isAvailable,
            supportsAirPlay2: device.supportsAirPlay2,
            isLocalDevice: device.isLocalDevice,
            // Passthrough overlay, mirroring `PopoverController.applySelectionState`:
            // with no real output behind the current Main Out target, the Mac's row
            // WRITES Main (`setMemberVolume` redirects a local-row write to
            // `setMainOutMasterVolume`), so it has to READ Main too. Without this the
            // phone showed the Mac's stored fader for a row whose slider moved the
            // master — a different number from the Mac's own row for the same thing.
            // The stored fader underneath is deliberately untouched: it is what the
            // row goes back to showing the moment an AirPlay device joins.
            volume: device.isLocalDevice && groupController.localRowDrivesMain
                ? groupController.mainOutMasterVolume : device.volume,
            isMuted: groupController.isMuted(device.id),
            isSelected: groupController.isSpeakerSelected(device.id),
            isMainOutMember: groupController.isMainOutMember(device.id),
            connection: connectionInfo(device.connectionState),
            alignment: alignment
        )
    }

    private static func connectionInfo(_ state: ConnectionState) -> DeviceState.ConnectionInfo {
        switch state {
        case .off:
            return DeviceState.ConnectionInfo(state: "off")
        case .connecting:
            return DeviceState.ConnectionInfo(state: "connecting")
        case .connected:
            return DeviceState.ConnectionInfo(state: "connected")
        case .reconnecting:
            return DeviceState.ConnectionInfo(state: "reconnecting")
        case .failed(let failure):
            return DeviceState.ConnectionInfo(
                state: "failed",
                failureHeadline: failure.headline,
                failureSuggestion: failure.suggestion
            )
        }
    }

    private static func mainOutState(_ target: MainOutTarget) -> MainOutState {
        switch target {
        case .selectedDevices: return MainOutState(kind: "selected")
        case .group(let id):   return MainOutState(kind: "group", groupID: id)
        }
    }

    /// Flattens `AppRouteDestination` to the wire `(kind, deviceID)` pair —
    /// same idiom `AppRouteStore.PersistedRoute` already uses on disk.
    ///
    /// razor: a `.group` route reports its KIND but not WHICH group, because
    /// `AudioutProtocol.AppRouteState` carries only `deviceID`, documented as
    /// non-nil for `"device"` alone — putting a group id there would have the
    /// phone look it up in the device list and find nothing. So the phone can
    /// tell the app is routed away from the main mix and cannot name the
    /// destination. To lift: add a `groupID` field to `AppRouteState` in
    /// audiout-shared, bump the pin, and fill it here.
    private static func destination(_ destination: AppRouteDestination) -> (kind: String, deviceID: String?) {
        switch destination {
        case .noRedirect:     return ("noRedirect", nil)
        case .currentDevice:  return ("currentDevice", nil)
        case .device(let id): return ("device", id)
        // razor: a group route reports its KIND but not which group. The wire
        // pair has only a device slot, and `AppRouteStore.PersistedRoute` keeps
        // group ids in `destinationGroupID` precisely so the two id spaces can
        // never be read as each other — so the id is dropped rather than
        // smuggled through `deviceID`. The phone can tell the app is
        // group-routed and cannot name the group. Closing that needs a
        // `groupID` on the wire type, mirroring `MainOutState.groupID`.
        case .group:          return ("group", nil)
        }
    }
}
