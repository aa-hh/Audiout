# Work order — Ticket 02b: keep "used" wired rows greyed through an unplug

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cpi-consumption-analysis-2e6406` (branch `claude/handoff-local-wired-outputs-3b2085`). Ticket 02 is built and UNCOMMITTED in this worktree; this order edits on top of it. All paths relative to the worktree.

## Goal

Ticket 02 removes a wired row the moment its output is unplugged. The owner decided (2026-09-26) that an unplugged wired output stays as a greyed row (`isAvailable == false`) while it is "used" — selected, or an app is routed to it, or it is a member of any saved group — and is removed only when it is not used, or the moment it stops being used. Replug makes the kept row available again. This keeps a headphone row a saved group or an app route names from vanishing and taking that reference with it, and gives ticket 03's replug re-arm a row to find.

## Verified facts

- `NativeBackend+Wired.swift:14-41` (built, uncommitted) is `applyWiredSnapshots` on `stateQueue`: the update branch `:16-19` writes only `name` and `wiredTransport` (never `isAvailable = true`, so a replugged kept row would stay greyed forever); the unplug loop `:33-40` commits `isAvailable = false` then deletes the row and emits `.deviceRemoved`. Its doc `:9-13` says rows leave on unplug.
- The only caller dispatches on `stateQueue`: `NativeBackend.swift:2080` `self?.stateQueue.async { self?.applyWiredSnapshots(snapshots) }`.
- "Used" inputs, all internal stored state on `NativeBackend`, all read on `stateQueue`: `expectedSelected: Set<String>` (`NativeBackend.swift:876`), `lastRoutes` (`:1384`), `lastGroupTargets: [String: GroupRouteTarget]` (`:1391`). `routesTargetDeviceLocked(_ id:)` (`NativeBackend+PerAppRouting.swift:71-78`) answers "a `.device` route names it or a `.group` route's resolved membership holds it". `GroupRouteTarget(memberVolumes:)` is built for every saved group in `AppRoutingController.resolveGroupTargets` (`AppRoutingController.swift:247-252`), filtered by kind only, never by availability.
- `expectedSelected` is written kind-blind at `NativeBackend+Tone.swift:333` (`self.expectedSelected = ids`, inside `setOutputSet`'s `stateQueue.sync`). `lastGroupTargets` is written at `NativeBackend+PerAppRouting.swift:254` (`self.lastGroupTargets = groupTargets`, inside `updateAppRoutes`'s `stateQueue.sync`).
- `commitKnownDevice(_:_:)` (`NativeBackend.swift:4877-4882`) writes `known[id]`, emits `.deviceUpdated`, and replays per-app routes when eligibility moved. `setConnectionState(_:for:)` is `NativeBackend.swift:5601`, on `stateQueue`. The Bluetooth deselect arm keeps a `.failed` story and otherwise writes `.off`: `NativeBackend+Tone.swift:524-528`.
- `emit(_:)` is `NativeBackend+Metering.swift:308`; `known`/`order` are `NativeBackend.swift:753-754`.
- `AppDelegate.swift:2753` is `if isNew, hasGroupRoute { pushAppRoutesToBackend() }` inside the `.deviceAdded`/`.deviceUpdated` arm; `hasGroupRoute` is `AppDelegate.swift:2472-2477`; `pushAppRoutesToBackend()` (`:2488-2493`) resolves every saved group against `devicesByID` and calls `updateAppRoutes`. Without the guard change, a wired row plugged in after launch is absent from `lastGroupTargets` until the next route or group edit, so its unplug reads "not in a group".
- `PopoverController.swift:924` deselect-on-loss is `device.isBluetooth && !device.isAvailable` and stays that way (settled): a selected wired row keeps its selection through an unplug, which is what makes it "used".
- `PopoverController.swift:964` route reset runs only `where devicesByID[goneID] == nil`; a kept unavailable row is still in `devicesByID`, so no route is reset for it.
- A wired id in `setOutputSet` with no `outputIDs` entry is skipped by the engine guard (`NativeBackend+Tone.swift:376-379`), so selecting one in the test harness is safe.
- Test harness: `NativeBackendWiredDevicesTests.swift` (built, uncommitted) has `FakeWiredEnumerator` (`:18-31`), `EventCollector` over `backend.makeEventStream()` (`:109-123`), `makeBackend()` (`:127-137`), fixtures `dac`/`jack` (`:149-151`), and `unpluggedOutputLeavesTheList` (`:176-202`) which today asserts a `.deviceUpdated(isAvailable == false)` followed by `.deviceRemoved` for an unselected, unrouted, ungrouped row — still the correct expectation for an UNUSED row.
- `updateAppRoutes(_:excludedBundleIDs:groupTargets:)` is public on `NativeBackend` (`NativeBackend+PerAppRouting.swift:242-245`), so a test can push a `GroupRouteTarget` naming the jack.

## Steps

Settled and final: used = `expectedSelected.contains(id) || routesTargetDeviceLocked(id) || lastGroupTargets.values.contains { $0.memberVolumes[id] != nil }`; one helper `pruneUnusedWiredLocked()`; three call sites; replug through `commitKnownDevice`; `.off` on unplug unless `.failed`; `AppDelegate.swift:2753` drops `hasGroupRoute` entirely; popover untouched; no ticket-03 re-arm (`beginBTConnectingLocked` / `reapplyBTSinkLocked`) here; plug-then-instant-unplug race accepted, untested.

1. **Tests first (`AudioutCore/Tests/AudioutCoreTests/NativeBackendWiredDevicesTests.swift`), run, paste the failing output.**
   - Keep `unpluggedOutputLeavesTheList` (`:176-202`) as is; retitle its doc comment to say it covers an UNUSED row (not selected, routed, or grouped).
   - Add `usedUnpluggedRowStaysGreyedUntilReleased` — defect: an unplugged selected headphone row vanishing and taking its selection with it. Start, fire `[dac, jack]`, wait for both rows; `backend.setOutputSet([jack.id])`; fire `[dac]`; wait until the jack row reads `isAvailable == false` and `connectionState == .off`; then assert no `.deviceRemoved(jack.id)` is in the collector (settle briefly with `SuiteWait.settle` the way `BTDeviceEnumeratorTests.swift:285` does). Then `backend.setOutputSet([])` and wait for `.deviceRemoved(jack.id)` and for `device(backend, jack.id) == nil`.
   - Add `groupMemberUnpluggedRowStaysUntilGroupReleasesIt` — defect: a saved-group member vanishing on unplug because the backend reads only selection. Start, fire `[dac, jack]`; `backend.updateAppRoutes([], groupTargets: ["g1": GroupRouteTarget(memberVolumes: [jack.id: 100])])`; fire `[dac]`; wait for the jack row unavailable; assert no `.deviceRemoved(jack.id)`; then `backend.updateAppRoutes([], groupTargets: [:])` and wait for `.deviceRemoved(jack.id)`.
   - Add `replugRestoresAvailability` — defect: a kept greyed row never coming back after replug. Start, fire `[dac, jack]`, `setOutputSet([jack.id])`, fire `[dac]`, wait for jack unavailable; fire `[dac, jack]`; wait for the jack row `isAvailable == true`; assert the collector has no `.deviceRemoved(jack.id)` and no second `.deviceAdded` for the jack (the row was updated, not re-added).
   - Run `bash scripts/run-tests.sh --filter NativeBackendWiredDevicesTests` (timeout 600000). Expected: the three new tests fail (the jack row is removed and/or never comes back); `unpluggedOutputLeavesTheList` and `snapshotBecomesAWiredRowKeyedByUID` still pass. Paste the output.

2. **`AudioutCore/Sources/AudioutCore/NativeBackend+Wired.swift`** — rewrite `applyWiredSnapshots`:
   - Update branch (`:16-19`): also set `device.isAvailable = true`; keep the `if device != known[…] { commitKnownDevice }` shape (that call is what replays a demoted per-app route on replug).
   - Unplug loop (`:31-40`): for each `id in order` where `known[id]?.kind == .wired` and not present, skip if already `isAvailable == false`; otherwise copy, set `isAvailable = false`, and if `connectionState` is not `.failed` set it to `.off` on the copy (mirror `NativeBackend+Tone.swift:524-528`; write it on the copy before the single `commitKnownDevice` so one `deviceUpdated` carries both), then `commitKnownDevice(id, device)`. Do NOT delete the row or emit `.deviceRemoved` here.
   - After the loop call `pruneUnusedWiredLocked()`.
   - Add `func wiredRowIsUsedLocked(_ id: String) -> Bool` on `stateQueue` returning exactly the settled expression, with a doc naming the three arms and why `btPerAppClaimedUIDs` is NOT used (post-eligibility; an unavailable row is already demoted out of it).
   - Add `func pruneUnusedWiredLocked()` on `stateQueue`: for every `id in order` where `known[id]?.kind == .wired`, `known[id]?.isAvailable == false`, and `!wiredRowIsUsedLocked(id)`: `known[id] = nil`, `order.removeAll { $0 == id }`, `emit(.deviceRemoved(id: id))`. Doc: called on every edge that can change "used" (snapshot, selection write, route/group push).
   - Replace the doc at `:9-13`: an unplugged output's row is kept greyed while used and removed once unused; the availability edge goes through `commitKnownDevice`; ticket 03 owns re-arming a kept selected row on replug.

3. **`AudioutCore/Sources/AudioutCore/NativeBackend+Tone.swift:333`** — immediately after `self.expectedSelected = ids`, call `self.pruneUnusedWiredLocked()` (inside the same `stateQueue.sync` block), with a one-line comment: a deselected greyed wired row leaves the list here.

4. **`AudioutCore/Sources/AudioutCore/NativeBackend+PerAppRouting.swift:254`** — immediately after `self.lastGroupTargets = groupTargets`, call `self.pruneUnusedWiredLocked()` (inside the same `stateQueue.sync` block), with a one-line comment: covers a cleared route and a group edit/delete, both of which re-push through here.

5. **`AudioutCore/Sources/AudioutApp/AppDelegate.swift:2753`** — change `if isNew, hasGroupRoute { pushAppRoutesToBackend() }` to `if isNew { pushAppRoutesToBackend() }`. Rewrite the comment at `:2748-2752` to say every new arrival re-pushes so the backend's saved-group membership (`lastGroupTargets`) includes a device plugged in after launch; the cost is one `updateAppRoutes` per arrival, the same call every route edit and reachability flip already makes. Leave the `.deviceRemoved` arm's `if hasGroupRoute` (`:2757`) unchanged.

6. **`.scratch/local-wired-outputs/issues/02-wired-kind-and-enumerator.md`** — under `## Change`, replace the sentence "Removal on unplug; a selected row that vanishes is deselected on the edge in the popover, like Bluetooth." with: "An unplugged output's row stays greyed while used (selected, app-routed, or a saved-group member) and is removed once unused; replug restores it; the popover's deselect-on-loss edge stays Bluetooth-only." Under `## Tests`, add a line for the three tests in step 1.

7. Run the Verification commands.

## Out of scope — do not touch

- `PopoverController.swift` (`:924` stays Bluetooth-only; `:964` unchanged) and every other `AudioutPopoverUI` file — ticket 04.
- `beginBTConnectingLocked`, `reapplyBTSinkLocked`, `reconcileSilenceWatchdog`, `btSelectedUIDs`, any sink or arm-gate change — ticket 03 (its step 7 adds the replug re-arm on top of this).
- `isRouteTargetReachableLocked` and the three `isBluetooth` widenings in `NativeBackend+PerAppRouting.swift` — ticket 05.
- `WiredOutputEnumerator.swift`, `Device.swift`, `OutputBackend.swift`, `DeviceDetailViewController.swift`, `GroupController`, `GroupStore`, `CompanionSnapshotBuilder`.
- The `.deviceRemoved` arm at `AppDelegate.swift:2755-2758`.
- No test for the plug-then-instant-unplug race (accepted). No AGENTS.md edit. No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. Do not commit or push.

## Verification

Test seam: `NativeBackendWiredDevicesTests.swift` (step 1); the defect each new test catches is stated there.

```
bash scripts/run-tests.sh --filter "NativeBackendWiredDevicesTests|NativeBackendBTDevicesTests|NativeBackendBTSelectionTests|AppRouteEligibilityReplayTests"
```
→ all pass; the run must print `Test run with N tests` with N ≥ 5 for the wired suite (a no-match filter reports green, so a run listing 0 tests is a failure). If `AppRouteEligibilityReplayTests` does not exist as a suite name, drop it from the filter and say so; the other three names are on disk.

```
bash scripts/build.sh
```
→ exit 0 (the `AudioutApp` target is not compiled by the test run; this proves the `AppDelegate` edit).

Foreground, timeout 600000. On a timeout: `bash scripts/capacity.sh status` once, retry once, then stop and report `blocked on capacity` with that output.

## Execution plan

One track. Files: `NativeBackend+Wired.swift`, `NativeBackend+Tone.swift`, `NativeBackend+PerAppRouting.swift`, `AudioutApp/AppDelegate.swift`, `NativeBackendWiredDevicesTests.swift`, the ticket file. Model: sonnet. Effort: medium (the logic is small and every line is cited; the only care point is keeping both prune calls inside their `stateQueue.sync` blocks). SERIAL after ticket 02's built tree (it edits 02's files), PARALLEL with nothing else in this batch that touches these files — ticket 03's order edits `NativeBackend+PerAppRouting.swift:1747-1781` and `NativeBackend+Bluetooth.swift`, so run 03 after this merges or the runner must merge the shared file. The worktree holds ticket 02's uncommitted work, which this track depends on; an isolated worktree forked from the last commit would NOT have it.

## Executor rules (copy verbatim into the handoff prompt)
> - Follow the steps in order. Do not add, merge, reorder, or skip steps.
> - Before editing in any folder, read the nearest AGENTS.md above it (and the root one) if the repo has them — folder rules and traps bind even when the work order doesn't repeat them.
> - If reality contradicts a Verified fact or a step is impossible as written, STOP and report the discrepancy. Do not improvise a workaround.
> - Before reporting progress, audit each claim against a tool result from this session. Only report work you can point to evidence for. If tests fail, say so with the output.
> - If the work order names a new test, run it before making the change and paste the failing output. A test that passes before the change proves nothing.
> - "Done" means the Verification commands were run in this session and passed. Paste their output.
> - Touch nothing in the Out-of-scope list.
> - Deliver what was asked, at the scope intended. If the spec seems mistaken or a better approach exists, say so in a sentence and continue as specified rather than quietly narrowing, widening, or transforming it.

## Cross-area questions

None.

---

Note for the coordinator: the `AppRouteEligibilityReplayTests` suite name in the filter is a guess at the suite covering `routesTargetDeviceLocked`; I did not confirm it exists, so the order tells the executor to drop it if absent. Everything else is cited against the built tree.