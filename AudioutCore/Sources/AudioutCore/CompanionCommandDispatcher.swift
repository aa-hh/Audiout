// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import os
import AudioutProtocol

/// Executes a decoded `CompanionCommand` (`AudioutProtocol`) against the
/// exact same controller methods the Mac's own popover/mixer window call
/// (PLAN-COMPANION-APP.md T4). Adds no new business logic — every case below
/// is a direct call-through to `GroupController`/`AppRoutingController`/
/// `AppSettings`, or the injected closures for the two capabilities Core
/// itself doesn't own (local-playback volume, the async buffer apply).
///
/// This IS the network trust boundary, though: commands arrive from LAN peers,
/// so unlike the Mac's own UI (which can only produce well-formed input) every
/// string and collection is validated and capped here before it can reach
/// persistent state — see `Limits`. Refusal reasons sent back to a peer never
/// embed system error descriptions (they can carry local file paths); the
/// detail goes to the local log instead.
///
/// The Bluetooth actuators the alignment family of commands needs — injected
/// for the same reason `applyStartBuffer` is: this type owns what each command
/// MEANS (and is testable), while the wiring layer owns which backend, if any,
/// can actually do the work. Every closure answers a refusal reason, or `nil`
/// when it applied. Left unset, every alignment command is refused.
///
/// The three that OPEN something in the room — a run, a fine-tune session, a
/// receipt — carry the requesting client, so the probe messages can be
/// addressed back to the phone that staged the run and to nobody else, and so
/// a phone that walks out of range takes whatever it left playing down with it.
@MainActor
public struct CompanionAlignmentActions {
    public var startProbe: (_ targetID: String, _ clientID: UUID?) -> String?
    public var cancelProbe: (_ targetID: String) -> String?
    public var reportMeasurement: (_ targetID: String, _ offsetMs: Double, _ confidence: Double) -> String?
    public var setTick: (_ targetID: String, _ active: Bool, _ clientID: UUID?) -> String?
    public var nudgeTrim: (_ targetID: String, _ deltaMs: Double) -> String?
    public var revertNudge: (_ targetID: String) -> String?
    public var clearTuning: (_ targetID: String) -> String?
    public var playDemo: (_ targetID: String, _ clientID: UUID?) -> String?

    public init(
        startProbe: @escaping (String, UUID?) -> String?,
        cancelProbe: @escaping (String) -> String?,
        reportMeasurement: @escaping (String, Double, Double) -> String?,
        setTick: @escaping (String, Bool, UUID?) -> String?,
        nudgeTrim: @escaping (String, Double) -> String?,
        revertNudge: @escaping (String) -> String?,
        clearTuning: @escaping (String) -> String?,
        playDemo: @escaping (String, UUID?) -> String?
    ) {
        self.startProbe = startProbe
        self.cancelProbe = cancelProbe
        self.reportMeasurement = reportMeasurement
        self.setTick = setTick
        self.nudgeTrim = nudgeTrim
        self.revertNudge = revertNudge
        self.clearTuning = clearTuning
        self.playDemo = playDemo
    }
}

/// `@MainActor` for the same reason as `PopoverController`: both controllers
/// it drives are plain (non-actor) classes only ever touched from the main
/// thread; the companion server hops to main before calling `execute(_:)`
/// (T7/T5).
@MainActor
public final class CompanionCommandDispatcher {

    /// Caps on LAN-supplied data that ends up in persistent state (groups.json /
    /// appRoutes) or in every subsequent snapshot. Generous multiples of any
    /// real fleet; a peer that exceeds them is refused, never truncated.
    enum Limits {
        static let maxGroups = 64
        static let maxGroupNameChars = 64
        static let maxGroupMembers = 32
        static let maxMemberIDChars = 128
        static let maxIconNameChars = 128
        static let maxAppRoutes = 64
        static let maxBundleIDChars = 128
        static let maxDisplayNameChars = 128
        /// Ceiling on a reported sweep-arrival offset. Ten seconds is far past
        /// any real room plus the staging's own separation, and a measurement
        /// becomes a persisted latency, so an absurd one stops here.
        static let maxOffsetMs: Double = 10_000
    }

    /// Mirrors the wire `commandResult` message 1:1
    /// (`AudioutProtocol/CompanionMessage.swift`).
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
    /// The alignment family's actuators — see ``CompanionAlignmentActions``.
    /// `nil` on a backend with no Bluetooth sink of its own.
    private let alignmentActions: CompanionAlignmentActions?

    /// True while a `setStartBufferMs` apply Task is running. The apply tears
    /// every AirPlay stream down and back (~3-5s); overlapping runs would keep
    /// audio dead for as long as a peer floods the command, so a second apply
    /// is refused (not queued — the peer can simply retry after the reconnect,
    /// and a same-value replay is already a no-op via the equality check).
    private var startBufferApplyInFlight = false

    /// ASCII letters/digits plus `.`/`-` (Apple's documented bundle-ID
    /// alphabet) and `_` (nonconforming but seen in real apps).
    private static let bundleIDAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")

    private let log = Logger(subsystem: "com.audiout.Audiout", category: "companion")

    public init(
        groupController: GroupController,
        appRouting: AppRoutingController,
        settings: AppSettings,
        isExcluded: @escaping (String) -> Bool,
        setLocalPlaybackVolume: @escaping (Int, String) -> Void,
        applyStartBuffer: @escaping (Int) async -> Void,
        alignmentActions: CompanionAlignmentActions? = nil
    ) {
        self.groupController = groupController
        self.appRouting = appRouting
        self.settings = settings
        self.isExcluded = isExcluded
        self.setLocalPlaybackVolume = setLocalPlaybackVolume
        self.applyStartBuffer = applyStartBuffer
        self.alignmentActions = alignmentActions
    }

    /// Execute one command, mapping it to the exact controller method the
    /// popover/mixer window already call. See the plan's command→method table
    /// for the full mapping. Refusals cover the protocol sketch's cases (an
    /// empty-membership group edit, an excluded app's `addAppRoute`, unknown
    /// device/group targets, an out-of-range `setStartBufferMs`, `.unknown`)
    /// plus the trust-boundary hardening: `Limits` caps, blank/overlong names,
    /// unknown-id `updateGroup`, duplicate-member-set `createGroup`, device
    /// writes on a device that can't accept them, and store failures (which
    /// roll back so the reply matches the state the next snapshot shows).
    @discardableResult
    public func execute(_ command: CompanionCommand) -> Result {
        execute(command, clientID: nil)
    }

    /// Client-aware twin: the alignment family's `startAlignmentProbe` needs to
    /// know which phone staged the run, so the two probe messages can be sent
    /// back to that one client. Every other command ignores it, which is why
    /// ``execute(_:)`` above can forward a `nil`.
    @discardableResult
    public func execute(_ command: CompanionCommand, clientID: UUID?) -> Result {
        switch command {
        case .setDeviceSelected(let id, let selected):
            return Result(groupController.setDeviceSelected(id, selected))

        case .retryConnection(let id):
            return Result(groupController.retryConnection(for: id))

        case .setMainOut(let state):
            return applySetMainOut(state)

        case .setDeviceVolume(let id, let volume):
            if let refused = deviceWriteRefusal(id: id) { return refused }
            groupController.setMemberVolume(volume, for: id)
            return .ok

        case .setDeviceMuted(let id, let muted):
            // Gated for honesty, not just hygiene: `GroupController.setMuted`
            // records `explicitMute` synchronously while `NativeBackend` drops
            // the volume write for a device with no live engine output — the
            // snapshot would say MUTED while the speaker comes up audible.
            if let refused = deviceWriteRefusal(id: id) { return refused }
            groupController.setMuted(muted, for: id)
            return .ok

        case .setMainOutMasterVolume(let volume):
            // Stateless by design: Main is its own stored gain (volume
            // decoupling) — no drag bracket, no shared drag state to guard.
            groupController.setMainOutMasterVolume(volume)
            return .ok

        case .setMainOutMuted(let muted):
            groupController.setMainOutMuted(muted)
            return .ok

        case .createGroup(let name, let memberIDs, let iconSymbolName):
            return applyCreateGroup(name: name, memberIDs: memberIDs, iconSymbolName: iconSymbolName)

        case .updateGroup(let group):
            return applyUpdateGroup(group)

        case .deleteGroup(let id):
            return applyDeleteGroup(id: id)

        case .setGroupMuted(let id, let muted):
            groupController.setGroupMuted(muted, groupID: id)
            return .ok

        case .addAppRoute(let bundleID, let displayName):
            return applyAddAppRoute(bundleID: bundleID, displayName: displayName)

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
            // Already that value: honest no-op. Without this, replaying a VALID
            // ms would tear every AirPlay stream down (~3-5s) on each replay.
            guard ms != settings.startBufferMs else { return .ok }
            guard !startBufferApplyInFlight else {
                return .refused("A buffer change is already being applied. Try again in a few seconds.")
            }
            startBufferApplyInFlight = true
            Task {
                await applyStartBuffer(ms)
                startBufferApplyInFlight = false
            }
            return .ok

        case .requestAppIcons:
            // Handled by the wiring layer BEFORE it reaches here: answering needs
            // the client identity (to address the icon frames) and AppKit (to read
            // icons), neither of which this AppKit-free, client-agnostic dispatcher
            // has. Reaching this arm means the wiring didn't intercept — report
            // applied so the phone doesn't surface a spurious refusal toast.
            return .ok

        case .startAlignmentProbe(let targetID):
            return alignment(targetID) { actions, id in actions.startProbe(id, clientID) }

        case .cancelAlignmentProbe(let targetID):
            return alignment(targetID) { actions, id in actions.cancelProbe(id) }

        case .reportAlignmentMeasurement(let targetID, let offsetMs, let confidence):
            // A measurement turns straight into a persisted latency, so the
            // numbers are bounded here rather than trusted. `maxOffsetMs` is
            // generous over any staggered run's own separation; a value past
            // it is a peer bug or a hostile one, never a room.
            // Signed on purpose: the phone reports what its microphone heard,
            // and a speaker that arrives AHEAD of the reference is a real
            // result, not a bad one.
            guard offsetMs.isFinite, abs(offsetMs) <= Limits.maxOffsetMs else {
                return .refused("That measurement isn't a usable number.")
            }
            // `confidence` is a peak-to-sidelobe RATIO, not a fraction: the
            // phone's own floor for reporting at all is 5 and it has no
            // ceiling. Anything finite and non-negative is a number this side
            // can accept; a 0...1 bound here refuses every real one.
            guard confidence.isFinite, confidence >= 0 else {
                return .refused("That measurement isn't a usable number.")
            }
            return alignment(targetID) { actions, id in
                actions.reportMeasurement(id, offsetMs, confidence)
            }

        case .setAlignmentTick(let targetID, let active):
            return alignment(targetID) { actions, id in actions.setTick(id, active, clientID) }

        case .nudgeAlignmentTrim(let targetID, let deltaMs):
            // One detent's worth. A delta bigger than the trim's whole range
            // could only be a peer that has lost the plot.
            guard deltaMs.isFinite, abs(deltaMs) <= BTSyncTrim.rangeMs else {
                return .refused("That's further than the fine-tune can move.")
            }
            return alignment(targetID) { actions, id in actions.nudgeTrim(id, deltaMs) }

        case .revertAlignmentNudge(let targetID):
            return alignment(targetID) { actions, id in actions.revertNudge(id) }

        case .clearAlignmentTuning(let targetID):
            return alignment(targetID) { actions, id in actions.clearTuning(id) }

        case .playAlignmentDemo(let targetID):
            return alignment(targetID) { actions, id in actions.playDemo(id, clientID) }

        case .unknown(let name):
            return .refused("Unknown command: \(name).")
        }
    }

    // MARK: - Sync calibration (the alignment family)

    /// Shared shape for all eight: validate the device id at the trust
    /// boundary, refuse outright when this backend has no alignment actuators,
    /// then run the action and turn its reason into a `Result`.
    private func alignment(
        _ targetID: String,
        _ action: (CompanionAlignmentActions, String) -> String?
    ) -> Result {
        guard !targetID.isEmpty, targetID.count <= Limits.maxMemberIDChars else {
            return .refused("Unknown speaker.")
        }
        guard let alignmentActions else {
            return .refused("This Mac can't measure speaker timing right now. Reconnect the speaker and try again.")
        }
        if let reason = action(alignmentActions, targetID) { return .refused(reason) }
        return .ok
    }

    // MARK: - Group CRUD (validated + all-or-nothing)

    private func applyCreateGroup(name: String, memberIDs: [String], iconSymbolName: String?) -> Result {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refused = groupShapeRefusal(trimmedName: trimmedName, memberIDs: memberIDs,
                                           iconSymbolName: iconSymbolName) {
            return refused
        }
        guard groupController.groups.count < Limits.maxGroups else {
            return .refused("The Mac already has the maximum of \(Limits.maxGroups) scenes.")
        }
        // Explicit id so a failed store write can be rolled back below.
        let newID = UUID().uuidString
        do {
            let created = try groupController.createGroup(name: trimmedName, memberIDs: memberIDs,
                                                          iconSymbolName: iconSymbolName, id: newID)
            // A dedup hit made NOTHING — saying `applied` would leave the phone
            // showing a success for a group that never appears.
            guard !created.alreadyExisted else {
                return .refused("A scene with those exact speakers already exists (\(created.group.name)).")
            }
            return .ok
        } catch {
            // `saveGroup` appends in memory BEFORE the store write, so a throw
            // leaves the half-made group behind — remove it so the refusal is
            // honest. The rollback's own store write fails the same way, but
            // its in-memory removal happens first, and disk still holds the
            // pre-create contents (the atomic write never landed).
            try? groupController.deleteGroup(id: newID)
            return refusal(for: error)
        }
    }

    private func applyUpdateGroup(_ state: GroupState) -> Result {
        // Unknown id: REFUSE, never create (mirror of `deleteGroup`'s unknown-id
        // no-op). `saveGroup` would happily append, which lets a peer working
        // from a ≤50ms-stale snapshot resurrect a group the Mac just deleted —
        // and bypasses `createGroup`'s dedup-by-member-set invariant.
        guard let existing = groupController.groups.first(where: { $0.id == state.id }) else {
            return .refused("That scene no longer exists on the Mac.")
        }
        let trimmedName = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refused = groupShapeRefusal(trimmedName: trimmedName, memberIDs: state.memberIDs,
                                           iconSymbolName: state.iconSymbolName) {
            return refused
        }
        // The Mac's own editor seeds a newly added member's remembered volume
        // from the device's current level and clears removed members' entries
        // (GroupEditorViewController) — mirror both, so activating the group
        // later doesn't silently skip restoring a new member's level.
        var volumes: [String: Int] = [:]
        for memberID in state.memberIDs {
            if let sent = state.memberVolumes[memberID] {
                volumes[memberID] = sent.clampedToVolume
            } else if let device = groupController.devices.first(where: { $0.id == memberID }) {
                volumes[memberID] = device.volume
            }
        }
        do {
            _ = try groupController.saveGroup(Group(
                id: state.id,
                name: trimmedName,
                memberIDs: state.memberIDs,
                memberVolumes: volumes,
                iconSymbolName: state.iconSymbolName,
                // The group's own gain stage rides along when the phone sent it
                // (a snapshot round-trip does), otherwise the Mac's value is
                // preserved — `Group.init`'s default of 100 must never clobber
                // it on an unrelated rename/member edit.
                masterVolume: state.masterVolume ?? existing.masterVolume
            ))
        } catch {
            // Restore the pre-edit group in memory (the failed store write left
            // disk at the old contents already), so the refusal matches state.
            _ = try? groupController.saveGroup(existing)
            return refusal(for: error)
        }
        // `GroupState.isMuted` rides the wire but `Group` has no mute field —
        // apply it through the same group-mute API the Mac's UI uses rather
        // than silently discarding the phone's edit. No-op when it already
        // matches, so a plain round-trip of the snapshot changes nothing.
        if state.isMuted != groupController.isGroupMuted(state.id) {
            groupController.setGroupMuted(state.isMuted, groupID: state.id)
        }
        return .ok
    }

    private func applyDeleteGroup(id: String) -> Result {
        // Already gone: idempotent no-op, same as GroupController's own guard.
        guard let existing = groupController.groups.first(where: { $0.id == id }) else {
            return .ok
        }
        let priorMainOut = groupController.mainOut
        do {
            try groupController.deleteGroup(id: id)
            return .ok
        } catch {
            // `deleteGroup` removes the group (and may re-target Main Out)
            // BEFORE its store write — undo both so the refusal is honest.
            // Residue: if the group was the active one, its mute bookkeeping
            // reset — the same reset any Main Out re-target causes.
            _ = try? groupController.saveGroup(existing)
            if groupController.mainOut != priorMainOut {
                groupController.setMainOut(priorMainOut)
            }
            return refusal(for: error)
        }
    }

    /// Shared create/update validation for phone-supplied group fields.
    /// `trimmedName` must already be whitespace-trimmed.
    private func groupShapeRefusal(trimmedName: String, memberIDs: [String], iconSymbolName: String?) -> Result? {
        // Same rule as the Mac's own rename path (GroupEditorViewController):
        // an all-whitespace name is refused, never a blank sidebar row.
        guard !trimmedName.isEmpty else {
            return .refused("A scene needs a name.")
        }
        guard trimmedName.count <= Limits.maxGroupNameChars else {
            return .refused("Scene names are limited to \(Limits.maxGroupNameChars) characters.")
        }
        guard !memberIDs.isEmpty else {
            return .refused("A scene needs at least one speaker.")
        }
        guard memberIDs.count <= Limits.maxGroupMembers else {
            return .refused("Scenes are limited to \(Limits.maxGroupMembers) speakers.")
        }
        guard !memberIDs.contains(where: { $0.isEmpty || $0.count > Limits.maxMemberIDChars }) else {
            return .refused("That scene names an invalid speaker.")
        }
        if let icon = iconSymbolName, icon.count > Limits.maxIconNameChars {
            return .refused("That scene's icon isn't valid.")
        }
        return nil
    }

    // MARK: - Device writes

    /// Volume/mute writes are only honest for a device that can actually take
    /// them: `NativeBackend` silently drops the write when the device has no
    /// live engine output (off/connecting/failed), which would leave the
    /// phone's slider reverting — or worse, a recorded mute the speaker never
    /// received. The local Mac always accepts (its "volume" is the system
    /// output level, no engine output involved); `.reconnecting` keeps its
    /// engine output alive, so it accepts too.
    private func deviceWriteRefusal(id: String) -> Result? {
        guard let device = groupController.devices.first(where: { $0.id == id }) else {
            return .refused("Unknown speaker.")
        }
        if device.isLocalDevice { return nil }
        switch device.connectionState {
        case .connected, .reconnecting:
            return nil
        case .off, .connecting, .failed:
            return .refused("\(device.name) isn't connected yet, so it can't take volume changes.")
        }
    }

    // MARK: - App routes

    private func applyAddAppRoute(bundleID: String, displayName: String) -> Result {
        guard isPlausibleBundleID(bundleID) else {
            return .refused("That app identifier isn't valid.")
        }
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty, trimmedDisplayName.count <= Limits.maxDisplayNameChars else {
            return .refused("That app name isn't valid.")
        }
        guard !isExcluded(bundleID) else {
            return .refused("\(trimmedDisplayName) is excluded from routing in Settings.")
        }
        // Re-adding an existing route is `addRoute`'s documented no-op, so the
        // cap only refuses genuinely NEW routes.
        let alreadyRouted = appRouting.appRoutes.contains { $0.bundleID == bundleID }
        guard alreadyRouted || appRouting.appRoutes.count < Limits.maxAppRoutes else {
            return .refused("The Mac already has the maximum of \(Limits.maxAppRoutes) routed apps.")
        }
        appRouting.addRoute(bundleID: bundleID, displayName: trimmedDisplayName)
        return .ok
    }

    /// Reverse-DNS-ish shape check: non-empty, capped length, and only the
    /// bundle-ID alphabet (`Self.bundleIDAllowed`). Every route persists AND
    /// spawns a per-bundle capture probe, so arbitrary strings stop here.
    private func isPlausibleBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty, bundleID.count <= Limits.maxBundleIDChars else { return false }
        return bundleID.unicodeScalars.allSatisfy { Self.bundleIDAllowed.contains($0) }
    }

    // MARK: - Refusals

    private func refusal(for error: Error) -> Result {
        if let groupError = error as? GroupController.GroupError, groupError == .emptyMembership {
            return .refused("A scene needs at least one speaker.")
        }
        // Never ship a raw error description to a LAN peer — Cocoa NSErrors
        // carry `NSFilePath` (`/Users/<name>/Library/...`). Log the detail
        // locally; the peer gets a generic reason.
        log.error("companion command store failure: \(String(describing: error), privacy: .private)")
        return .refused("The Mac couldn't save that change.")
    }

    private func applySetMainOut(_ state: MainOutState) -> Result {
        switch state.kind {
        case "selected":
            groupController.setMainOut(.selectedDevices)
            return .ok
        case "group":
            guard let groupID = state.groupID,
                  groupController.groups.contains(where: { $0.id == groupID }) else {
                return .refused("Unknown scene.")
            }
            groupController.setMainOut(.group(id: groupID))
            return .ok
        default:
            return .refused("Unknown Main Audio kind: \(state.kind).")
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
            guard let deviceID, let device = groupController.devices.first(where: { $0.id == deviceID }) else {
                return .refused("Unknown speaker.")
            }
            // One-role-per-speaker, server side: the popover's redirect picker
            // skips Main Out members (PopoverController.appDestinations), and
            // AppRoutingController.clearRoutes(toDevices:) resolves the reverse
            // direction. A remote client is the third way to build the overlap —
            // post-008 the arbiter would silently demote the route, so refuse
            // honestly instead. The phone's own picker filters too (AppsView);
            // this guard is the trust boundary for any client.
            guard !groupController.isMainOutMember(deviceID) else {
                return .refused("\u{201C}\(device.name)\u{201D} is carrying Main Audio, deselect it as a speaker first.")
            }
            destination = .device(id: deviceID)
        default:
            return .refused("Unknown destination kind: \(kind).")
        }
        appRouting.setDestination(destination, for: bundleID)
        return .ok
    }
}
