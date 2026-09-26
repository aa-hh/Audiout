Changed since the last report: scope-ui asked whether the popover needs a "keep" filter; answered no (the backend already sees saved groups through `lastGroupTargets`), and scope-ui dropped 04's wired deselect test and AGENTS.md line. Everything else stands.

## Answers

**1. Route reset and unavailable wired rows.**
Confirmed. The reset at `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cpi-consumption-analysis-2e6406/AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift:964` is `for goneID in previous.subtracting(nowValid) where devicesByID[goneID] == nil`. A row kept as unavailable is still in `devicesByID`, so `handleDeviceDisappeared` (`AppRoutingController.swift:274-284`) never runs for it. Its doc at `:266-273` already says "GONE means gone from the snapshot, NOT merely isAvailable == false".

Demote/restore matches an off Bluetooth speaker once ticket 05 step 2 lands: `isRouteTargetReachableLocked` (`NativeBackend+PerAppRouting.swift:28-31`) guards `device.isAvailable` first, then `outputIDs[id] != nil || device.isBluetooth` (to be widened to `|| device.isWired`). The unplug commit goes through `commitKnownDevice` (`NativeBackend+Wired.swift:36`), which samples eligibility before and after and calls `rerunAppRoutesIfTargeted` (`NativeBackend.swift:4877-4882`, `:4856-4863`), so the route is demoted on unplug and restored on replug with no route-table edit.

Replug gap, sent to scope-sink: the update branch at `NativeBackend+Wired.swift:16-19` writes only `name` and `wiredTransport`, never `isAvailable = true`. Harmless today (the row is deleted at `:37`) but with the keep rule a replugged row would stay unavailable forever. The rewrite must set it and commit through `commitKnownDevice`.

"Selected" arm: the popover deselect-on-loss at `PopoverController.swift:924` is `device.isBluetooth && !device.isAvailable`, so a wired row stays selected through an unplug, which is what makes it "used" and what 03 step 7's replug re-arm (`expectedSelected.contains(id)`) needs. scope-ui confirmed 04 leaves `:924` Bluetooth-only.

**2. Where saved groups live; does the backend see them.**
`GroupController` owns them: `private(set) public var groups: [Group]` (`GroupController.swift:63`) backed by `private let store: GroupStore` (`:59`), built once in `AppDelegate.swift:993`. Main-thread state, not safe to read from `stateQueue`.

The backend already holds every saved group, active or not: `NativeBackend.lastGroupTargets` (`NativeBackend.swift:1386-1391`, "The saved groups' resolved per-app-route memberships"). Fed by `updateAppRoutes(_:excludedBundleIDs:groupTargets:)`, whose doc says "`groupTargets` is every saved group resolved" (`OutputBackend.swift:539-541`); `AppDelegate.pushAppRoutesToBackend` (`:2488-2493`) resolves `groupController.groups` and `resolveGroupTargets` loops `for group in groups` (`AppRoutingController.swift:246-253`), filtered only by `canBePerAppRouteTarget()` (kind only, `AppRouteTargetEligibility.swift:28-32`, wired qualifies), never by availability. So a kept unavailable wired member stays in it. Both scope-sink and scope-ui grepped for `GroupStore|memberIDs` and missed it because the backend copy is keyed by `memberVolumes`.

The keep decision lives in the backend (it owns `known`/`order`); no closure, no popover filter. Membership test on `stateQueue`: `lastGroupTargets.values.contains { $0.memberVolumes[id] != nil }`.

Staleness caveat (load-bearing): `lastGroupTargets` is re-pushed on a new device only `if isNew, hasGroupRoute` (`AppDelegate.swift:2753`; `hasGroupRoute` at `:2472-2477`). With no app group-routed, a wired row plugged in after the launch push (`:1394`) is absent from `lastGroupTargets` until the next route edit or group edit (`:1067-1075`), so its unplug would read "not in a group". Fix: drop `hasGroupRoute` from the `.deviceAdded` guard at `:2753`. `updateAppRoutes` already runs on every route edit and every reachability flip (`rerunAppRoutesForReachabilityChange`, `NativeBackend+PerAppRouting.swift:193-202`), so one more call per device arrival is the same cost.

**3. Backend state for per-app routes to a device id.**
Raw intent: `lastRoutes: [AppRoute]` (`NativeBackend.swift:1384`) plus `lastGroupTargets` (`:1391`), both set in `updateAppRoutes` (`NativeBackend+PerAppRouting.swift:250-254`). The ready-made test is `routesTargetDeviceLocked(_ id:)` (`:71-79`): true for a `.device` route naming the id or a `.group` route whose resolved membership holds it. The `sets` at `:1746` (and `btPerAppClaimedUIDs`, `NativeBackend.swift:634`) are the post-eligibility mixer topology: a route to an unavailable row is already demoted out of them (`effectiveAppRoutesLocked`, `:138`), so they must not be used for "used".

Full expression, adopted by scope-sink: `expectedSelected.contains(id) || routesTargetDeviceLocked(id) || lastGroupTargets.values.contains { $0.memberVolumes[id] != nil }` (`expectedSelected` at `NativeBackend.swift:876`).

**4. Step 4 collapsed; the observing spy.**
Ticket 03 chose reuse (03 Goal, Interface "Arming"); scope-sink confirmed. Step 4 becomes: widen the three `isBluetooth` tests at `NativeBackend+PerAppRouting.swift:30`, `:1747`, `:1781` to `isBluetooth || isWired`; nothing else changes. `btPerAppClaimedUIDs`, `btArmingLocked()` (`NativeBackend+Bluetooth.swift:219-222`), `btSink?.setPerAppClaimedUIDs` (`:1765`) and `btPerAppFeeds` (`:1789`) all take plain UID strings. 03 step 5 adds one `reportedLatencyUIDs:` argument at `:1760-1762`; same file, serial, no conflict.

Spy: `SpyBTSink` in `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cpi-consumption-analysis-2e6406/AudioutCore/Tests/AudioutCoreTests/NativeBackendBTSelectionTests.swift:198-199` records `setPerAppClaimedUIDs` into `perAppClaimedUIDCalls` (`:238-239`); existing tests assert on it at `:1254-1319`. Nothing to add. It is `private` to that suite; 03 step 1 copies it into `NativeBackendWiredSinkTests.swift` (not on disk yet; `ls` shows only `NativeBackendWiredDevicesTests` and `WiredOutputEnumeratorTests`), so the step 4 test lives there and waits on `sink.perAppClaimedUIDCalls.last == [jack.id]` after `updateAppRoutes` with a `.device(jack.id)` route, mirroring `:1236-1260`. The `NativeBackendWiredDevicesTests` harness cannot host it (no spy sink; `NoOpEngine` only, `:33-40`).

## Corrections to the draft

- **Verified fact line 12 / step 2**: correct as written; add that the guard order (`isAvailable` first) is what makes a kept unavailable wired row demote and restore exactly like Bluetooth (`:29-30`, `commitKnownDevice` `NativeBackend.swift:4877-4882`).
- **Verified fact line 15**: incomplete. Add: the backend holds every saved group's resolved membership in `lastGroupTargets` (`NativeBackend.swift:1386-1391`, fed from `AppDelegate.swift:2488-2493`), which is what the keep rule reads.
- **Verified fact line 20** (wired row removed on unplug, route lost): wrong under the owner's decision. Replace with: a used wired row stays in the snapshot as unavailable, so `PopoverController.swift:964`'s `devicesByID[goneID] == nil` guard skips it and `handleDeviceDisappeared` never fires; the route is demoted by the effective table and restored on replug via `commitKnownDevice`'s replay. An unused row is removed; `handleDeviceDisappeared` no-ops for it because nothing routes to it (`AppRoutingController.swift:282`).
- **Verified fact line 21** (group editor has no row to grey): resolved. A group member is "used" by definition, so it stays in `devices` as unavailable and `GroupEditorViewController.swift:826-838` greys it like a dropped AirPlay device. No placeholder needed.
- **Step 4**: collapse to form (a): widen `:30`, `:1747`, `:1781` to `isBluetooth || isWired`; delete form (b). Name the test: in `NativeBackendWiredSinkTests` (03's file), after 03 lands, `routeToAWiredRowClaimsItForPerAppDelivery`: start, fire the jack snapshot, `updateAppRoutes([route("com.foo", toDevice: jack.id)])`, wait for `sink.perAppClaimedUIDCalls.last == [jack.id]`; defect: the wired UID never reaches the sink's per-app claim set, so the app's stream has no delivery path. Verification filter must add `NativeBackendWiredSinkTests`.
- **Out of scope line 45**: keep the reset out of scope, but change the reason: no UI change is needed; the keep rule in `applyWiredSnapshots` (ticket 02 amendment, scope-sink) makes the existing reset correct.
- **Execution plan**: add the AudioutApp one-liner (or hand it to the ticket-02 amendment): drop `hasGroupRoute` from `if isNew, hasGroupRoute { pushAppRoutesToBackend() }` at `AppDelegate.swift:2753`. Without it, the saved-group arm of "used" is blind to any wired row plugged in after launch while no app is group-routed. Cross-area questions 3 and 4 close with the owner's decision.

## Sent to teammates

- scope-sink: the three-part "used" expression with file:line; do not use `sets`/`btPerAppClaimedUIDs`.
- scope-sink: replug bug (`NativeBackend+Wired.swift:16-19` never sets `isAvailable = true`); commit through `commitKnownDevice`; 03 step 7's reapply trigger should key on an availability edge like `desiredAvailabilityMoved` (`NativeBackend+Bluetooth.swift:654-656`, `:733`, `:747-750`).
- scope-ui: keep `PopoverController.swift:924` Bluetooth-only; the `:964` reset does not fire for a kept row; the group editor greys it for free.
- scope-ui: no popover "keep" filter wanted; the backend already sees saved groups via `lastGroupTargets`, and its shape (B) happens without a closure.
- scoper: `lastGroupTargets` staleness and the `AppDelegate.swift:2753` guard fix.
- Folded in: scope-sink confirmed reuse and the spy, withdrew its `setSavedGroupMemberIDs` entry point, adopted the expression above. scope-ui dropped 04's `selectedWiredRowIsDeselectedOnAvailabilityLoss` test and its AGENTS.md line.

## Still open

- Whether the `:2753` guard is dropped entirely or narrowed to `hasGroupRoute || device.isWired`. Both work; the dropped guard is shorter. scoper's call.
- Launch-time race: a wired row's `deviceAdded` reaches AppDelegate on the main thread and the re-push lands on `stateQueue` later, so an unplug inside that window reads "not in a group". Only a test that fires add and an empty snapshot back-to-back would show whether it matters.