// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AudiouterProtocol

/// Pure mapper from the existing controllers' live state to the wire
/// `AudiouterProtocol.Snapshot` the companion iPhone app renders
/// (PLAN-COMPANION-APP.md T3). No AppKit import — `AudiouterCore` stays
/// AppKit-free (see `AudiouterCore/AGENTS.md`); anything that would otherwise
/// need `NSImage`/`DeviceIconController` (AppKit-importing, lives in
/// `AudiouterSharedUI`) is taken as the injected `iconFor` closure instead.
///
/// `build(...)` never mutates anything it's handed — it only reads. The
/// coordinating layer (`AppDelegate`, T7) calls this after any change that
/// could affect the snapshot and broadcasts the result.
public enum CompanionSnapshotBuilder {

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
    ///     file is the only place in `AudiouterCore` that needs to
    ///     `import AudiouterProtocol` (the test target doesn't otherwise).
    ///   - runningRouted: bundle IDs of ALREADY-ROUTED apps that are
    ///     currently running, backing each `AppRouteState.isRunning`.
    ///   - liveRoutedAppNames: passthrough to `Snapshot.liveRoutedAppNames`.
    ///   - localFallbackActive: passthrough to `Snapshot.localFallbackActive`.
    ///   - takeoverStatus: passthrough to `Snapshot.takeoverStatus`.
    ///   - serverName: passthrough to `Snapshot.serverName`.
    ///   - connectVolume/connectVolumeMin/connectVolumeMax/startBufferMs/
    ///     startBufferOptionsMs: the Mac-authoritative settings slice —
    ///     passed through as-is so the phone always renders the Mac's
    ///     current range/options (`Snapshot.settings`).
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
        serverName: String,
        connectVolume: Int,
        connectVolumeMin: Int,
        connectVolumeMax: Int,
        startBufferMs: Int,
        startBufferOptionsMs: [Int]
    ) -> Snapshot {
        let deviceStates = devices.map { device in
            deviceState(for: device, groupController: groupController, iconFor: iconFor)
        }

        let groupStates = groupController.groups.map { group in
            GroupState(
                id: group.id,
                name: group.name,
                memberIDs: group.memberIDs,
                memberVolumes: group.memberVolumes,
                iconSymbolName: group.iconSymbolName,
                isMuted: groupController.isGroupMuted(group.id)
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
            liveRoutedAppNames: liveRoutedAppNames,
            addableApps: addableApps
                .filter { !excludedBundleIDs.contains($0.bundleID) }
                .map { Snapshot.AddableApp(bundleID: $0.bundleID, displayName: $0.displayName) },
            localFallbackActive: localFallbackActive,
            takeoverStatus: takeoverStatus,
            settings: SettingsState(
                connectVolume: connectVolume,
                connectVolumeMin: connectVolumeMin,
                connectVolumeMax: connectVolumeMax,
                startBufferMs: startBufferMs,
                startBufferOptionsMs: startBufferOptionsMs
            )
        )
    }

    private static func deviceState(
        for device: Device,
        groupController: GroupController,
        iconFor: (Device) -> String
    ) -> DeviceState {
        DeviceState(
            id: device.id,
            name: device.name,
            kind: device.kind.rawValue,
            iconSymbolName: iconFor(device),
            isAvailable: device.isAvailable,
            supportsAirPlay2: device.supportsAirPlay2,
            isLocalDevice: device.isLocalDevice,
            volume: device.volume,
            isMuted: groupController.isMuted(device.id),
            isSelected: groupController.isSpeakerSelected(device.id),
            isMainOutMember: groupController.isMainOutMember(device.id),
            connection: connectionInfo(device.connectionState)
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
    private static func destination(_ destination: AppRouteDestination) -> (kind: String, deviceID: String?) {
        switch destination {
        case .noRedirect:     return ("noRedirect", nil)
        case .currentDevice:  return ("currentDevice", nil)
        case .device(let id): return ("device", id)
        }
    }
}
