# T2 — Data safety + GroupController main-thread hygiene

**Branch:** `claude/fix-data-safety` (worktree under `.claude/worktrees/`, pushed to origin at creation per CLAUDE.md). Fork from current `main` HEAD (`7886f98d`); the source worktree is clean — no uncommitted work this track depends on.

**Repo root (path has a space — quote it):** `/Users/alechenderson/Projects/AirPlay Controller` — but work in YOUR track worktree, never the main checkout. All paths below are relative to the repo root; `Sources/` means `AudioutCore/Sources/`.

**Read first:** root `CLAUDE.md`, root `AGENTS.md`, `AudioutCore/AGENTS.md`. Guard 7 requires `scripts/self-review.sh` before any Swift commit.

**BINDING BUILD/TEST RULE (coordinator directive):** every compile and every test run — filtered runs included — goes through the wrapper scripts, which route work to the remote test mule: `bash scripts/build.sh` and `bash scripts/run-tests.sh --filter <Suite>` (full suite only for the final check). Bare Swift-toolchain build/test invocations are FORBIDDEN — they opt out of the mule, the machine-wide concurrency cap, and the sources cache, and pin work to a machine running many parallel agents (the repo has a guard that blocks them). `AUDIOUT_BUILD_LOCAL=1` only if the mule is unreachable, and report that you used it. Two traps: never pipe `run-tests.sh` through `| tail` or similar (the pipe eats the exit code — read the full output instead); never kill or abandon an in-flight remote test run (orphaned remote legs pin the build lock).

## Owned files (you may edit ONLY these)

- `AudioutCore/Sources/AudioutCore/`: `StoreRecovery.swift` (new), `GroupController.swift`, `GroupStore.swift`, `RoutingStore.swift`, `AppRouteStore.swift`, `ExcludedAppsStore.swift`, `DeviceIconStore.swift`, `DeviceEQStore.swift`, `BTTrimStore.swift`, `AppRoutingController.swift`, `ExcludedAppsController.swift`
- `AudioutCore/Sources/AudioutSharedUI/DeviceIcon.swift` — the `DeviceIconController.persist()` hunk only
- `AudioutCore/Sources/AudioutCore/NativeBackend.swift` — ONLY the four tiny hunks in Edit 9
- `AudioutCore/Sources/AudioutApp/AppDelegate.swift` — ONLY the three tiny hunks in Edit 10
- `dev/notes/stability-audit-2026-07-18.md` — Edit 11
- `AudioutCore/Tests/AudioutCoreTests/`: `StoreRecoveryTests.swift` (new), `GroupControllerTests.swift` (additions only)

## Do not touch

- `PopoverController.swift` or ANY file in `AudioutPopoverUI/`, `AudioutWindowUI/`, `AudioutSettingsUI/`, `AudioutOnboardingUI/` — a parallel track owns the popover/window layer. The swallowed-save bugs in `GroupCreationSheetController.swift:380` and `PopoverController.swift:3190` (hardening items 10/11) are NOT yours.
- `NativeBackend.swift` outside the four functions named in Edit 9. A parallel track (T1) owns regions around lines 5026, 6081, 7632, 8186, and 9608 (`btUsableTrimRangeMs`). Your nearest hunk (9589-9599) is 13 lines above T1's 9608 hunk — keep it strictly inside `resolveBTAlignmentPrompt`'s body.
- The `NativeBackend` store LOADS at `NativeBackend.swift:1473-1483` — they need no change (the quarantine lives inside the stores).
- Schema-NEWER files (a store returning empty for `schemaVersion > current`) — deliberate behavior, leave it (see Open decisions).
- No `lazy var` launch-order changes in AppDelegate (perf item 16 belongs to another track). No menu-bar failure state. No new abstractions beyond `StoreRecovery`. No cleanup, no refactors, no backwards-compat shims.

## Handoff notes (for the merge coordinator)

- **Notice surface decision:** user-visible reporting is ONE `NSAlert` per launch, presented by `AppDelegate` (Edit 10) — NOT the popover note slot, because a parallel track owns `PopoverController`. The seam is `StoreRecovery.quarantinedFileNames` + `StoreRecovery.onWriteFailure`; a later popover pass can re-route the same seam into the note slot without touching this track's stores.
- **T1 collision:** both tracks edit `NativeBackend.swift`. Our hunks: lines ~9420-9435 (`setBTSyncTrim`), ~9448-9458 (`resetBTAlignment`), ~9589-9599 (`resolveBTAlignmentPrompt`), ~9690-9705 (`endBTWizardLatencyPreview`). T1's nearest is `btUsableTrimRangeMs` (~9601-9613). Distinct functions; expect at worst context-line merge friction — keep both sides.
- `GroupController.updateDevices(_:)` (Edit 3) is the same "push, don't pull" shape the perf track's P0-1 fix wants for BT recency; independent files, no coordination needed.

---

## Verified facts

(all line numbers re-checked in this worktree, 2026-08-27)

- `GroupController.swift:144` — `self.groups = loadPersisted ? ((try? store.load()) ?? []) : []` swallows a decode throw; the next `store.save(groups)` atomically overwrites the corrupt file.
- Same swallow-load shape: `AppRoutingController.swift:50`, `ExcludedAppsController.swift:27`, `AudioutSharedUI/DeviceIcon.swift:114`, `NativeBackend.swift:1473-1483` (BTTrim ×3 + EQ).
- `GroupStore.load()` (`GroupStore.swift:116-122`) deliberately throws on real corruption ("that's a real corruption we don't want to hide", `GroupStore.swift:113-115`); its siblings share the shape: `RoutingStore.swift:79-85`, `AppRouteStore.swift:149-155`, `ExcludedAppsStore.swift:67-74`, `DeviceIconStore.swift:41-48`, `DeviceEQStore.swift:44-51`, and `BTTrimStore.swift:166-172` (`loadEnvelope()`, the single choke point behind `load`/`loadLatencies`/`loadDismissedUIDs` AND every writer's read-modify-write via `existingEnvelope()` at `BTTrimStore.swift:158-164`).
- Store file names: `groups.json` (`GroupStore.swift:94`), `routing.json` (`RoutingStore.swift:70`), `app-routes.json` (`AppRouteStore.swift:140`), `excluded-apps.json` (`ExcludedAppsStore.swift:58`), `device-icons.json` (`DeviceIconStore.swift:32`), `device-eq.json` (`DeviceEQStore.swift:36`), `bt-sync-trims.json` (`BTTrimStore.swift:96`).
- Swallowed WRITES (`try?` + no report): `GroupController.swift:221` (`persistRouting`), `AppRoutingController.swift:58` (`persist`), `ExcludedAppsController.swift:31`, `DeviceIcon.swift:118`, `NativeBackend.swift:9433` (`setBTSyncTrim`), `:9456` (`resetBTAlignment` → `clearAlignment`), `:9595` (`resolveBTAlignmentPrompt` → `saveDismissedUIDs`), `:9703-9704` (`endBTWizardLatencyPreview` → `saveLatencies` + `save`). `NativeBackend.saveEQLocked` (`NativeBackend.swift:2694-2699`) already catches and Telemetry-logs — leave it.
- `GroupController.saveGroup` (`:558-568`) mutates `groups` BEFORE `try store.save(groups)`; `deleteGroup` (`:629-634`) removes BEFORE saving and switches Main Out first. A throwing save leaves the failed change live in memory.
- `GroupController` reads `backend.devices` at exactly four places: `:189` (`ensureDefaultSelection`), `:228` (`devices`), `:232` (`device(_:)`, marked `STABILITY(C8)` at `:230`), `:272` (`localDeviceID`). On `NativeBackend`, `devices` is `stateQueue.sync` (`NativeBackend.swift:1600-1603`).
- The comment block `GroupController.swift:74-87` claims "`devices` (above) always reads `backend.devices` LIVE and on demand — `GroupController` never caches a device list"; the doc at `:226-227` claims "straight from the backend — never caches its own copy". Both become stale under Edit 3 and MUST be updated.
- `persistRouting()` (`GroupController.swift:217-222`, marked `STABILITY(D4)` at `:217`) synchronously JSON-writes on the main thread; callers: `ensureDefaultSelection` (`:213`), `setDeviceSelected` (`:333`, `:355`), `setMainOut` (`:461`). All main-thread.
- `AppDelegate.repaintFromCurrentState()` (`AppDelegate.swift:1666-1689`) already builds the snapshot (`Array(devicesByID.values)` at `:1673`) but AFTER calling `groupController.ensureDefaultSelection()` at `:1670`. `devicesByID` is folded from backend events at `:1524-1528`, so it is current when `repaintFromCurrentState` runs.
- `AppDelegate.applicationShouldTerminate` (`:1469-1503`) is the quit path; it runs synchronously on main until `return .terminateLater` at `:1502`.
- `installMainMenu()` is called at `AppDelegate.swift:447`; `groupController = GroupController(backend: backend)` at `:452`. AppDelegate stored properties (all the store-loading controllers, incl. `NativeBackend`) initialize before `applicationDidFinishLaunching` runs, so `StoreRecovery.quarantinedFileNames` is fully populated by then.
- `DeviceIcon.swift` (AudioutSharedUI) already does `import AudioutCore` (`DeviceIcon.swift:4`), so it can see `StoreRecovery`.
- `NSLock` + `.withLock` is house style (`NativeBackend.swift:308` `btTrimLock = NSLock()`, used at `:9426` etc.).
- Injected-closure seams are house style on these controllers (`AppRoutingController.onRoutesDidChange` `:40`, `GroupController.onMainOutMembersChanged` `:118`).
- Tests: `GroupControllerTests.swift` constructs controllers with injected `GroupStore(directory:)`/`RoutingStore(directory:)` in temp dirs; the reconnect-at-launch tests (`:301-345`) PRE-SAVE routing.json manually and never read back GroupController's own write — no existing test depends on `persistRouting` being synchronous (verified by grep over `Tests/`).
- Process-global test seams must nest under the `.serialized` `SerializedSharedState` parent suite, declared via `extension SerializedSharedState { @Suite final class ... }` (`Tests/AudioutCoreTests/SerializedSharedStateSuite.swift:33-46`).
- The AudioutApp executable target is not a test dependency (`AudioutCore/AGENTS.md`), so an `NSAlert` in AppDelegate can never flash during tests.
- Stability ledger entries C8 and D4 live at `dev/notes/stability-audit-2026-07-18.md:42-139`; both cover MORE sites than this track fixes, so neither entry moves to Resolved — they get partial-fix annotations (Edit 11).
- Baseline recorded before any change (2026-08-27, the exact Verification test command below): **PASSED — "Test run with 394 tests in 14 suites passed"**.

---

## Edits

### 1. New file `Sources/AudioutCore/StoreRecovery.swift`

WHY: one shared seam for "corrupt file set aside" and "swallowed save failed", so seven stores and five writers report through a single choke point instead of five new closures plus wiring.

Exact API (this IS the decision — implement exactly this surface; doc comments in your own words, noting `quarantine` is called by store `load()`s on decode failure and `onWriteFailure` may fire on any thread):

```swift
public enum StoreRecovery {
    /// File names (e.g. "groups.json") quarantined during this process's lifetime.
    public static var quarantinedFileNames: [String] { get }

    /// App-installed sink for swallowed save failures. May be invoked on any thread.
    public static var onWriteFailure: ((Error) -> Void)? { get set }

    public static func noteWriteFailure(_ error: Error)

    /// Move a corrupt store file aside so the next save cannot overwrite the evidence.
    public static func quarantine(_ fileURL: URL)
}
```

Behavior: all statics guarded by one private `NSLock`. `quarantine` renames `<base>.json` to `<base>.corrupt-<unix-seconds>.json` in the same directory — literal format: `"\(base).corrupt-\(Int(Date().timeIntervalSince1970)).json"` where `base` is `fileURL.deletingPathExtension().lastPathComponent`. Rename via `FileManager.default.moveItem(at:to:)`; on ANY move failure return silently (no retry, no throw). Only a successful move appends `fileURL.lastPathComponent` to the list. `noteWriteFailure` reads the handler under the lock, invokes it outside the lock, no-op when nil.

### 2. Quarantine hook in all seven stores

WHY: hardening P1 §3 — a truncated/corrupt file is currently discarded by the callers' `try?` and then atomically overwritten by the next save; the evidence must be moved aside before the throw propagates.

In each of these functions, wrap ONLY the `decoder.decode(Envelope.self, from: data)` line: on catch, call `StoreRecovery.quarantine(fileURL)` then rethrow the original error. Do NOT touch the `fileExists` guard, the `Data(contentsOf:)` read (an I/O error is not corruption — no quarantine), or the newer-schema early return.

- `GroupStore.swift` `load()` (:116-122)
- `RoutingStore.swift` `load()` (:79-85)
- `AppRouteStore.swift` `load()` (:149-155)
- `ExcludedAppsStore.swift` `load()` (:67-74)
- `DeviceIconStore.swift` `load()` (:41-48)
- `DeviceEQStore.swift` `load()` (:44-51)
- `BTTrimStore.swift` `loadEnvelope()` (:166-172) — the one choke point; do NOT touch the four public loads or `existingEnvelope()`. (Side effect, correct and intended: a corrupt file hit during a writer's read-modify-write gets quarantined and the save proceeds on a fresh envelope.)

Function-body semantics are otherwise unchanged: decode failure still throws, so every existing caller still lands on its empty default.

### 3. `GroupController` — pushed device snapshot (perf P1-3 / ledger C8)

WHY: `backend.devices` is `stateQueue.sync` on the shipping backend; click paths (`setDeviceSelected`, `ensureDefaultSelection`, mute, group activation) currently block the main thread on whatever the backend is doing.

In `GroupController.swift`:
- Add `private var pushedDevices: [Device]?` and `public func updateDevices(_ devices: [Device])` that stores it. Doc: the app layer pushes the same per-event snapshot `AppDelegate.repaintFromCurrentState` builds; until the first push (tests, harnesses) reads fall back to the live backend query.
- Change `public var devices: [Device]` (:228) to return `pushedDevices ?? backend.devices`, and rewrite its doc comment (:226-227) — the "never caches its own copy" claim is now false.
- Change `device(_:)` (:231-233) and `localDeviceID` (:272) to read `devices` (the property) instead of `backend.devices`. Delete the `STABILITY(C8)` marker comment at :230.
- Change `ensureDefaultSelection`'s read at :189 from `backend.devices.first(where: \.isLocalDevice)` to go through `devices` as well.
- Update the stale clause in the `memberState` comment block (:74-87): it asserts `devices` "always reads `backend.devices` LIVE" and "never caches a device list" — rewrite that sentence to describe the pushed-snapshot-with-fallback reality. Keep the rest of the block (the pruning rationale still holds).
- `backend.systemOutputVolume` (:210) stays as-is — it is served from a cached last-seen value on `NativeBackend` (`NativeBackend.swift:2990-2993`), not a blocking read.

### 4. `GroupController` — coalesced off-main routing persist (perf P1-4 / ledger D4)

WHY: every selection change serializes and writes JSON on the main thread inside a gesture; the ledger already attributes UI stalls to it.

Replace `persistRouting()` (:217-222) with a latest-wins writer on a private serial queue. Exact mechanism (implement this shape; naming as shown):

```swift
private let routingPersistQueue = DispatchQueue(label: "GroupController.routingPersist", qos: .utility)
private let routingPersistLock = NSLock()
private var pendingRoutingState: RoutingStore.State?

private func persistRouting() {   // main thread, as today
    let state = RoutingStore.State(selectedDeviceIDs: Array(selectedDeviceIDs).sorted(), mainOut: mainOut)
    let schedule: Bool = routingPersistLock.withLock {
        let wasIdle = pendingRoutingState == nil
        pendingRoutingState = state
        return wasIdle
    }
    guard schedule else { return }   // a flush is already enqueued; it will take the newest state
    routingPersistQueue.async { [weak self] in self?.flushRoutingStateNow() }
}

private func flushRoutingStateNow() {
    let state = routingPersistLock.withLock { () -> RoutingStore.State? in
        defer { pendingRoutingState = nil }
        return pendingRoutingState
    }
    guard let state else { return }
    do { try routingStore.save(state) } catch { StoreRecovery.noteWriteFailure(error) }
}

/// Drain any pending routing write synchronously — the quit path calls this so a
/// selection made just before quitting still lands on disk. Also a test seam.
public func flushPendingRoutingSave() {
    routingPersistQueue.sync { }
}
```

Invariant that makes the drain correct (state it in a comment): whenever `pendingRoutingState` is non-nil, at least one not-yet-run flush block is enqueued on the serial queue, so `routingPersistQueue.sync {}` returning means everything pending was written. Delete the `STABILITY(D4)` marker at :217. `ensureDefaultSelection`'s `try? routingStore.load()` (:197) stays synchronous — one launch-time read before any save can exist.

### 5. `GroupController` — write-to-copy for group CRUD (hardening item 9)

WHY: `saveGroup`/`deleteGroup` mutate `groups` before a throwing save, so the editor's alert says "didn't save" while the pane shows the edit applied — and the change silently vanishes at next launch.

Restructure both to save a local copy FIRST and commit to `self.groups` only on success (no snapshot/restore needed). Exact shapes:

```swift
@discardableResult
public func saveGroup(_ group: Group) throws -> Group {
    guard !group.memberIDs.isEmpty else { throw GroupError.emptyMembership }
    var updated = groups
    if let index = updated.firstIndex(where: { $0.id == group.id }) { updated[index] = group }
    else { updated.append(group) }
    try store.save(updated)
    groups = updated
    return group
}

public func deleteGroup(id: String) throws {
    var remaining = groups
    remaining.removeAll { $0.id == id }
    try store.save(remaining)
    groups = remaining
    if activeGroupID == id { activeGroupID = nil }
    if mainOut == .group(id: id) { setMainOut(.selectedDevices) }
}
```

Note the `deleteGroup` reorder: the Main Out fallback now runs AFTER the successful save. `setMainOut(.selectedDevices)` has no dependency on the deleted group (its `.selectedDevices` arm never reads `groups`), so behavior on the success path is unchanged; on the failure path nothing moves at all. Update the doc comments to match (`saveGroup`'s "guard runs before any mutation" sentence extends naturally to "a rejected or failed save leaves `groups` untouched").

### 6. `AppRoutingController.persist()` (:53-60) — report the swallowed save

WHY: per-app routes are user-tuned state; a disk-full failure currently loses them without a word.

Replace `try? store.save(appRoutes)` with `do { try store.save(appRoutes) } catch { StoreRecovery.noteWriteFailure(error) }`. `onRoutesDidChange?()` still fires unconditionally after (the in-memory table DID change; the backend must still see it). Delete the `STABILITY(D4)` marker at :53. This stays on the main thread — routes change at click frequency, not drag frequency; only `persistRouting` (Edit 4) earned a queue.

### 7. `ExcludedAppsController.persist()` (:30-32) — same do/catch → `noteWriteFailure`

WHY: a privacy denylist entry that fails to persist means the app IS captured again next launch — the one silent-save here with a privacy consequence.

### 8. `DeviceIconController.persist()` (`AudioutSharedUI/DeviceIcon.swift:117-119`) — same do/catch → `noteWriteFailure`

WHY: cosmetic state, but the failure means the disk is in trouble; the funnel is once-per-launch coalesced so reporting costs nothing.

### 9. `NativeBackend.swift` — four tiny hunks, same do/catch → `StoreRecovery.noteWriteFailure(error)`

WHY: BT trims, measured latencies and wizard results are minutes of the user's listening work; a "Keep" that silently didn't keep is the audit's item 12. All four sites run on UI/main threads (per surrounding comments), never the render path.

- `:9433` in `setBTSyncTrim`: `try? btTrimStore?.save(all)` → do/catch. (Only inside the existing `if persist { }` — scrubs still skip disk.)
- `:9456` in `resetBTAlignment`: `try? btTrimStore?.clearAlignment(deviceUID: id)` → do/catch. (One site beyond the audit's list — identical failure class in the same extension; a failed clear silently keeps a stale alignment.)
- `:9595` in `resolveBTAlignmentPrompt`: `try? btTrimStore?.saveDismissedUIDs(all)` → do/catch.
- `:9703-9704` in `endBTWizardLatencyPreview`: wrap BOTH `saveLatencies(latencies)` and `save(trims)` in ONE `do { } catch { StoreRecovery.noteWriteFailure(error) }` block.

Nothing else in this file. Do not reformat neighbors.

### 10. `AppDelegate.swift` — three tiny hunks

WHY: the seam needs exactly one consumer that makes failures user-visible, and the snapshot/flush seams need their single production caller.

**(a) Snapshot push** — in `repaintFromCurrentState()` (:1666-1689): move the `let devices = Array(devicesByID.values)` line (currently :1673) to the TOP of the method, add `groupController.updateDevices(devices)` immediately after it, and only then call `groupController.ensureDefaultSelection()` (so the seed reads the fresh snapshot). The rest of the method body is untouched and keeps using the same `devices` local.

**(b) Failure notice wiring** — in `applicationDidFinishLaunching`, immediately after `installMainMenu()` (:447), add:
- Set `StoreRecovery.onWriteFailure = { [weak self] error in DispatchQueue.main.async { self?.presentStoreDataAlertOnce(message: ..., info: ...) } }` with message `"Audiout couldn't save a settings change"` and info `"\(error.localizedDescription)\n\nRecent changes may be lost when Audiout quits. Check that the startup disk isn't full."`
- Then: `if !StoreRecovery.quarantinedFileNames.isEmpty { DispatchQueue.main.async { ... } }` presenting message `"Some of Audiout's saved settings couldn't be read"` and info `"The unreadable files were set aside so nothing is lost: \(StoreRecovery.quarantinedFileNames.joined(separator: ", ")). The affected settings are back to their defaults. Everything else is untouched."` (The async dispatch lets launch finish before any modal.)
- Add a private method `presentStoreDataAlertOnce(message:info:)` and a `private var storeDataAlertShown = false`: guard the flag (set it), `NSApp.activate(ignoringOtherApps: true)`, then an `NSAlert` with `alertStyle = .warning`, the given `messageText`/`informativeText`, one "OK" button, `runModal()`. One alert per launch total, across both kinds — first event wins.

**(c) Quit flush** — in `applicationShouldTerminate` (:1469-1503), add `groupController.flushPendingRoutingSave()` right after `eventTask = nil` (:1474). It drains a utility-QoS queue holding at most one small JSON write — bounded and effectively instant.

### 11. Stability ledger — `dev/notes/stability-audit-2026-07-18.md`

WHY: docs land with code (root AGENTS.md); the ledger explicitly instructs marker deletion on fix, but both entries are only PARTIALLY resolved by this track, so neither moves to Resolved.

- C8 entry (:42-73): add one line noting the `GroupController.device(_:)`/`devices` read-through is fixed (pushed snapshot, this branch) and its marker deleted; the two `NativeBackend` sites remain open.
- D4 entry (:75-139): add one line under "Sync persistence on main per gesture" noting both listed sites are fixed (coalesced off-main writer / reported failure, this branch) and their markers deleted; all other D4 sub-items remain open.

### 12. Tests

**New file `Tests/AudioutCoreTests/StoreRecoveryTests.swift`** — declared as `extension SerializedSharedState { @Suite final class StoreRecoveryTests: IsolatedSuite { ... } }` (it installs the process-global `onWriteFailure` handler, so it must serialize; do NOT add `.serialized` on the child — see `SerializedSharedStateSuite.swift`). Tests:
1. One quarantine test per store (seven): in a fresh `scratchDir` subdirectory, write garbage bytes (e.g. `Data("not json".utf8)`) at the store's file name, construct the store with `directory:` injection, expect `load()` (for `BTTrimStore`: `load()`) to throw, then assert the original file no longer exists, exactly one file matching `*.corrupt-*.json` exists in the directory, and a second `load()` returns the empty/nil default without throwing. Assert `StoreRecovery.quarantinedFileNames.contains(<file name>)` (contains, not equality — the list is process-global and accumulates).
2. `quarantineOnMissingFileRecordsNothing`: `StoreRecovery.quarantine` on a nonexistent URL leaves the directory empty and records nothing new.
3. Controller-level end-to-end: corrupt `groups.json` in a scratch dir → `GroupController(backend:store:GroupStore(directory:), loadPersisted: true)` initializes with `groups == []` and the file is quarantined (pins that the `try?` caller still triggers quarantine). Copy the `makeBackend()` helper shape from `GroupControllerTests.swift:24-60`.
4. `writeFailureFiresHandler`: create a FILE at `scratchDir/"blocker"`, then `AppRoutingController(store: AppRouteStore(directory: blockerURL.appendingPathComponent("x")), loadPersisted: false)` — the save fails because `createDirectory` cannot make a directory under a file. Install `StoreRecovery.onWriteFailure` capturing into a local, `defer { StoreRecovery.onWriteFailure = nil }`, call `addRoute(bundleID:displayName:)`, assert the handler fired once and `appRoutes.count == 1` (the in-memory change survives; only the disk write failed).

**Additions to `GroupControllerTests.swift`** (existing suite, existing helpers):
5. `saveGroupFailedPersistLeavesModelUntouched`: controller whose `GroupStore` points below a blocker FILE (same trick as test 4), `loadPersisted: false`; `#expect(throws:)` on `saveGroup(...)`; then `controller.groups.isEmpty`.
6. `deleteGroupFailedPersistKeepsGroup`: writable store dir; save group `"g1"`; then make the directory unwritable via `FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)` with a `defer` restoring `0o755`; expect `deleteGroup(id: "g1")` throws and `controller.groups.map(\.id) == ["g1"]`.
7. `routingSelectionPersistsAfterFlush`: controller with injected `RoutingStore(directory: dir)`; `ensureDefaultSelection()`; `setDeviceSelected("office", true)`; `controller.flushPendingRoutingSave()`; `try routing.load()` state has `selectedDeviceIDs == ["office"]`.
8. `pushedSnapshotFeedsDeviceReads`: `controller.updateDevices([...])` with a fabricated `[Device]` list, then `controller.devices` returns exactly that list (not the backend's).

Do not modify or delete any existing test.

**Order of work:** Edit 1 → 2 → 3/4/5 → 6/7/8 → 9 → 10 → 11 → 12. The build stays green after every numbered edit (Edits 3-9 are self-contained behavior changes; Edit 10 is the only consumer wiring).

---

## Verification

Baseline recorded before any change (2026-08-27, this exact test command): **PASSED — "Test run with 394 tests in 14 suites passed"**.

```bash
bash scripts/build.sh
bash scripts/run-tests.sh --filter GroupControllerTests --filter AppRoutingControllerTests --filter ExcludedAppsTests --filter DeviceIconStoreTests --filter DeviceIconResolverTests --filter AppRouteStoreTests --filter BTTrimStoreTests --filter DeviceEQStoreTests --filter GroupIconPersistenceTests --filter GroupMasterVolumePersistenceTests --filter NativeBackendTests --filter StoreRecoveryTests
```

Run both plain (no `| tail`, no pipes — the pipe eats the exit code). Expected after the change: build clean; test run passes with MORE than 394 tests (baseline 394 + the ~12 new ones), zero failures. Then the commit itself: Guard 7 (`scripts/self-review.sh` against `docs/REVIEW-RUBRIC.md`) before committing, and Guard 4 runs the FULL suite on commit — that full-suite pass is part of done. Push the branch to `origin/claude/fix-data-safety`. Do NOT merge to `main` — merging needs Alec's explicit go-ahead (standing rule).

## Acceptance checklist

- [ ] Corrupting any of the seven store files yields, on next load: file renamed `<base>.corrupt-<unix-seconds>.json`, empty defaults, no crash — pinned by tests, all seven stores.
- [ ] `saveGroup`/`deleteGroup` on a failing store throw AND leave `groups` exactly as before — pinned by tests 5/6.
- [ ] No `try?`-swallowed save remains at the eight listed write sites (`git grep` for `try? store.save`, `try? routingStore`, `try? btTrimStore` in owned files finds none at those sites; `saveEQLocked` untouched).
- [ ] `GroupController` contains zero direct `backend.devices` reads except the documented fallback inside the `devices` property itself.
- [ ] `persistRouting` performs no disk I/O on the calling thread; `flushPendingRoutingSave()` is called from `applicationShouldTerminate`.
- [ ] `STABILITY(C8)` marker gone from `GroupController`; `STABILITY(D4)` markers gone from `GroupController` and `AppRoutingController`; ledger annotated; no other marker touched.
- [ ] No file outside the "Owned files" list is modified (review `git status` before committing).
- [ ] Verification commands run in-session with output pasted.

## Open decisions (defaults chosen — apply them, don't ask)

1. **Schema-newer files** are still silently returned-as-empty and overwritten by the next save (the same loss shape for a DOWNGRADE). Default: out of scope, leave untouched; the audit scoped this track to decode corruption only.
2. **No Telemetry line on quarantine.** Default: skip — the quarantined file itself is the evidence; adding telemetry is scope creep.
3. **Write-failure alert granularity**: one alert per launch across all stores and both failure kinds. Default: keep — a full disk fails everything at once; N alerts would be hostile.

## Executor rules (verbatim)

> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.
