import Foundation

/// UI-agnostic mixer model implementing SPEC.md §9's group semantics on top of
/// an ``OutputBackend``. Pure model — no AppKit, no menu/window code — so the
/// menu-bar extra and the mixer window can both drive the same logic and stay
/// in lockstep (Q6 in PLAN-PHASE-1.md's resolved decisions).
///
/// `GroupController` owns three things the backend itself doesn't know about:
/// 1. **Groups** — named member sets, persisted via ``GroupStore``, with at
///    most one *active* at a time.
/// 2. **The Main Out master gain** — a value of its own, never derived from and
///    never written back into the members. What reaches a device is
///    `Main × Group × Device`, multiplied at the backend's write boundary
///    (``OutputBackend/setMasterGain(mainOut:group:mirrorToSystemVolume:)``);
///    moving Main rewrites nobody's stored level.
/// 3. **Mute** — volume-based (Q4): mute stores the pre-mute volume and drops
///    to 0; unmute restores the stashed level. (Solo was removed 2026-07-13 —
///    confusing jargon for a consumer app; mute is the only per-device silence.)
///
/// All mutation methods call through to the injected ``OutputBackend`` (real
/// or mock) via `setVolume`/`setOutputSet`; `GroupController` never invents a
/// second source of truth for volumes — it reads them back from `devices`.
public final class GroupController {

    /// Errors from group CRUD that a caller may want to surface or (for the
    /// empty-membership invariant) simply rely on as a backstop.
    public enum GroupError: Error, Equatable {
        /// A group must always name at least one member device — an empty group
        /// can't be activated and would show as a dead entry in the Main Out
        /// selector. Creation and edits that would empty a group are refused;
        /// removing a group entirely is `deleteGroup(id:)`, not emptying it.
        case emptyMembership
    }

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
    private let settings: AppSettings

    private(set) public var groups: [Group]
    private(set) public var activeGroupID: String?

    /// Keyed by device id. Cleared WHOLESALE on group-activation transitions
    /// (`syncActiveGroupToSelection()`, `activateGroup(id:)`,
    /// `deactivateGroup()` — search `memberState.removeAll()`), never pruned
    /// per-device. Growth is bounded (one entry per distinct real device id
    /// this controller has ever muted, not unbounded), but a device that's
    /// muted once and then permanently leaves the fleet keeps its entry
    /// forever until the next wholesale clear.
    ///
    /// NOT fixed here (audit finding, scoped low-effort/deferred): this class
    /// has no per-device-removal signal to prune against. `devices` (above)
    /// always reads `backend.devices` LIVE and on demand — `GroupController`
    /// never caches a device list or subscribes to `BackendEvent` itself, so
    /// there's no hook that fires when a device drops out. The nearest
    /// candidate, `BackendEvent.deviceRemoved`, is also the WRONG signal for
    /// this even if wired up: its own doc comment says a device "stays in the
    /// model as unavailable; this signals availability, not deletion" — i.e.
    /// it fires for an ordinary offline blip, not a permanent departure, so
    /// pruning on it would drop a reconnecting device's mute state. It is also
    /// the last per-device dictionary in this class — the ratio snapshots that
    /// used to sit beside it are gone with the proportional master. Wiring a real
    /// permanent-removal signal is a bigger, separate change; left as a
    /// documented gap rather than building that machinery here.
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

    /// Fired AFTER a public mutation that actually changed pure-model state —
    /// Selected Devices membership, Main Out target, groups, the active group,
    /// or mute — never on a no-op early return. Deliberately NOT fired from a
    /// pure-backend-write path (``setMemberVolume(_:for:)``,
    /// ``setMainOutMasterVolume(_:)``, ``mirrorSystemVolumeToMainOut(_:)``):
    /// those write straight to ``OutputBackend`` and echo back as `BackendEvent
    /// .deviceUpdated`, so firing here too would double-notify. Single-assignment
    /// per house idiom — `AppDelegate` is the sole assignee.
    public var onStateDidChange: (() -> Void)?

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
    ///   - settings: where the Main Out master level persists. Injected so tests
    ///     can pass an isolated defaults suite.
    public init(backend: OutputBackend,
                store: GroupStore = GroupStore(),
                routingStore: RoutingStore = RoutingStore(),
                settings: AppSettings = AppSettings(),
                loadPersisted: Bool = true) {
        self.backend = backend
        self.store = store
        self.routingStore = routingStore
        self.settings = settings
        self.groups = loadPersisted ? ((try? store.load()) ?? []) : []
        // DECISION (ahh, 2026-07-17): the live Selected-Devices routing set is
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
    ///
    /// This is also where the Main Out master is SEEDED: it ADOPTS the Mac's
    /// actual current level (`backend.systemOutputVolume`), falling back to the
    /// persisted `AppSettings.mainOutVolume` only when the current output exposes
    /// no readable volume (many aggregate/digital outputs). Adoption, not
    /// restoration, is the point — opening the app must never move the user's
    /// volume, so the gain is pushed with `mirrorToSystemVolume: false` and no
    /// hardware write happens at launch. (`init` deliberately reads nothing back;
    /// see the decision note there.)
    public func ensureDefaultSelection() {
        guard !loadedPersistedRouting, selectedDeviceIDs.isEmpty else { return }
        guard let local = backend.devices.first(where: \.isLocalDevice) else { return }
        selectedDeviceIDs = [local.id]
        mainOut = .selectedDevices
        loadedPersistedRouting = true
        mainOutMasterVolume = (backend.systemOutputVolume ?? settings.mainOutVolume).clampedToVolume
        pushMasterGain(mirrorToSystemVolume: false)
        applyRouting()
        persistRouting()
        onStateDidChange?()
    }

    /// Persist the current routing state (Selected Devices + Main Out target).
    // STABILITY(D4): UI-thread stalls and stuck-drag state — see dev/notes/stability-audit-2026-07-18.md
    private func persistRouting() {
        let state = RoutingStore.State(selectedDeviceIDs: Array(selectedDeviceIDs).sorted(),
                                       mainOut: mainOut)
        try? routingStore.save(state)
    }

    // MARK: Devices

    /// Current device snapshot, straight from the backend — `GroupController`
    /// never caches its own copy.
    public var devices: [Device] { backend.devices }

    // STABILITY(C8): main thread blocks on the state queue for slow work — see dev/notes/stability-audit-2026-07-18.md
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

    /// Legacy user-facing string for the (now-lifted) local-mix block. Retained
    /// only because out-of-tree callers still reference the symbol
    /// (`AudiouterPopoverUI.PopoverController`, popover-harness); with the synced
    /// local sink the Mac may now join a mixed Selected Devices set, so nothing in
    /// this type ever emits it as a refusal any more (T-GROUPCTL / Q5). The popover
    /// wiring is retired separately in T-UI-ALLOW.
    public static let localMixRefusalReason =
        "Can't combine with AirPlay yet"

    /// The local (Mac's own) device id in the current fleet, if discovered.
    private var localDeviceID: String? { backend.devices.first(where: \.isLocalDevice)?.id }

    /// Whether `id` is in the "Selected Devices" set. (Membership, NOT "is it
    /// receiving audio" — routing is decided by Main Out.)
    public func isSpeakerSelected(_ id: String) -> Bool { selectedDeviceIDs.contains(id) }

    /// Add or remove a device from "Selected Devices" (SPEC §9b). Composes the
    /// persistent set; live-applies the output set when Main Out targets
    /// `.selectedDevices`.
    ///
    /// One rule applies when ADDING:
    /// - **Auto-swap (first-time AirPlay from Mac-only):** turning ON an AirPlay
    ///   device while the current (local) device is the ONLY selected member
    ///   auto-untoggles the current device (switching to AirPlay implies moving
    ///   the audio there). Fires ONLY when local is the sole member — so once the
    ///   Mac already coexists with ≥1 AirPlay device (the mixed set below), a
    ///   further AirPlay add is a plain insert and the Mac stays.
    ///
    /// The Mac may now join a MIXED Selected Devices set (Q5 / synced local sink):
    /// adding the local device is always allowed and drops nothing ⇒ `S ∪ {L}`.
    /// (The old pre-engine "local-mix block" refusal is gone.)
    ///
    /// Removing is always allowed, flooring the set at the local passthrough
    /// default:
    /// - **Current-device floor / reverse auto-swap:** removing the LAST AirPlay
    ///   device from an AirPlay-only set restores the local passthrough default
    ///   ({local}) instead of leaving the set empty. Physically the audio moves
    ///   back to the Mac either way (an empty output set IS passthrough at the
    ///   backend), so an empty set is a fiction the UI then renders as nonsense —
    ///   historically the master averaged an empty member set to 0 and the slider
    ///   slammed to zero on disconnect (ahh, live session 2026-07-17b: "when I
    ///   disconnect an airplay device, system audio out just goes straight down to
    ///   zero … when nothing is selected … only current device changes"). The
    ///   master no longer averages anything, so that particular symptom is gone;
    ///   the floor is kept because it is what makes {local} — a row the user can
    ///   see and move — the resting state instead of an empty mixer.
    ///   Fires only when the REMOVED device was an AirPlay one AND the set is left
    ///   empty: toggling the local device itself off is a deliberate act on that
    ///   row, not a disconnect, and re-adding it would make its toggle a no-op.
    ///   In the newly-reachable mixed set {L, A, …} this restore is SUBSUMED —
    ///   removing the last AirPlay device naturally leaves {L} (non-empty), so the
    ///   floor never fires and needs no special case for that path.
    ///
    /// No-op (`.ok`) if unknown / already in state.
    @discardableResult
    public func setDeviceSelected(_ id: String, _ selected: Bool) -> SelectionResult {
        guard let d = device(id) else { return .ok }
        if selected {
            guard !selectedDeviceIDs.contains(id) else { return .ok }

            // Auto-swap: an AirPlay device turning ON while the local device is
            // the sole selected member drops the local device. Once the Mac is
            // already mixed with AirPlay, this guard is false and the Mac stays.
            var autoSwapped = false
            if !d.isLocalDevice, let local = localDeviceID,
               selectedDeviceIDs == [local] {
                selectedDeviceIDs.remove(local)
                autoSwapped = true
            }

            selectedDeviceIDs.insert(id)
            persistRouting()
            if mainOut == .selectedDevices { applyRouting() }
            onStateDidChange?()
            return autoSwapped ? .okAutoSwap : .ok
        } else {
            guard selectedDeviceIDs.contains(id) else { return .ok }
            selectedDeviceIDs.remove(id)

            // Current-device floor (Warm Signal v4 §Call-1): there is NEVER a
            // zero-selected state — deselecting the LAST remaining device
            // auto-reselects the current (local) device, so the spine always
            // exists. This SUBSUMES the reverse auto-swap (removing the last
            // AirPlay device restored {local}); now removing the last device of
            // ANY kind does — including the local device itself, whose deselect
            // therefore becomes a no-op the row bounces back from.
            var autoSwapped = false
            if selectedDeviceIDs.isEmpty, let local = localDeviceID {
                selectedDeviceIDs.insert(local)
                // The auto-swap flash is for when the LOCAL row was re-toggled
                // FOR the user (the removed device wasn't the local one).
                autoSwapped = !d.isLocalDevice
            }

            persistRouting()
            if mainOut == .selectedDevices { applyRouting() }
            onStateDidChange?()
            return autoSwapped ? .okAutoSwap : .ok
        }
    }

    /// Force a fresh connection attempt for `id` — what the diagnosis panel's
    /// "Try again" calls (R12/W2-T3).
    ///
    /// Before R12, retry rode `setDeviceSelected(id, true)`: a `.failed` id had
    /// been dropped from the desired set as failure *cleanup*, so re-adding it
    /// was a genuine off→on membership edge that reached `applyRouting()`
    /// naturally. R12 stopped that cleanup — `.failed` keeps the id in the
    /// desired set (Selected Devices OR an active group's members) so the
    /// user's intent survives the failure — which means the id is usually
    /// ALREADY present by the time "Try again" fires. `setDeviceSelected`'s own
    /// no-op guard would swallow that call before it ever reached the backend.
    /// This bypasses that guard and re-applies routing unconditionally, so
    /// `OutputBackend.setOutputSet` is called again and can re-kick a `.failed`
    /// id (see that method's doc for the "already-desired retry" contract each
    /// backend implements).
    ///
    /// Handles both membership shapes identically (Groups and Selected Devices
    /// behave the same under R12): `id` already in `selectedDeviceIDs`, or
    /// already a member of the currently-active group. Falls back to the
    /// ordinary add path (`setDeviceSelected(id, true)`) if `id` isn't
    /// currently desired by either — shouldn't normally happen from the retry
    /// button, but keeps this safe as a general-purpose entry point.
    ///
    /// `selectedDeviceIDs` and an active group's `memberIDs` are INDEPENDENT
    /// sets — a device can sit in both at once (selected individually, then
    /// also swept into a group that later becomes Main Out). What must decide
    /// which re-kick fires is which routing is ACTUALLY live right now, i.e.
    /// `mainOut` itself — not "which membership set happens to contain `id`
    /// first". So the active-group check runs BEFORE the Selected-Devices
    /// early return (R12 rediscovery fixup): a `.failed` device that is both
    /// selected AND a member of the currently-active group must re-kick via
    /// the group path, since that's the routing actually in effect.
    @discardableResult
    public func retryConnection(for id: String) -> SelectionResult {
        if case .group(let groupID) = mainOut,
           let group = groups.first(where: { $0.id == groupID }),
           group.memberIDs.contains(id) {
            applyRouting()
            return .ok
        }
        if selectedDeviceIDs.contains(id) {
            if mainOut == .selectedDevices { applyRouting() }
            return .ok
        }
        return setDeviceSelected(id, true)
    }

    /// Whether the local Mac may currently be toggled ON. Always `true` now: with
    /// the synced local sink the Mac may join any (including mixed) Selected
    /// Devices set (Q5 / T-GROUPCTL), so the pre-engine local-mix block is gone.
    /// Retained as a stable predicate for the popover row (its greying-out is
    /// retired separately in T-UI-ALLOW).
    public func canSelectLocalSpeaker(_ id: String) -> Bool { true }

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
    ///
    /// The gain is pushed BEFORE `applyRouting()`: the target change also changes
    /// the GROUP stage (a group's own `masterVolume`, or 100 for Selected
    /// Devices), and a device connected by `applyRouting()` while the previous —
    /// possibly louder — product was still in force would get one burst at the
    /// wrong level.
    public func setMainOut(_ target: MainOutTarget) {
        mainOut = target
        pushMasterGain(mirrorToSystemVolume: false)
        applyRouting()
        persistRouting()
        onStateDidChange?()
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
            backend.setOutputSet(routableOutputIDs)
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
            if activeGroupID != nil {
                activeGroupID = nil
                memberState.removeAll()
                onStateDidChange?()
            }
            return activeGroupID
        }
        let derived = groupMatchingCurrentSelection?.id
        if derived != activeGroupID {
            activeGroupID = derived
            // A different (or no) active group invalidates mute bookkeeping
            // tied to the previous group's membership.
            memberState.removeAll()
            onStateDidChange?()
        }
        return activeGroupID
    }

    // MARK: Group CRUD + persistence

    /// Add or replace (by `id`) a group and persist the full set.
    ///
    /// Throws ``GroupError/emptyMembership`` if `group.memberIDs` is empty — a
    /// group must always keep at least one device. The guard runs before any
    /// mutation so a rejected save leaves `groups` untouched.
    @discardableResult
    public func saveGroup(_ group: Group) throws -> Group {
        guard !group.memberIDs.isEmpty else { throw GroupError.emptyMembership }
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        try store.save(groups)
        onStateDidChange?()
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
    /// it (`alreadyExisted == true`) rather than making a copy — in that case
    /// `iconSymbolName` is NOT applied, since the existing group's own icon
    /// (chosen when it was first created) must win. Pure model op — it does NOT
    /// route (routing is via Main Out); the caller activates if it wants (the
    /// window does, via its own `activateGroup` callback).
    ///
    /// Member volumes default to each device's current backend volume.
    @discardableResult
    public func createGroup(name: String,
                            memberIDs: [String],
                            memberVolumes: [String: Int]? = nil,
                            iconSymbolName: String? = nil,
                            id: String = UUID().uuidString) throws -> CreateResult {
        guard !memberIDs.isEmpty else { throw GroupError.emptyMembership }
        if let existing = group(matchingMemberSet: memberIDs) {
            return CreateResult(group: existing, alreadyExisted: true)
        }
        let volumes = memberVolumes ?? Dictionary(uniqueKeysWithValues: memberIDs.compactMap { id in
            device(id).map { (id, $0.volume) }
        })
        let group = Group(id: id, name: name, memberIDs: memberIDs, memberVolumes: volumes,
                          iconSymbolName: iconSymbolName)
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
    /// never dangles at a deleted group. No-op if `id` names no saved group.
    public func deleteGroup(id: String) throws {
        guard groups.contains(where: { $0.id == id }) else { return }
        if activeGroupID == id { activeGroupID = nil }
        if mainOut == .group(id: id) { setMainOut(.selectedDevices) }
        groups.removeAll { $0.id == id }
        try store.save(groups)
        onStateDidChange?()
    }

    // MARK: Activation

    /// Make `id` the one active group: the output set becomes exactly its
    /// AirPlay members (SPEC.md §9 — "groups behave like output presets"). Also
    /// applies the group's remembered per-member volumes and clears any
    /// mute bookkeeping left over from the previous active group.
    ///
    /// The local Mac is filtered out of both (see the body) — a group containing
    /// the Mac still plays there, via the synced local sink, which arms off
    /// ``isMainOutMember(_:)`` rather than off the output set.
    public func activateGroup(id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        activeGroupID = id
        memberState.removeAll()
        // Only the group's REAL (AirPlay) members reach the backend output set —
        // the same local-device filter `applyRouting()`'s Selected-Devices branch
        // applies, and the contract `NativeBackend.setOutputSet` documents ("the
        // local Mac is never a real engine output; `GroupController` never hands
        // it through"). Handing the Mac through made a Mac-only group look like
        // "Mac + ≥1 AirPlay" to the synced-local-sink decision — a sink armed with
        // nothing behind it — and left the Mac's own membership in a MIXED group
        // indistinguishable from a plain AirPlay member.
        // App-route redirect targets are still NOT unioned in (T7) — a redirected
        // app reaches its device through the per-app capture path, not this
        // whole-system set.
        backend.setOutputSet(routableOutputs(in: group.memberIDs))
        for memberID in group.memberIDs {
            // …and the Mac is skipped here too: its "volume" is the Mac's SYSTEM
            // output level (`NativeBackend.setVolume`'s local branch writes Core
            // Audio, not an engine output), so replaying a group's remembered
            // level would silently move the user's system volume on every
            // activation — and a remembered 0 would mute the Mac outright. The
            // Selected-Devices path pushes no member volumes at all, so leaving
            // the Mac's own level alone is the consistent behaviour.
            guard device(memberID)?.isLocalDevice != true else { continue }
            if let volume = group.memberVolumes[memberID] {
                backend.setVolume(volume, for: memberID)
            }
        }
        onStateDidChange?()
    }

    /// Clear the active group without changing the current output set
    /// (devices remain individually selectable — SPEC.md §9). No-op if no
    /// group is currently active.
    public func deactivateGroup() {
        guard activeGroupID != nil else { return }
        activeGroupID = nil
        memberState.removeAll()
        onStateDidChange?()
    }

    // MARK: Per-member volume

    /// Set one member's own level — the DEVICE stage of `Main × Group × Device`,
    /// and nothing more. The product is formed at the backend's write boundary, so
    /// moving one device never touches Main, the group, or any other member.
    ///
    /// **The one documented exception to "moving a device never changes Main"** is
    /// the Mac's own row while ``localRowDrivesMain`` — i.e. while there is no
    /// AirPlay output at all behind the current Main Out target. In that state what
    /// the user hears IS the Mac's system output, and Main is precisely the control
    /// that moves it: the row and Main are physically the same control, so the row
    /// drives Main rather than writing a device level that would leave Main
    /// displaying a loudness the machine isn't playing at. This is deliberate, not
    /// a leak of the master into the members — everywhere else the rule holds
    /// without exception.
    ///
    /// The Mac's own stored `Device.volume` is deliberately NOT written in that
    /// branch. It is the level the Mac returns to as an ordinary mixed member the
    /// moment an AirPlay device joins, and it must survive the round trip
    /// untouched.
    public func setMemberVolume(_ volume: Int, for id: String) {
        if id == localDeviceID, localRowDrivesMain {
            setMainOutMasterVolume(volume)
            return
        }
        backend.setVolume(volume.clampedToVolume, for: id)
    }

    // MARK: Main Out master — a gain stage, not a scaler (SPEC §9; volume decoupling)
    //
    // Main Out is a value of its OWN, stored here and persisted in
    // `AppSettings.mainOutVolume`. What reaches a device is `Main × Group ×
    // Device`, multiplied at the backend's write boundary
    // (`OutputBackend.setMasterGain`) and never stored anywhere. Moving Main
    // re-pushes wire levels and REWRITES NO DEVICE'S LEVEL.
    //
    // ## Why the old bugs are now structurally impossible
    //
    // Until W3 this master had no state: it AVERAGED its members and, on every
    // change, rewrote each member from a ratio snapshot taken against that
    // average. That design leaked the master into the members, and three of its
    // four hazards needed dedicated machinery (ratio snapshots held across a
    // burst, a `master > 0 ? … : 1.0` fallback, a per-step `.rounded()`) to hold
    // them off. All of it is deleted, because none of the hazards can occur:
    //
    // 1. **Clamp ratchet.** The old failure needed an AVERAGE to re-normalize
    //    against: once one member clamped at 100 the average fell below the
    //    target, so the next step re-expanded everyone else and the balance
    //    walked away (80/40 → up → back down → ~69/58, permanently). There is
    //    now no average and no ratio anywhere in this file. Each device's stored
    //    level is independent and untouched by Main; the master multiplies once,
    //    at the boundary. A device clamping at the wire has no path back into any
    //    other device's number.
    // 2. **Zero collapse.** The old failure needed the ratio fallback: at Main 0
    //    every member sat at 0, ratios were undefined, and the way back up was
    //    uniform (80/40 returned as 6/6). Main 0 now sends 0 while every stored
    //    level stays exactly where the user put it, so coming back up restores the
    //    EXACT original balance. The fallback is gone with the function that
    //    needed it.
    // 3. **Burst rounding drift.** The old failure needed a per-member,
    //    per-step integer `.rounded()` write, whose ±0.5 random-walked over a
    //    ~16-step key burst (worst for quiet members). A Main change now performs
    //    NO per-member write at all: one `Double` multiply per push, with no
    //    integer intermediate to accumulate error in. There is nothing to drift.
    // 4. **No feedback loop.** The old argument was behavioural — the mirror
    //    REFUSED TO RUN whenever the local device was a member, and one had to
    //    trust that guard. The new one is structural and needs no guard: the
    //    read-back arm (``applyExternalSystemVolume(_:)``) performs no hardware
    //    write whatsoever, and the only arm that writes hardware is the user-drag
    //    arm (``setMainOutMasterVolume(_:)``), whose echo `SystemOutputVolume`
    //    already suppresses by comparing state. One direction writes hardware; the
    //    other never does. A cycle would need both.

    /// The set of device ids the Main Out target names.
    private var mainOutMemberIDs: [String] {
        switch mainOut {
        case .selectedDevices: return Array(selectedDeviceIDs)
        case .group(let id):   return groups.first { $0.id == id }?.memberIDs ?? []
        }
    }

    /// The non-local members of `ids` — the exact filter every `setOutputSet` call
    /// applies, since the local Mac is never a backend output (it is the Mac
    /// itself, reached through the synced local sink instead).
    private func routableOutputs(in ids: [String]) -> Set<String> {
        Set(ids.filter { device($0)?.isLocalDevice == false })
    }

    /// The real (AirPlay) outputs of whatever Main Out currently targets — exactly
    /// what ``applyRouting()`` hands `OutputBackend.setOutputSet`. This is
    /// DISCOVERY-filtered (`device($0)` is nil for an undiscovered id, so it drops
    /// out) because you cannot open a route to a device that isn't there.
    private var routableOutputIDs: Set<String> { routableOutputs(in: mainOutMemberIDs) }

    /// True exactly when the current Main Out target has no non-local MEMBER —
    /// nothing selected but the Mac, an empty selection, or a Mac-only group. In
    /// that state the Mac's own row and the Main Out master are the same physical
    /// control; see ``setMemberVolume(_:for:)`` for the one behaviour that keys off
    /// this.
    ///
    /// Keyed off MEMBERSHIP, deliberately NOT ``routableOutputIDs``. Those two must
    /// diverge: routing needs the *discovered* outputs, but this predicate must not.
    /// A saved group that names a currently-powered-off AirPlay speaker still has a
    /// non-local member, so the Mac's row is NOT the master there — even though the
    /// speaker isn't discovered and so isn't routable yet. Keying off
    /// `routableOutputIDs` (discovery-filtered) would wrongly flip this true while
    /// the speaker is off and flip it back when it powers on, moving the Mac row
    /// between "drives Main" and "its own fader" under the user's hand.
    ///
    /// Also NOT ``isPassthrough`` (`selectedDeviceIDs == [local]`), which answers
    /// *false* for a Mac-only GROUP and an empty selection, and carries a standing
    /// warning that nothing in the audio path may key off it.
    public var localRowDrivesMain: Bool {
        !mainOutMemberIDs.contains { $0 != localDeviceID }
    }

    /// Whether `id` is a member of whatever Main Out currently points at — the
    /// Selected Devices set, or the active group's members.
    ///
    /// This — NOT ``isSpeakerSelected(_:)`` — is what
    /// `NativeBackend.selectedDevicesQuery` is wired to (in `AppDelegate`), the
    /// out-of-band signal behind the "Mac + ≥1 AirPlay ⇒ arm the synced local
    /// sink" decision. It has to arrive out of band because neither
    /// ``applyRouting()`` nor ``activateGroup(id:)`` ever hands the local Mac to
    /// `backend.setOutputSet`. `isSpeakerSelected(_:)` reads `selectedDeviceIDs`
    /// alone and so answers the wrong question under a GROUP target, in both
    /// directions: a group containing the Mac would never arm the sink (the Mac
    /// goes silent), and a Mac left behind in the untargeted Selected Devices set
    /// would arm it while an AirPlay-only group plays (the Mac plays when it
    /// shouldn't).
    ///
    /// Under `.selectedDevices` this is *exactly* ``isSpeakerSelected(_:)``, since
    /// `mainOutMemberIDs` is `Array(selectedDeviceIDs)` in that branch — so the
    /// two differ only on the group path.
    public func isMainOutMember(_ id: String) -> Bool { mainOutMemberIDs.contains(id) }

    /// The Main Out master gain (0–100). Its own value — not an average of
    /// anything. Seeded in ``ensureDefaultSelection()``, moved only by
    /// ``setMainOutMasterVolume(_:)`` and ``applyExternalSystemVolume(_:)``.
    private(set) public var mainOutMasterVolume: Int = 100

    /// The GROUP gain stage: the active group's own `masterVolume`, or 100 (the
    /// identity) whenever Main Out targets Selected Devices.
    private var groupGain: Int {
        guard case .group(let id) = mainOut else { return 100 }
        return groups.first { $0.id == id }?.masterVolume ?? 100
    }

    /// Push the current `Main × Group` product to the backend, which multiplies in
    /// each device's own level at its write boundary. Writes no device level.
    private func pushMasterGain(mirrorToSystemVolume: Bool) {
        backend.setMasterGain(mainOut: mainOutMasterVolume,
                              group: groupGain,
                              mirrorToSystemVolume: mirrorToSystemVolume)
    }

    /// The single body behind both Main entry points. `writeBackToSystem` is the
    /// ONLY thing that distinguishes them, and it is the whole feedback argument:
    /// exactly one arm writes the Mac's hardware volume.
    private func setMain(_ volume: Int, writeBackToSystem: Bool) {
        mainOutMasterVolume = volume.clampedToVolume
        pushMasterGain(mirrorToSystemVolume: writeBackToSystem)
        // Written straight through, not debounced. `AppSettings.mainOutVolume` is a
        // `UserDefaults` scalar — an in-memory set the framework already coalesces
        // before it ever touches disk — so a fader drag's dozens of writes a second
        // cost nothing worth batching. This used to sit behind a 0.5s trailing
        // DispatchWorkItem, which bought two defects for no benefit: the write
        // depended on the main run loop being serviced (it silently never landed
        // under a loaded test run), and quitting inside the window dropped it.
        settings.mainOutVolume = mainOutMasterVolume
    }

    /// The user moved Main (a fader drag, or anything else that means "make
    /// everything this loud"). Stores it, re-pushes the gain, and mirrors it to the
    /// Mac's own hardware output — the Mac is one of the things Main levels.
    public func setMainOutMasterVolume(_ volume: Int) {
        setMain(volume, writeBackToSystem: true)
    }

    /// **Precondition: the system output volume is ALREADY at `volume`.** Bring
    /// Main into agreement with it and re-push every dependent gain.
    ///
    /// Writes no hardware — the caller's premise is that something else already
    /// did. This is a statement about state, not about provenance: it makes no
    /// assumption as to what moved the system volume (a HAL listener, a media-key
    /// event tap, a scripted change) and applies no filtering of its own. Deciding
    /// which changes are genuinely external — and are not this app's own echo — is
    /// the caller's job and stays upstream in `NativeBackend`/`SystemOutputVolume`.
    public func applyExternalSystemVolume(_ volume: Int) {
        setMain(volume, writeBackToSystem: false)
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
        // Fires BEFORE the caller writes `state` back into `memberState`, so an observer reading `isMuted(id)` from this hook still sees the pre-toggle value.
        onStateDidChange?()

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
