// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public enum SpeakerPresentationStatus: Equatable, Sendable {
    case connected
    case available
    case notConnected
    case unavailable
    case missing
    case connecting
    case reconnecting
    case awaitingPassword
    case failed(ConnectionFailure)

    public var text: String {
        switch self {
        case .connected: return "Connected"
        case .available: return "Ready"
        case .notConnected: return "Not connected"
        case .unavailable: return "Unavailable"
        case .missing: return "Missing speaker"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .awaitingPassword: return "Waiting for password"
        case .failed(let failure): return failure.headline
        }
    }
}

/// The host supplies current routing intent, without giving this controller a backend.
public struct SpeakerCurrentUse: Equatable, Sendable {
    public var mainAudioMemberIDs: Set<String>
    public var appRouteDestinations: [AppRouteDestination]
    public var liveFeedIDs: Set<String>
    public var recoveryIDs: Set<String>

    public init(mainAudioMemberIDs: Set<String> = [], appRouteDestinations: [AppRouteDestination] = [],
                liveFeedIDs: Set<String> = [], recoveryIDs: Set<String> = []) {
        self.mainAudioMemberIDs = mainAudioMemberIDs
        self.appRouteDestinations = appRouteDestinations
        self.liveFeedIDs = liveFeedIDs
        self.recoveryIDs = recoveryIDs
    }

    public func deviceIDs(groups: [Group]) -> Set<String> {
        routedDeviceIDs(groups: groups).union(liveFeedIDs).union(recoveryIDs)
    }

    /// Speakers Main Audio or an app route names. Forget refuses these; a recovery lookup alone never blocks it.
    public func routedDeviceIDs(groups: [Group]) -> Set<String> {
        var ids = mainAudioMemberIDs
        for destination in appRouteDestinations {
            switch destination {
            case .device(let id): ids.insert(id)
            case .group(let id):
                if let group = groups.first(where: { $0.id == id }) { ids.formUnion(group.memberIDs) }
            case .noRedirect, .currentDevice: break
            }
        }
        return ids
    }
}

/// What the Speakers screen says and does about Bluetooth access; the host owns the prompt itself.
public struct SpeakerBluetoothAccessPresentation: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case openSettings(SystemSettingsPane)
        case prime
    }

    public let explanation: String?
    public let actionTitle: String?
    public let action: Action

    public init(status: PermissionStatus, priming: Bool) {
        switch status {
        case .granted:
            explanation = nil
            actionTitle = nil
            action = .openSettings(.bluetooth)
        case .denied:
            explanation = "Allow Bluetooth access in System Settings to see paired speakers that are not connected."
            actionTitle = "Open Privacy Settings…"
            action = .openSettings(.bluetoothPrivacy)
        case .unsupported:
            explanation = "Bluetooth access is unavailable on this Mac."
            actionTitle = nil
            action = .none
        case .unknown, .requested:
            explanation = "Allow Bluetooth access to see paired speakers that are not connected."
            actionTitle = priming ? nil : "Allow Bluetooth…"
            action = priming ? .none : .prime
        }
    }
}

public struct SpeakerPresentationRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: Device.Kind?
    public let liveDevice: Device?
    public let visibility: SpeakerMixerVisibility
    public let metadataIsKnown: Bool
    public let isInUse: Bool
    /// Main Audio or an app route names it, which blocks Forget. Narrower than `isInUse`, which also counts
    /// connections, live feeds and recovery lookups, and decides visibility.
    public let isRouted: Bool

    public var isLocalDevice: Bool { liveDevice?.isLocalDevice == true || kind == .localMac }
    public var secondaryText: String? { metadataIsKnown ? nil : id }
    public var accessibilityIdentity: String { metadataIsKnown ? displayName : "Missing speaker, \(id)" }

    public var isAvailable: Bool {
        liveDevice?.isAvailable == true || liveDevice?.connectionState == .connected
    }

    public var status: SpeakerPresentationStatus {
        if let live = liveDevice {
            switch live.connectionState {
            case .connected: return .connected
            case .connecting: return .connecting
            case .reconnecting: return .reconnecting
            case .awaitingPassword: return .awaitingPassword
            case .failed(let failure): return .failed(failure)
            case .off: break
            }
        }
        guard let kind else { return .missing }
        if kind == .bluetooth { return liveDevice?.isAvailable == true ? .connected : .notConnected }
        return liveDevice?.isAvailable == true ? .available : .unavailable
    }

    public var isVisibleInMixer: Bool {
        if isLocalDevice || isInUse { return true }
        switch visibility {
        case .always: return true
        case .whenAvailable: return isAvailable
        case .hideWhenNotInUse: return false
        }
    }

    /// For configuration rendering only. Never supply this value to routing or a backend.
    public var renderingDevice: Device {
        liveDevice ?? Device(id: id, name: displayName, kind: kind ?? .generic, isAvailable: false,
                             supportsAirPlay2: false, volume: 0, isSelected: false,
                             isLocalDevice: isLocalDevice, connectionState: .off)
    }
}

/// Called on the host's presentation thread, like GroupController.
public final class SpeakerLibraryController {
    private let store: SpeakerLibraryStore
    private let persists: Bool
    private var state = SpeakerLibraryState()
    private var liveDevices: [Device] = []
    private var groups: [Group] = []
    private var currentUse = SpeakerCurrentUse()

    public private(set) var records: [SpeakerPresentationRecord] = []
    public var onChange: (() -> Void)?

    /// Disabling persistence also disables writes, for UI tests and offline harnesses.
    public init(store: SpeakerLibraryStore = SpeakerLibraryStore(),
                legacyHiddenStore: HiddenSpeakersStore = HiddenSpeakersStore(), loadPersisted: Bool = true) {
        self.store = store
        persists = loadPersisted
        if loadPersisted {
            let hadLibrary = store.hasAuthoritativeHistory
            let loaded = try? store.loadReportingDrops()
            state = loaded?.state ?? SpeakerLibraryState()
            if loaded?.droppedEntries == true || (hadLibrary && !store.exists) {
                // Quarantine or the load's copy preserves the old bytes; write the cleaned file without legacy
                // import, so the next launch neither drops the same entries again nor keeps another copy.
                _ = save(state)
            } else if !hadLibrary {
                let hidden = (try? legacyHiddenStore.load()) ?? []
                let imported = SpeakerLibraryState(visibility: Dictionary(hidden.map { ($0, .hideWhenNotInUse) },
                                                                           uniquingKeysWith: { first, _ in first }))
                if save(imported) { state = imported }
            }
        }
        records = makeRecords()
    }

    public func record(for id: String) -> SpeakerPresentationRecord? { records.first { $0.id == id } }

    public func visibility(for id: String) -> SpeakerMixerVisibility { state.visibility[id] ?? .whenAvailable }

    public var mixerRecords: [SpeakerPresentationRecord] { records.filter(\.isVisibleInMixer) }

    public func update(liveDevices: [Device], groups: [Group], confirmedUsedIDs: Set<String> = [],
                       currentUse: SpeakerCurrentUse = SpeakerCurrentUse()) {
        self.liveDevices = liveDevices
        self.groups = groups
        self.currentUse = currentUse
        let members = Set(groups.flatMap(\.memberIDs))
        var candidate = state
        for device in liveDevices {
            if candidate.metadata[device.id] != nil || confirmedUsedIDs.contains(device.id)
                || members.contains(device.id) || visibility(for: device.id) == .always {
                candidate.metadata[device.id] = SpeakerMetadata(name: device.name, kind: device.kind)
            }
        }
        var persistedChange = false
        if candidate != state, save(candidate) { state = candidate; persistedChange = true }
        publishIfChanged(force: persistedChange)
    }

    /// Derives current use from the host's routing state: the main output's members, connected ones, and live app feeds.
    public func update(liveDevices: [Device], groups: [Group], mainOut: MainOutTarget, selectedDeviceIDs: Set<String>,
                       appRouteDestinations: [AppRouteDestination], routedAppNamesByDeviceID: [String: [String]],
                       recoveryIDs: Set<String>) {
        let mainMembers: Set<String>
        switch mainOut {
        case .selectedDevices:
            mainMembers = selectedDeviceIDs
        case .group(let id):
            mainMembers = Set(groups.first { $0.id == id }?.memberIDs ?? [])
        }
        let liveIDs = Set(liveDevices.map(\.id))
        let liveFeeds = Set(routedAppNamesByDeviceID.compactMap { id, names in
            !names.isEmpty && liveIDs.contains(id) ? id : nil
        })
        let connectedMembers = Set(liveDevices.compactMap { device in
            mainMembers.contains(device.id) && device.connectionState == .connected ? device.id : nil
        })
        update(liveDevices: liveDevices, groups: groups, confirmedUsedIDs: connectedMembers.union(liveFeeds),
               currentUse: SpeakerCurrentUse(mainAudioMemberIDs: mainMembers, appRouteDestinations: appRouteDestinations,
                                             liveFeedIDs: liveFeeds, recoveryIDs: recoveryIDs))
    }

    @discardableResult
    public func setVisibility(_ visibility: SpeakerMixerVisibility, for id: String) -> Bool {
        setVisibility(visibility, for: [id])
    }

    /// A bulk gesture has one write and one publication, after the write succeeds.
    @discardableResult
    public func setVisibility(_ visibility: SpeakerMixerVisibility, for ids: Set<String>) -> Bool {
        var candidate = state
        var written = 0
        for id in ids {
            guard record(for: id)?.isLocalDevice != true else { continue }
            written += 1
            if visibility == .whenAvailable { candidate.visibility.removeValue(forKey: id) }
            else { candidate.visibility[id] = visibility }
            if visibility == .always, let device = liveDevices.first(where: { $0.id == id }) {
                candidate.metadata[id] = SpeakerMetadata(name: device.name, kind: device.kind)
            }
        }
        guard candidate != state else { return true }
        guard save(candidate) else { return false }
        state = candidate
        Analytics.capture("speaker:visibility_changed", ["visibility": visibility.rawValue, "count": String(written)])
        publishIfChanged(force: true)
        return true
    }

    /// Removes speakers the Mac cannot find from every scene and from the library. Speakers with a live device,
    /// and speakers Main Audio or an app route names (`isRouted`), are skipped. Throws
    /// `GroupError.emptyMembership` (nothing written) when a scene would be left empty.
    /// Never touches routing. Returns how many scenes changed.
    @discardableResult
    public func forget(_ ids: Set<String>, scenes: GroupController) throws -> Int {
        let filtered = ids.filter { record(for: $0)?.liveDevice == nil && record(for: $0)?.isRouted != true }
        guard !filtered.isEmpty else { return 0 }
        let sceneCounts = Dictionary(uniqueKeysWithValues: filtered.map { id in
            (id, scenes.groups.filter { $0.memberIDs.contains(id) }.count)
        })
        let changed = try scenes.removeDevices(filtered)
        for index in groups.indices {
            groups[index].memberIDs.removeAll { filtered.contains($0) }
        }
        var candidate = state
        for id in filtered {
            candidate.metadata.removeValue(forKey: id)
            candidate.visibility.removeValue(forKey: id)
        }
        guard save(candidate) else { return changed }
        state = candidate
        publishIfChanged(force: true)
        for id in filtered.sorted() {
            Analytics.capture("speaker:forgotten", ["scenes": String(sceneCounts[id] ?? 0)])
        }
        return changed
    }

    private func save(_ candidate: SpeakerLibraryState) -> Bool {
        guard persists else { return true }
        do { try store.save(candidate); return true }
        catch { StoreRecovery.noteWriteFailure(error); return false }
    }

    private func publishIfChanged(force: Bool = false) {
        let next = makeRecords()
        guard force || next != records else { return }
        records = next
        onChange?()
    }

    private func makeRecords() -> [SpeakerPresentationRecord] {
        let live = Dictionary(liveDevices.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ids = Set(live.keys).union(state.metadata.keys).union(groups.flatMap(\.memberIDs))
        var inUse = currentUse.deviceIDs(groups: groups)
        let routed = currentUse.routedDeviceIDs(groups: groups)
        for device in liveDevices {
            switch device.connectionState {
            case .connected, .connecting, .reconnecting, .awaitingPassword: inUse.insert(device.id)
            case .off, .failed: break
            }
        }
        return ids.map { id in
            let device = live[id]
            let metadata = state.metadata[id]
            return SpeakerPresentationRecord(id: id, displayName: device?.name ?? metadata?.name ?? "Missing speaker",
                                             kind: device?.kind ?? metadata?.kind, liveDevice: device,
                                             visibility: visibility(for: id), metadataIsKnown: device != nil || metadata != nil,
                                             isInUse: inUse.contains(id), isRouted: routed.contains(id))
        }.sorted {
            if $0.isAvailable != $1.isAvailable { return $0.isAvailable }
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
