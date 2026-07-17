import Foundation

/// UI-agnostic mixer model implementing SPEC.md §9's group semantics on top of
/// an ``OutputBackend``. Pure model — no AppKit, no menu/window code — so the
/// menu-bar extra and the mixer window can both drive the same logic and stay
/// in lockstep (Q6 in PLAN-PHASE-1.md's resolved decisions).
///
/// `GroupController` owns three things the backend itself doesn't know about:
/// 1. **Groups** — named member sets, persisted via ``GroupStore``, with at
///    most one *active* at a time.
/// 2. **Proportional master volume** — dragging a group's master scales its
///    members while preserving their relative balance; the master also
///    *echoes* the members' average when a member changes individually.
/// 3. **Mute** — volume-based (Q4): mute stores the pre-mute volume and drops
///    to 0; unmute restores the stashed level. (Solo was removed 2026-07-13 —
///    confusing jargon for a consumer app; mute is the only per-device silence.)
///
/// All mutation methods call through to the injected ``OutputBackend`` (real
/// or mock) via `setVolume`/`setOutputSet`; `GroupController` never invents a
/// second source of truth for volumes — it reads them back from `devices`.
public final class GroupController {

    // MARK: Mute semantics
    //
    // A member is *effectively silent* when `explicitMute[id] == true`.
    // Effective silence is realized as volume 0 on the backend; the volume from
    // just before muting is stashed and restored on unmute. Concretely:
    //
    // - `setMuted(true, id)` sets `explicitMute[id] = true`, stashes the current
    //   volume, and zeroes it on the backend.
    // - `setMuted(false, id)` sets `explicitMute[id] = false` and restores the
    //   stash.
    //
    // The stash is written only on the silence *edge* (a false→true transition),
    // so re-muting an already-muted member doesn't overwrite the original level.
    // (Solo was removed 2026-07-13 — see the type doc.)

    private struct MemberState {
        var explicitMute = false
        /// Volume to restore when the mute is lifted. `nil` means "not currently
        /// muted by us" (silence, if any, predates our bookkeeping — we just
        /// leave volume alone rather than guess).
        var priorVolume: Int?
    }

    private let backend: OutputBackend
    private let store: GroupStore
    private let routingStore: RoutingStore

    private(set) public var groups: [Group]
    private(set) public var activeGroupID: String?

    private var memberState: [String: MemberState] = [:]

    // MARK: Main Out / Selected Devices (SPEC.md §9 2026-07-14b — SoundSource model)
    //
    // Per-device toggles no longer route audio. They compose a PERSISTENT ad-hoc
    // set — `selectedDeviceIDs` ("Selected Devices"). Routing happens ONLY via
    // the Main Out selector (`mainOut` / `setMainOut`). The Mac's own output is
    // just one more device in the set; passthrough is DERIVED (set == {local}).

    /// The persistent "Selected Devices" set (SPEC §9). Toggling a device's
    /// switch adds/removes it here; this alone does NOT route audio unless Main
    /// Out currently targets `.selectedDevices` (the default), in which case the
    /// change is live-applied. Persisted.
    private(set) public var selectedDeviceIDs: Set<String> = []

    /// Where Main Out currently points (SPEC §9). Persisted. Changing it (via
    /// ``setMainOut(_:)``) is the ONLY thing that re-routes audio. Defaults to
    /// `.selectedDevices` so the out-of-the-box state (current device selected)
    /// is passthrough.
    private(set) public var mainOut: MainOutTarget = .selectedDevices

    /// Ratios captured by ``beginMasterDrag()``, keyed by member id, relative
    /// to the master volume at drag start. `nil` while no drag is in
    /// progress. See ``setMasterVolume(_:)``.
    private var dragRatios: [String: Double]?

    /// - Parameters:
    ///   - backend: where volume/output-set changes actually go.
    ///   - store: persistence for saved groups. Defaults to the on-disk store
    ///     at ``GroupStore/defaultDirectory``; tests inject one pointed at a
    ///     temp directory.
    ///   - loadPersisted: load `store`'s saved GROUPS immediately. Tests that
    ///     don't care about persistence can skip the disk hit. Scoped to groups
    ///     ONLY — it deliberately does not resume the live Selected-Devices
    ///     routing set (see the decision note in the body).
    ///   - routingStore: persistence for the live routing set. WRITE-ONLY at
    ///     launch by design — `persistRouting()` saves to it, nothing reads it
    ///     back (same decision note).
    public init(backend: OutputBackend,
                store: GroupStore = GroupStore(),
                routingStore: RoutingStore = RoutingStore(),
                loadPersisted: Bool = true) {
        self.backend = backend
        self.store = store
        self.routingStore = routingStore
        self.groups = loadPersisted ? ((try? store.load()) ?? []) : []
        // DECISION (Alec, 2026-07-17): the live Selected-Devices routing set is
        // NOT auto-resumed on launch. Every launch defaults to {current device}
        // = passthrough, so a previously-selected AirPlay device never
        // auto-streams when the app opens. Saved GROUPS still persist and stay
        // re-applyable (loaded above); only this live routing set resets to
        // local. We therefore do NOT read the persisted `selectedDeviceIDs` /
        // `mainOut` from `routingStore` here — `ensureDefaultSelection()` seeds
        // {local} once the fleet (incl. the current device) is known.
        //
        // `routingStore` is retained so ongoing changes are still SAVED (via
        // `persistRouting()`), which keeps the field live and lets a future
        // "resume last routing" option read it back without a signature change.
        //
        // MERGE NOTE (2026-07-17, phase2b ← main): main branched before this
        // decision and its side of this hunk restored routing here via
        // `routingStore.load()` under `loadPersisted`. That restore is
        // deliberately NOT carried forward. `loadPersisted` still gates SAVED
        // GROUPS (`store.load()` above) — it is a live knob, not vestigial — but
        // it must never again gate a routing resume. Do not "restore" the read
        // below; it is absent on purpose.
        _ = routingStore
    }

    /// True once the out-of-the-box default has been established, so
    /// ``ensureDefaultSelection()`` doesn't re-seed after the user has made a
    /// deliberate selection that was later cleared to empty.
    private var loadedPersistedRouting = false

    /// Establish the out-of-the-box default once the fleet is known (SPEC §9b):
    /// **Current Device toggled ON**, Main Out = Selected Devices ⇒ passthrough.
    /// No-op once established or if a selection already exists. The app calls
    /// this after every discovery event; safe to call repeatedly.
    public func ensureDefaultSelection() {
        guard !loadedPersistedRouting, selectedDeviceIDs.isEmpty else { return }
        guard let local = backend.devices.first(where: \.isLocalDevice) else { return }
        selectedDeviceIDs = [local.id]
        mainOut = .selectedDevices
        loadedPersistedRouting = true
        applyRouting()
        persistRouting()
    }

    /// Persist the current routing state (Selected Devices + Main Out target).
    private func persistRouting() {
        let state = RoutingStore.State(selectedDeviceIDs: Array(selectedDeviceIDs).sorted(),
                                       mainOut: mainOut)
        try? routingStore.save(state)
    }

    // MARK: Devices

    /// Current device snapshot, straight from the backend — `GroupController`
    /// never caches its own copy.
    public var devices: [Device] { backend.devices }

    private func device(_ id: String) -> Device? {
        backend.devices.first { $0.id == id }
    }

    // MARK: Selected Devices + Main Out routing (SPEC.md §9 2026-07-14b)
    //
    // THE CORE MODEL (supersedes the 07-13 free-on/off version): a device's toggle
    // no longer routes audio — it adds/removes the device from the PERSISTENT
    // `selectedDeviceIDs` set ("Selected Devices"). Audio is routed ONLY by the
    // Main Out selector (`setMainOut`). Toggling live-applies the output set when
    // Main Out currently targets `.selectedDevices` (the default). The Mac's own
    // output is one more device in the set; passthrough is DERIVED.

    /// Outcome of a `setDeviceSelected` attempt, so the UI can surface a refusal
    /// (the Phase-1 local-mix block) or note the auto-swap.
    public struct SelectionResult: Equatable {
        /// True when the requested change was applied.
        public let applied: Bool
        /// A user-facing reason when `applied == false` (else nil).
        public let refusalReason: String?
        /// True when this toggle auto-untoggled the current device (SPEC §9b
        /// auto-swap) so the UI can repaint that row.
        public let autoSwappedCurrentDevice: Bool

        public static let ok = SelectionResult(applied: true, refusalReason: nil, autoSwappedCurrentDevice: false)
        public static let okAutoSwap = SelectionResult(applied: true, refusalReason: nil, autoSwappedCurrentDevice: true)
        public static func refused(_ reason: String) -> SelectionResult {
            SelectionResult(applied: false, refusalReason: reason, autoSwappedCurrentDevice: false)
        }
    }

    /// The user-facing reason the Mac's own output is blocked from a mixed
    /// Selected Devices set (SPEC §9 Phase-1 local rule).
    public static let localMixRefusalReason =
        "Synced everywhere-audio arrives with the new engine"

    /// The local (Mac's own) device id in the current fleet, if discovered.
    private var localDeviceID: String? { backend.devices.first(where: \.isLocalDevice)?.id }

    /// Whether `id` is in the "Selected Devices" set. (Membership, NOT "is it
    /// receiving audio" — routing is decided by Main Out.)
    public func isSpeakerSelected(_ id: String) -> Bool { selectedDeviceIDs.contains(id) }

    /// Would adding `id` mix the local Mac with AirPlay devices in the set?
    private func wouldMixLocalWithAirPlay(adding id: String) -> Bool {
        guard let d = device(id) else { return false }
        if d.isLocalDevice {
            return selectedDeviceIDs.contains { device($0)?.isLocalDevice == false }
        } else {
            return selectedDeviceIDs.contains { device($0)?.isLocalDevice == true }
        }
    }

    /// Add or remove a device from "Selected Devices" (SPEC §9b). Composes the
    /// persistent set; live-applies the output set when Main Out targets
    /// `.selectedDevices`.
    ///
    /// Two Phase-1 rules apply when ADDING:
    /// - **Auto-swap:** turning ON an AirPlay device while the current (local)
    ///   device is the ONLY selected member auto-untoggles the current device
    ///   (switching to AirPlay implies moving the audio there). Fires only when
    ///   local is the sole member.
    /// - **Local-mix block:** turning ON the local device into a set that already
    ///   holds an AirPlay device is REFUSED with a reason (pre-engine sync limit).
    ///
    /// Removing is always allowed. No-op (`.ok`) if unknown / already in state.
    @discardableResult
    public func setDeviceSelected(_ id: String, _ selected: Bool) -> SelectionResult {
        guard let d = device(id) else { return .ok }
        if selected {
            guard !selectedDeviceIDs.contains(id) else { return .ok }

            // Local-mix block (manual re-add of the Mac into a mixed set).
            if d.isLocalDevice, wouldMixLocalWithAirPlay(adding: id) {
                return .refused(Self.localMixRefusalReason)
            }

            // Auto-swap: an AirPlay device turning ON while the local device is
            // the sole selected member drops the local device.
            var autoSwapped = false
            if !d.isLocalDevice, let local = localDeviceID,
               selectedDeviceIDs == [local] {
                selectedDeviceIDs.remove(local)
                autoSwapped = true
            }

            selectedDeviceIDs.insert(id)
            persistRouting()
            if mainOut == .selectedDevices { applyRouting() }
            return autoSwapped ? .okAutoSwap : .ok
        } else {
            guard selectedDeviceIDs.contains(id) else { return .ok }
            selectedDeviceIDs.remove(id)
            persistRouting()
            if mainOut == .selectedDevices { applyRouting() }
            return .ok
        }
    }

    /// Whether the local Mac may currently be toggled ON — false when it would
    /// mix with AirPlay devices (so the UI can disable its toggle with a
    /// tooltip). Removing an already-selected local device is always fine.
    public func canSelectLocalSpeaker(_ id: String) -> Bool {
        guard let d = device(id), d.isLocalDevice else { return true }
        if selectedDeviceIDs.contains(id) { return true }
        return !wouldMixLocalWithAirPlay(adding: id)
    }

    // MARK: Legacy on/off shims (kept for callers not yet migrated)

    /// Legacy alias for ``isSpeakerSelected(_:)``.
    public func isEnabled(_ id: String) -> Bool { isSpeakerSelected(id) }

    /// Legacy alias for ``setDeviceSelected(_:_:)`` (discards the result).
    public func setDeviceEnabled(_ id: String, _ on: Bool) { _ = setDeviceSelected(id, on) }

    // MARK: Main Out — the routing decision (SPEC §9 2026-07-14b)

    /// Whether the app is in passthrough (SPEC §9b — DERIVED): Main Out targets
    /// Selected Devices and that set is exactly {the local device}. A UI/test-facing
    /// predicate only — nothing in the audio path reads it. The real capture gate is
    /// `NativeBackend.reconcileCaptureGate()`, keyed on the backend's own
    /// `expectedSelected` (what `setOutputSet` was last called with), not on this
    /// property; the two agree because `applyRouting()` below always filters the
    /// local device out of the set it hands the backend, so passthrough reaches the
    /// backend as an empty output set on its own. Do NOT wire capture to consult
    /// `isPassthrough` directly — an unconsulted version of exactly that assumption
    /// is what let a passthrough session mute the Mac in the first place (the tap
    /// ran unconditionally; nothing here ever stopped it).
    ///
    /// T7 NOTE: `applyRouting()` no longer unions app-route redirect targets into
    /// the backend output set, so the "passthrough ⇒ empty output set" agreement
    /// now holds unconditionally again — redirecting an app leaves this property's
    /// answer (and the whole-system output set) untouched, because that app's audio
    /// travels the per-app capture path (`NativeBackend.updateAppRoutes`) instead.
    /// This property still answers only "is the SELECTED set just the Mac?"; nothing
    /// in the audio path may key off it.
    public var isPassthrough: Bool {
        guard mainOut == .selectedDevices, let local = localDeviceID else { return false }
        return selectedDeviceIDs == [local]
    }

    /// Point Main Out at a target and APPLY the routing (SPEC §9b — the only
    /// audio-routing action). Persisted.
    public func setMainOut(_ target: MainOutTarget) {
        mainOut = target
        applyRouting()
        persistRouting()
    }

    /// Realize `mainOut` against the backend's output set.
    /// - `.selectedDevices` → output set = the AirPlay members of the set. The
    ///   local device is never a backend output (it's the Mac itself); when the
    ///   set is exactly {local} the output set is EMPTY (passthrough).
    /// - `.group(id)` → output set = that group's members (via activation).
    private func applyRouting() {
        switch mainOut {
        case .selectedDevices:
            activeGroupID = nil
            // Only real (AirPlay) outputs go to the backend; the local device is
            // the Mac's own output, represented by an EMPTY output set. App-route
            // redirect targets are deliberately NOT unioned in here (T7): a
            // redirected app streams to its target device through the per-app
            // capture path (`NativeBackend.updateAppRoutes`), not the whole-system
            // output set — so this set stays exactly Selected Devices' AirPlay
            // members. Routing one app must never push the whole system mix to that
            // device (the original per-app-routing bug).
            let outputs = selectedDeviceIDs.filter { device($0)?.isLocalDevice == false }
            backend.setOutputSet(outputs)
        case .group(let id):
            activateGroup(id: id)
        }
    }

    // MARK: Group identity — member-set matching (SPEC.md §9 "DEDUP / group identity")
    //
    // A group is identified by its member SET, order-independent. These helpers
    // let the UI (menu + window) recognize "this selection IS group X" and avoid
    // ever creating a second group with an identical membership.

    /// The saved group whose members equal `memberIDs` as a *set* (order- and
    /// duplicate-independent), or nil if none. Empty sets never match (an empty
    /// selection isn't a group).
    public func group(matchingMemberSet memberIDs: [String]) -> Group? {
        group(matchingMemberSet: Set(memberIDs))
    }

    /// Set-typed overload of ``group(matchingMemberSet:)``.
    public func group(matchingMemberSet memberSet: Set<String>) -> Group? {
        guard !memberSet.isEmpty else { return nil }
        return groups.first { Set($0.memberIDs) == memberSet }
    }

    /// The saved group whose members equal the current Main Out target's
    /// membership, or nil for an ad-hoc selection that matches no group. This is
    /// the derived notion behind ``syncActiveGroupToSelection()``.
    public var groupMatchingCurrentSelection: Group? {
        // Keyed off the MEMBERSHIP the Main Out target names (`mainOutMemberIDs`
        // — selectedDeviceIDs when targeting Selected Devices, the group's own
        // members when targeting a group), NOT the live output set
        // (`Device.isSelected`): redirect targets now enter the output set, so
        // matching on it would spuriously pollute group identity (Q3).
        // `mainOutMemberIDs` is exactly the redirect-free membership set.
        return group(matchingMemberSet: mainOutMemberIDs)
    }

    /// Reconcile ``activeGroupID`` with the live output set: if the current
    /// selection exactly equals a saved group's members, that group IS active;
    /// if it matches none, there is no active group (ad-hoc selection). Call
    /// after the backend echoes a selection change so the model never treats a
    /// group's own member set as a nameless ad-hoc selection (SPEC.md §9).
    ///
    /// - Returns: the resolved `activeGroupID` (possibly nil).
    @discardableResult
    public func syncActiveGroupToSelection() -> String? {
        // Under the 2026-07-14 Main Out model, the active group is decided
        // EXPLICITLY by `mainOut`, not derived from the live output set. Only
        // re-derive when Main Out is itself a group (defensive: keeps
        // activeGroupID honest if the output set is reconciled underneath a
        // group target). For `.selectedDevices` there is no active group even if
        // the set coincidentally equals one.
        guard case .group = mainOut else {
            if activeGroupID != nil { activeGroupID = nil; memberState.removeAll() }
            return activeGroupID
        }
        let derived = groupMatchingCurrentSelection?.id
        if derived != activeGroupID {
            activeGroupID = derived
            // A different (or no) active group invalidates mute bookkeeping
            // tied to the previous group's membership.
            memberState.removeAll()
        }
        return activeGroupID
    }

    // MARK: Group CRUD + persistence

    /// Add or replace (by `id`) a group and persist the full set.
    @discardableResult
    public func saveGroup(_ group: Group) throws -> Group {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        try store.save(groups)
        return group
    }

    /// Outcome of a create/save-current operation, so the UI can tell "made a new
    /// group" from "you're already that group" (SPEC.md §9 dedup).
    public struct CreateResult {
        /// The group the operation resolved to (new or pre-existing).
        public let group: Group
        /// True when an identical-member group already existed and was resolved
        /// to instead of creating a duplicate.
        public let alreadyExisted: Bool
    }

    /// Create a group from an explicit member list + optional per-member volumes
    /// (the window's "New Group" / "New Group from Selection" paths). Dedups by
    /// member set: if a group with an identical set already exists, resolves to
    /// it (`alreadyExisted == true`) rather than making a copy. Pure model op —
    /// it does NOT route (routing is via Main Out); the caller activates if it
    /// wants (the window does, via its own `activateGroup` callback).
    ///
    /// Member volumes default to each device's current backend volume.
    @discardableResult
    public func createGroup(name: String,
                            memberIDs: [String],
                            memberVolumes: [String: Int]? = nil,
                            id: String = UUID().uuidString) throws -> CreateResult {
        if let existing = group(matchingMemberSet: memberIDs) {
            return CreateResult(group: existing, alreadyExisted: true)
        }
        let volumes = memberVolumes ?? Dictionary(uniqueKeysWithValues: memberIDs.compactMap { id in
            device(id).map { (id, $0.volume) }
        })
        let group = Group(id: id, name: name, memberIDs: memberIDs, memberVolumes: volumes)
        let saved = try saveGroup(group)
        return CreateResult(group: saved, alreadyExisted: false)
    }

    /// Build a group from the **Selected Devices** set + current volumes ("Save
    /// current setup as group…", SPEC.md §9 2026-07-14b — now = "save Selected
    /// Devices as a group"). Dedups: if the set already equals a saved group,
    /// that group is returned with `alreadyExisted == true` — never a second
    /// copy. Note this no longer activates on dedup, since routing is decided by
    /// Main Out (the caller can `setMainOut(.group(id:))` if desired).
    @discardableResult
    public func saveCurrentSetupAsGroup(name: String, id: String = UUID().uuidString) throws -> CreateResult {
        let selected = selectedDeviceIDs.compactMap(device)
        return try createGroup(
            name: name,
            memberIDs: selected.map(\.id),
            memberVolumes: Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.volume) }),
            id: id
        )
    }

    /// Remove a group. Deactivates it first if it was active, and if Main Out
    /// pointed at it, falls back to `.selectedDevices` so the routing target
    /// never dangles at a deleted group.
    public func deleteGroup(id: String) throws {
        if activeGroupID == id { activeGroupID = nil }
        if mainOut == .group(id: id) { setMainOut(.selectedDevices) }
        groups.removeAll { $0.id == id }
        try store.save(groups)
    }

    // MARK: Activation

    /// Make `id` the one active group: the output set becomes exactly its
    /// members (SPEC.md §9 — "groups behave like output presets"). Also
    /// applies the group's remembered per-member volumes and clears any
    /// mute bookkeeping left over from the previous active group.
    public func activateGroup(id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        activeGroupID = id
        memberState.removeAll()
        // Exactly the group's members reach the backend output set. App-route
        // redirect targets are NOT unioned in (T7) — a redirected app reaches its
        // device through the per-app capture path, not this whole-system set.
        backend.setOutputSet(Set(group.memberIDs))
        for memberID in group.memberIDs {
            if let volume = group.memberVolumes[memberID] {
                backend.setVolume(volume, for: memberID)
            }
        }
    }

    /// Clear the active group without changing the current output set
    /// (devices remain individually selectable — SPEC.md §9).
    public func deactivateGroup() {
        activeGroupID = nil
        memberState.removeAll()
    }

    private var activeMemberIDs: [String] {
        guard let activeGroupID, let group = groups.first(where: { $0.id == activeGroupID }) else { return [] }
        return group.memberIDs
    }

    // MARK: Master volume — proportional scaling + echo

    /// The active group's master volume: the members' current average,
    /// rounded to the nearest integer. 0 if there's no active group or it has
    /// no members — a reasonable "nothing playing" readout.
    public var masterVolume: Int {
        let members = activeMemberIDs.compactMap(device)
        guard !members.isEmpty else { return 0 }
        let sum = members.reduce(0) { $0 + $1.volume }
        return Int((Double(sum) / Double(members.count)).rounded())
    }

    /// Snapshot each member's volume ratio relative to the current master, so
    /// a subsequent ``setMasterVolume(_:)`` scales everyone proportionally
    /// instead of compounding rounding error across a drag. Call at the start
    /// of a master-slider drag; pair with ``endMasterDrag()``.
    public func beginMasterDrag() {
        let master = masterVolume
        var ratios: [String: Double] = [:]
        for id in activeMemberIDs {
            guard let device = device(id) else { continue }
            // A zero master can't be scaled proportionally (every ratio would
            // be undefined); fall back to "everyone moves together" by giving
            // each member a ratio of 1. See ``setMasterVolume(_:)`` clamp note.
            ratios[id] = master > 0 ? Double(device.volume) / Double(master) : 1.0
        }
        dragRatios = ratios
    }

    /// End the drag started by ``beginMasterDrag()``. Idempotent.
    public func endMasterDrag() {
        dragRatios = nil
    }

    /// Scale every active member from the ratios captured at
    /// ``beginMasterDrag()`` so relative balance is preserved, clamping each
    /// member at 100 (`Int.clampedToVolume`, Device.swift:88).
    ///
    /// If called without an open drag (no ``beginMasterDrag()``), snapshots
    /// ratios against the current master first — a single programmatic "set
    /// master to X" still scales proportionally, it just won't have the
    /// drag's stable reference point across repeated calls.
    ///
    /// Clamp behavior: when a member would exceed 100, it is clamped to 100
    /// and *stays* at 100 for the rest of the drag (its ratio is not
    /// re-derived), matching how a real fader stack behaves — that channel is
    /// pinned at unity until the drag ends and a fresh drag recomputes ratios
    /// from wherever the members ended up. Driving the master back down after
    /// clamping un-clamps normally, since scaling downward from the original
    /// ratio never re-hits the ceiling.
    public func setMasterVolume(_ target: Int) {
        let ratios = dragRatios ?? snapshotRatios()
        let target = target.clampedToVolume
        for id in activeMemberIDs {
            guard let ratio = ratios[id] else { continue }
            let scaled = Int((Double(target) * ratio).rounded())
            backend.setVolume(scaled.clampedToVolume, for: id)
        }
    }

    private func snapshotRatios() -> [String: Double] {
        let master = masterVolume
        var ratios: [String: Double] = [:]
        for id in activeMemberIDs {
            guard let device = device(id) else { continue }
            ratios[id] = master > 0 ? Double(device.volume) / Double(master) : 1.0
        }
        return ratios
    }

    /// Set one member's volume directly. The group master is a pure readout
    /// (``masterVolume``) so it automatically echoes the new average — no
    /// separate bookkeeping needed (SPEC.md §9 "Master echoes").
    public func setMemberVolume(_ volume: Int, for id: String) {
        backend.setVolume(volume.clampedToVolume, for: id)
    }

    // MARK: Main Out master (SPEC §9 2026-07-14b — proportional master of the target)
    //
    // The Main Out row's slider is the proportional master of whatever Main Out
    // currently points at: the Selected Devices set or a group's members. Reuses
    // the same ratio-snapshot math as the per-group master, over the target's
    // member set. (Device volumes exist for every device incl. the local Mac, so
    // the master scales the local device's own level too when it's a member.)

    /// The set of device ids the Main Out master scales.
    private var mainOutMemberIDs: [String] {
        switch mainOut {
        case .selectedDevices: return Array(selectedDeviceIDs)
        case .group(let id):   return groups.first { $0.id == id }?.memberIDs ?? []
        }
    }

    /// The Main Out master volume: the average of the target's members' volumes
    /// (0 when the target is empty).
    public var mainOutMasterVolume: Int {
        let members = mainOutMemberIDs.compactMap(device)
        guard !members.isEmpty else { return 0 }
        let sum = members.reduce(0) { $0 + $1.volume }
        return Int((Double(sum) / Double(members.count)).rounded())
    }

    private func mainOutRatios() -> [String: Double] {
        let master = mainOutMasterVolume
        var ratios: [String: Double] = [:]
        for id in mainOutMemberIDs {
            guard let device = device(id) else { continue }
            ratios[id] = master > 0 ? Double(device.volume) / Double(master) : 1.0
        }
        return ratios
    }

    /// Snapshot proportional ratios for a Main Out master drag. Pair with
    /// ``endMainOutMasterDrag()``.
    public func beginMainOutMasterDrag() { dragRatios = mainOutRatios() }

    /// End a Main Out master drag. Idempotent.
    public func endMainOutMasterDrag() { dragRatios = nil }

    /// Scale the Main Out target proportionally to `target` (0–100).
    public func setMainOutMasterVolume(_ target: Int) {
        scaleMainOutMembers(to: target, ratios: dragRatios ?? mainOutRatios())
    }

    /// Write `target × ratio` to every Main Out member, clamped. The shared body of
    /// the slider path above and the volume-key mirror below — which differ ONLY in
    /// where their ratios come from.
    ///
    /// - Returns: the exact volume commanded per member. The mirror keeps this as the
    ///   evidence behind its ratio snapshot; ``setMainOutMasterVolume(_:)`` discards it.
    @discardableResult
    private func scaleMainOutMembers(to target: Int, ratios: [String: Double]) -> [String: Int] {
        let target = target.clampedToVolume
        var commanded: [String: Int] = [:]
        for id in mainOutMemberIDs {
            guard let ratio = ratios[id] else { continue }
            let scaled = Int((Double(target) * ratio).rounded()).clampedToVolume
            backend.setVolume(scaled, for: id)
            commanded[id] = scaled
        }
        return commanded
    }

    // MARK: System-volume mirror — the volume keys drive what's actually playing
    //
    // THE BUG (Alec, live hardware session 2026-07-17): "when i use the volume keys
    // only the current device slider moves up and down not the selected devices".
    // The macOS volume keys move the system default output, which IS the local
    // "Current Device" row, and `NativeBackend`'s two-way sync faithfully moves that
    // row's slider. But while streaming, the capture tap MUTES the local output — so
    // the keys diligently adjusted a device the user could not hear while the
    // speakers actually playing ignored them.
    //
    // THE FIX: on an external system-volume change outside passthrough, mirror the
    // new volume onto the Main Out master, so the keys drive whatever Main Out
    // actually points at.
    //
    // NOT via CGEventTap/media-key interception — that needs an Accessibility grant.
    // The `SystemOutputVolume` listener already exists and already reports only
    // genuinely external changes, which is the whole design.

    /// The ratio snapshot an in-flight mirror burst is scaling from, plus the exact
    /// per-member volumes the last mirror write COMMANDED. `nil` when no burst is
    /// live. See ``mirrorSystemVolumeToMainOut(_:)``.
    ///
    /// Deliberately NOT ``dragRatios``: that field is shared with the group master
    /// (``setMasterVolume(_:)`` falls back to it), so parking mirror ratios — keyed
    /// to *Main Out* membership — in it would silently corrupt an undragged group
    /// master. The two snapshots answer different questions and get different fields.
    private var mirrorRatios: (ratios: [String: Double], commanded: [String: Int])?

    /// Mirror an EXTERNAL system-output-volume change onto the Main Out master, so
    /// the macOS volume keys drive whatever is actually playing rather than the
    /// tap-muted local output.
    ///
    /// Driven by ``BackendEvent/systemVolumeChanged(volume:)`` via `AppDelegate`.
    /// The backend only ever emits that for a genuine outside change —
    /// `SystemOutputVolume` suppresses echoes of its own writes by comparing a fresh
    /// read against its last-known state — so "the user pressed a volume key" and
    /// "the user dragged our Current Device slider" arrive already distinguished, and
    /// this needs no flag of its own to tell them apart.
    ///
    /// ## Why this cannot feed back
    ///
    /// The mirror never writes to the local device, because it refuses to run at all
    /// when the local device is a Main Out member. `backend.setVolume` reaches
    /// `SystemVolumeControlling` — and thus the listener that called us — for exactly
    /// one id, the local one (`NativeBackend.setVolume`'s `isLocalDevice` branch);
    /// every other id goes to the engine and can never come back around. No write to
    /// that id, no loop: the property is structural, not a race we happen to win.
    ///
    /// The two guards that establish it:
    /// - `!isPassthrough` — the agreed condition. In passthrough the local device is
    ///   the SOLE member, so mirroring would be circular *and* pointless: the keys
    ///   already moved the only thing Main Out names.
    /// - no local member — covers what `isPassthrough` does NOT. `isPassthrough` is
    ///   false for EVERY `.group` target, but a group's members can absolutely include
    ///   the Mac: `saveCurrentSetupAsGroup(name:id:)` while in passthrough saves
    ///   exactly such a group, and pointing Main Out at it afterwards is a normal
    ///   thing to do. Without this guard a volume key in that state would scale the
    ///   Mac by its own ratio and yank the system volume somewhere the user didn't
    ///   ask for. (`SystemOutputVolume`'s echo suppression would stop it *spinning* —
    ///   but no-loop should be a property of this method, not a behavior inherited
    ///   from a HAL helper two layers down.)
    ///
    /// ## Burst stability — why the ratios are held
    ///
    /// Volume keys arrive as a rapid series of ~16 discrete steps, each a separate
    /// call. Re-deriving ratios per step — what ``setMainOutMasterVolume(_:)`` does
    /// with no drag open — measurably DRIFTS, because `mainOutRatios()` normalizes
    /// against the members' *average* while the write scales to the *target*. The
    /// three ways it goes wrong, all reachable with two members at 80/40:
    /// 1. **Clamp ratchet.** Once any member clamps at 100 the average falls below
    ///    the target, so the next step's ratios re-normalize against that lower
    ///    average and re-expand everyone else. Stepping 80/40 up to the top and back
    ///    down lands at ~69/58 — the 2:1 balance is gone and does NOT come back.
    /// 2. **Zero collapse.** A burst down to 0 leaves every member at 0, where
    ///    `mainOutRatios()`'s `master > 0` fallback hands out a flat 1.0 — so the way
    ///    back up is uniform, not proportional. 80/40 returns as 6/6.
    /// 3. **Rounding noise.** Each member's own `.rounded()` is ±0.5 per step, which
    ///    random-walks over a burst; worst for quiet members, where ±0.5 is a large
    ///    fraction of the value.
    /// The existing slider path dodges all three by snapshotting once
    /// (``beginMainOutMasterDrag()``), and a keypress burst is morally a drag: a
    /// series of steps between two settled states. So the mirror holds one snapshot
    /// across the burst — giving it exactly the drag's semantics, including the
    /// documented "a clamped member stays pinned and un-clamps on the way down".
    ///
    /// It holds that snapshot with **no timer and no debounce**: `commanded` records
    /// what the last mirror write asked for, so if every member still sits exactly
    /// there, nothing but the mirror has touched them and the snapshot is still the
    /// right thing to scale from. Anything else moving a member — a slider, a mute,
    /// a group activation, a membership change — fails the comparison and re-derives.
    /// That is deliberately evidence rather than a list of invalidation call sites to
    /// keep in sync: a future path that moves a member gets this right by default
    /// instead of by remembering to.
    public func mirrorSystemVolumeToMainOut(_ volume: Int) {
        guard !isPassthrough else { mirrorRatios = nil; return }
        let members = mainOutMemberIDs
        guard !members.isEmpty else { mirrorRatios = nil; return }
        guard !members.contains(where: { device($0)?.isLocalDevice == true }) else {
            mirrorRatios = nil
            return
        }

        let current = currentMemberVolumes(members)
        let ratios: [String: Double]
        if let held = mirrorRatios, held.commanded == current {
            ratios = held.ratios        // still the same burst — hold the snapshot
        } else {
            ratios = mainOutRatios()    // fresh burst, or something else moved a member
        }
        mirrorRatios = (ratios, scaleMainOutMembers(to: volume, ratios: ratios))
    }

    /// Each member's current backend volume, skipping ids with no device. The key set
    /// matches ``mainOutRatios()``'s exactly (both skip the same ids), which is what
    /// makes the `commanded == current` comparison above meaningful: a member
    /// appearing or vanishing changes the keys and correctly forces a fresh snapshot.
    private func currentMemberVolumes(_ ids: [String]) -> [String: Int] {
        var volumes: [String: Int] = [:]
        for id in ids {
            guard let device = device(id) else { continue }
            volumes[id] = device.volume
        }
        return volumes
    }

    // MARK: Mute (Q4 — volume-based; see "Mute semantics" above)

    public func setMuted(_ muted: Bool, for id: String) {
        var state = memberState[id] ?? MemberState()
        let wasSilent = state.explicitMute
        state.explicitMute = muted
        applySilence(for: id, state: &state, wasSilent: wasSilent)
        memberState[id] = state
    }

    public func isMuted(_ id: String) -> Bool {
        memberState[id]?.explicitMute ?? false
    }

    // MARK: Master mute (SPEC §9 2026-07-14b — a "master" is muted iff ALL of the
    // target's members are muted; toggling drives every member together).

    /// Main Out master mute — mutes/unmutes every current Main Out target member together.
    public var isMainOutMuted: Bool {
        let ids = mainOutMemberIDs
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy { isMuted($0) }
    }
    public func setMainOutMuted(_ muted: Bool) {
        for id in mainOutMemberIDs { setMuted(muted, for: id) }
    }
    /// Group master mute — over a specific group's members.
    public func isGroupMuted(_ groupID: String) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }), !group.memberIDs.isEmpty else { return false }
        return group.memberIDs.allSatisfy { isMuted($0) }
    }
    public func setGroupMuted(_ muted: Bool, groupID: String) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        for id in group.memberIDs { setMuted(muted, for: id) }
    }

    /// Realize `state`'s effective silence against the backend, stashing or
    /// restoring volume on the silence edge only. `wasSilent` must be computed
    /// *before* the caller mutates `state`'s mute flag.
    private func applySilence(for id: String, state: inout MemberState, wasSilent: Bool) {
        let isSilent = state.explicitMute
        guard isSilent != wasSilent else { return }

        if isSilent {
            state.priorVolume = device(id)?.volume
            backend.setVolume(0, for: id)
        } else {
            let restored = state.priorVolume ?? device(id)?.volume ?? 0
            state.priorVolume = nil
            backend.setVolume(restored, for: id)
        }
    }
}
