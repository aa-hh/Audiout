// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import AudiouterProtocol

/// Executes a decoded `CompanionCommand` (`AudiouterProtocol`) against the
/// exact same controller methods the Mac's own popover/mixer window call
/// (PLAN-COMPANION-APP.md T4). Adds no new business logic — every case below
/// is a direct call-through to `GroupController`/`AppRoutingController`/
/// `AppSettings`, or the injected closures for the two capabilities Core
/// itself doesn't own (local-playback volume, the async buffer apply).
///
/// `@MainActor` for the same reason as `PopoverController`: both controllers
/// it drives are plain (non-actor) classes only ever touched from the main
/// thread; the companion server hops to main before calling `execute(_:)`
/// (T7/T5).
@MainActor
public final class CompanionCommandDispatcher {

    /// Mirrors the wire `commandResult` message 1:1
    /// (`AudiouterProtocol/CompanionMessage.swift`).
    public struct Result: Equatable {
        public let applied: Bool
        public let refusalReason: String?
        public let autoSwappedCurrentDevice: Bool

        public init(applied: Bool, refusalReason: String? = nil, autoSwappedCurrentDevice: Bool = false) {
            self.applied = applied
            self.refusalReason = refusalReason
            self.autoSwappedCurrentDevice = autoSwappedCurrentDevice
        }

        public static let ok = Result(applied: true)

        public static func refused(_ reason: String) -> Result {
            Result(applied: false, refusalReason: reason)
        }

        /// `GroupController.SelectionResult` already carries this exact triple
        /// (`setDeviceSelected`/`retryConnection`) — round-trip it as-is.
        init(_ selection: GroupController.SelectionResult) {
            self.applied = selection.applied
            self.refusalReason = selection.refusalReason
            self.autoSwappedCurrentDevice = selection.autoSwappedCurrentDevice
        }
    }

    private let groupController: GroupController
    private let appRouting: AppRoutingController
    private let settings: AppSettings
    private let isExcluded: (String) -> Bool
    /// Mirrors `AppDelegate.swift`'s `onSetLocalPlaybackVolume` wiring
    /// (`(volume, bundleID) -> Void`, `AppDelegate.swift:416-420`) — reaches a
    /// `.currentDevice` route's local playback stream immediately, same as an
    /// Applications-card slider drag on the Mac.
    private let setLocalPlaybackVolume: (Int, String) -> Void
    /// Implements the persist-then-apply path `AppDelegate.makeLatencySettingModel()`
    /// wires up (`AppDelegate.swift:1060-1063`): persists `AppSettings.startBufferMs`
    /// FIRST, then awaits `LatencyConfigurable.applyStartBuffer(ms:)`. Fired from a
    /// detached `Task` (below) so `execute(_:)` itself stays synchronous and returns
    /// `applied` immediately — the ~3-5s reconnect gap happens after the reply, same
    /// as the Mac's own "Apply & Reconnect" semantics (protocol sketch, D10).
    private let applyStartBuffer: (Int) async -> Void

    public init(
        groupController: GroupController,
        appRouting: AppRoutingController,
        settings: AppSettings,
        isExcluded: @escaping (String) -> Bool,
        setLocalPlaybackVolume: @escaping (Int, String) -> Void,
        applyStartBuffer: @escaping (Int) async -> Void
    ) {
        self.groupController = groupController
        self.appRouting = appRouting
        self.settings = settings
        self.isExcluded = isExcluded
        self.setLocalPlaybackVolume = setLocalPlaybackVolume
        self.applyStartBuffer = applyStartBuffer
    }

    /// Execute one command, mapping it to the exact controller method the
    /// popover/mixer window already call. See the plan's command→method table
    /// for the full mapping; refusals are limited to the cases the protocol
    /// sketch calls out: an empty-membership group edit, an excluded app's
    /// `addAppRoute`, a `.device` destination naming an unknown device (or
    /// `setMainOut` naming an unknown group — same trust-boundary shape), an
    /// out-of-range `setStartBufferMs`, and `.unknown` itself.
    @discardableResult
    public func execute(_ command: CompanionCommand) -> Result {
        switch command {
        case .setDeviceSelected(let id, let selected):
            return Result(groupController.setDeviceSelected(id, selected))

        case .retryConnection(let id):
            return Result(groupController.retryConnection(for: id))

        case .setMainOut(let state):
            return applySetMainOut(state)

        case .setDeviceVolume(let id, let volume):
            groupController.setMemberVolume(volume, for: id)
            return .ok

        case .setDeviceMuted(let id, let muted):
            groupController.setMuted(muted, for: id)
            return .ok

        case .beginMainOutDrag:
            groupController.beginMainOutMasterDrag()
            return .ok

        case .setMainOutMasterVolume(let volume):
            groupController.setMainOutMasterVolume(volume)
            return .ok

        case .endMainOutDrag:
            groupController.endMainOutMasterDrag()
            return .ok

        case .setMainOutMuted(let muted):
            groupController.setMainOutMuted(muted)
            return .ok

        case .createGroup(let name, let memberIDs, let iconSymbolName):
            do {
                _ = try groupController.createGroup(name: name, memberIDs: memberIDs, iconSymbolName: iconSymbolName)
                return .ok
            } catch {
                return refusal(for: error)
            }

        case .updateGroup(let group):
            do {
                _ = try groupController.saveGroup(Group(
                    id: group.id,
                    name: group.name,
                    memberIDs: group.memberIDs,
                    memberVolumes: group.memberVolumes,
                    iconSymbolName: group.iconSymbolName
                ))
                return .ok
            } catch {
                return refusal(for: error)
            }

        case .deleteGroup(let id):
            do {
                try groupController.deleteGroup(id: id)
                return .ok
            } catch {
                return refusal(for: error)
            }

        case .setGroupMuted(let id, let muted):
            groupController.setGroupMuted(muted, groupID: id)
            return .ok

        case .addAppRoute(let bundleID, let displayName):
            guard !isExcluded(bundleID) else {
                return .refused("\(displayName) is excluded from routing in Settings.")
            }
            appRouting.addRoute(bundleID: bundleID, displayName: displayName)
            return .ok

        case .removeAppRoute(let bundleID):
            appRouting.removeRoute(bundleID: bundleID)
            return .ok

        case .setAppDestination(let bundleID, let kind, let deviceID):
            return applySetAppDestination(bundleID: bundleID, kind: kind, deviceID: deviceID)

        case .setAppVolume(let bundleID, let volume):
            appRouting.setVolume(volume, for: bundleID)
            // Bug T2 parity (AppDelegate.swift:412-419): a `.currentDevice`
            // route's local playback stream must move immediately, not only
            // once the persisted route round-trips through `updateAppRoutes`.
            if let route = appRouting.appRoutes.first(where: { $0.bundleID == bundleID }),
               route.destination == .currentDevice {
                setLocalPlaybackVolume(volume, bundleID)
            }
            return .ok

        case .setConnectVolume(let volume):
            // Clamped by `AppSettings.connectVolume`'s own setter. No push —
            // the seed is read live on the next connect (protocol sketch).
            settings.connectVolume = volume
            return .ok

        case .setStartBufferMs(let ms):
            guard AppSettings.startBufferOptionsMs.contains(ms) else {
                return .refused("\(ms) ms is not one of the available buffer sizes.")
            }
            Task { await applyStartBuffer(ms) }
            return .ok

        case .unknown(let name):
            return .refused("Unknown command: \(name).")
        }
    }

    private func refusal(for error: Error) -> Result {
        if let groupError = error as? GroupController.GroupError, groupError == .emptyMembership {
            return .refused("A group needs at least one device.")
        }
        return .refused("\(error)")
    }

    private func applySetMainOut(_ state: MainOutState) -> Result {
        switch state.kind {
        case "selected":
            groupController.setMainOut(.selectedDevices)
            return .ok
        case "group":
            guard let groupID = state.groupID,
                  groupController.groups.contains(where: { $0.id == groupID }) else {
                return .refused("Unknown group.")
            }
            groupController.setMainOut(.group(id: groupID))
            return .ok
        default:
            return .refused("Unknown Main Out kind: \(state.kind).")
        }
    }

    private func applySetAppDestination(bundleID: String, kind: String, deviceID: String?) -> Result {
        let destination: AppRouteDestination
        switch kind {
        case "noRedirect":
            destination = .noRedirect
        case "currentDevice":
            destination = .currentDevice
        case "device":
            guard let deviceID, groupController.devices.contains(where: { $0.id == deviceID }) else {
                return .refused("Unknown device.")
            }
            destination = .device(id: deviceID)
        default:
            return .refused("Unknown destination kind: \(kind).")
        }
        appRouting.setDestination(destination, for: bundleID)
        return .ok
    }
}
