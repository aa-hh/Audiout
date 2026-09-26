# Revised after team scoping: sink, ui, routing

# Work order — Ticket 05: wired rows as per-app destinations, saved-group members, companion snapshot

Worktree: `/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/cpi-consumption-analysis-2e6406` (branch `claude/handoff-local-wired-outputs-3b2085`). Ticket 02 is built on disk, uncommitted. This order runs after tickets 02, 02b (keep-while-used amendment) and 03 are on the branch; step 4's test lives in ticket 03's suite.

## Goal

Let an app be routed to a wired output row (headphone jack, USB, HDMI) and let a saved group name one, exactly the way a Bluetooth row works today, and let the phone see the row with honest flags. The user-facing case in the spec's "Done means": an app routed to the headphones plays only there; a saved group naming them restores it; the companion snapshot lists it. Most of this already holds by construction; the real code change is three one-word widenings in the per-app routing file, so a wired UID counts as reachable and reaches the sink manager's per-app claim set.

## Verified facts

- `Device.canBePerAppRouteTarget()` refuses only `isLocalDevice || kind == .localMac` and `isCast`; `.wired` already qualifies — `AudioutCore/Sources/AudioutCore/AppRouteTargetEligibility.swift:28-32`. Callers: `AppRoutingController.resolveGroupTargets` (`AppRoutingController.swift:238-256`; drops a member the fleet lacks, keeps an unavailable one, never filters by availability) and `PopoverController.availableAirPlayDestinations` (`PopoverController+ApplicationsCard.swift:330`, adds `isAvailable`). No change in any of the three.
- `isRouteTargetReachableLocked` is `known[id]` + `isAvailable` + (`outputIDs[id] != nil || device.isBluetooth`) — `NativeBackend+PerAppRouting.swift:28-31`, doc `:9-27`. A wired row never has an `outputIDs` entry, so today every route to it is demoted at `:138-139`. The `isAvailable` guard coming first is what makes a kept unavailable wired row (02b) demote on unplug and restore on replug: the unplug commit goes through `commitKnownDevice` (`NativeBackend+Wired.swift:36`), which samples eligibility before/after and calls `rerunAppRoutesIfTargeted` (`NativeBackend.swift:4856-4863`, `:4877-4882`).
- The scope arbiter is kind-blind: `isWholeSystemClaimedLocked` reads `expectedSelected` (`NativeBackend+PerAppRouting.swift:40-42`), assigned from every selected id at `NativeBackend+Tone.swift:333`; a selection flip on a routed id replays the table (`:358-361`). Demotion records a `ScopeConflict` readable via `test_scopeConflict(deviceID:)` (`NativeBackend+TestSupport.swift:130-132`). The engine loop skips a selected id with no `outputIDs` entry (`NativeBackend+Tone.swift:376-379`), so selecting a wired row in a test before ticket 03 is harmless.
- Per-app Bluetooth delivery arm: `perAppBTUIDs = Set(sets.flatMap(\.deviceIDs)).filter { known[$0]?.isBluetooth == true }` (`NativeBackend+PerAppRouting.swift:1746-1748`) feeds `btPerAppClaimedUIDs` (`NativeBackend.swift:634`), `btArmingLocked()` (`NativeBackend+Bluetooth.swift:219-222`) and `btSink?.setPerAppClaimedUIDs` (`:1763-1766`); `rebuildBTPerAppFeedsLocked` filters `isBluetooth` again at `:1781`. All downstream takes plain UID strings. The reference in force is reused, never re-derived (`:1757-1759`); rule in `AudioutCore/AGENTS-HISTORY.md:173-180` and `AudioutCore/AGENTS.md:22`. Ticket 03 reuses this manager for wired sinks (03 work order, "Arming"), so the three widenings are the whole delivery change; 03 step 5 adds a `reportedLatencyUIDs:` argument at `:1760-1762` in the same file, serial, no conflict.
- Saved groups: `GroupController` owns them (`GroupController.swift:59-63`) and never prunes a member id (`:75-92`). The backend already holds every saved group's resolved membership in `lastGroupTargets` (`NativeBackend.swift:1386-1391`), pushed from `AppDelegate.swift:2488-2493` through `resolveGroupTargets`, which admits wired members. Group activation goes through `setOutputSet`, whose `known[id]` guard skips an absent id (`NativeBackend+Tone.swift:376`). No change to `GroupStore` or `GroupController`.
- Route reset on disappearance: `PopoverController.swift:964` resets a route only `where devicesByID[goneID] == nil` (`AppRoutingController.handleDeviceDisappeared`, `:274-284`, "GONE means gone from the snapshot, NOT merely isAvailable == false", `:266-273`). Under 02b a used wired row (selected, app-routed, or a saved-group member) stays in the snapshot as unavailable, so the reset never fires for it; an unused row is removed and the reset no-ops because nothing routes to it (`:282`).
- Group editor rows come from `devices` (`GroupEditorViewController.swift:826-838`) and render unavailable ones dimmed; a saved-group member is "used" by definition under 02b, so it stays in `devices` and greys like a dropped AirPlay device (`NativeBackend.swift:4889-4905`). No placeholder needed.
- `CompanionSnapshotBuilder.deviceState` sends `kind: device.kind.rawValue` and `isLocalDevice: device.isLocalDevice` straight through (`CompanionSnapshotBuilder.swift:255-263`); the local-row volume overlay at `:268-269` keys on `isLocalDevice`. `alignmentState`'s `kind == .bluetooth` guard (`:234`) is widened to wired by ticket 04, not here. Wire field is `Device.Kind.rawValue`, no enumerated values (`~/Projects/audiout-shared/Sources/AudioutProtocol/CompanionSnapshot.swift:105-106`). No `audiout-shared` change, no pin bump.
- Ticket 02 harness: `NativeBackendWiredDevicesTests.swift:18-30` `FakeWiredEnumerator` with `fire(_:)`; `makeBackend()` at `:127-135` passes `wiredEnumerator:`; `WiredOutputSnapshot(id:name:transport:)` (`WiredOutputEnumerator.swift:18-22`). Its engine is `NoOpEngine` with no sink spy (`:33-40`). Per-app doubles live privately in `NativeBackendBTSelectionTests.swift`: `FakeProcessEnumerator` (`:279`), `AlwaysSucceedsTap` (`:294-302`), `singleProcessResolver` (`:338-343`), `workingPerAppCapture` (`:351-358`), `route(_:name:toDevice:)` (`:387-389`); `SpyBTSink` records `setPerAppClaimedUIDs` into `perAppClaimedUIDCalls` (`:198-199`, `:238-239`), asserted at `:1254-1319`. `NativeBackend.init` takes `injectedPerAppCapture:` (`NativeBackend.swift:1652`); `captureCoordinator` is a public settable var (`:131`). `NativeBackendTests.swift:7110-7160` observes an effective route through `capture.lastExcludedBundleIDs`; that `FakeCapture` is at `NativeBackendTests.swift:986` (the BTSelection copy at `:125` records only `ops`).
- Analytics: the destination event sends `destination: "device"`, no kind (`PopoverController+ApplicationsCard.swift:586-598`); `mixer:device_selected`'s `kind` has no documented value list (`~/Projects/audiout-shared/docs/analytics-events.md:57`). No new user action here, so no event and no doc edit.

## Steps

Decisions recorded here are final: no source change to `AppRouteTargetEligibility.swift`, `GroupStore.swift`, `GroupController.swift`, or `CompanionSnapshotBuilder.swift`; the delivery arm is the three widenings and nothing else.

1. **Write the route-table test first, run it, paste the failing output.** In `AudioutCore/Tests/AudioutCoreTests/NativeBackendWiredDevicesTests.swift` add copies of `FakeProcessEnumerator`, `AlwaysSucceedsTap`, `singleProcessResolver`, `workingPerAppCapture`, `route` from `NativeBackendBTSelectionTests.swift` (lines above) and the `FakeCapture` that records `lastExcludedBundleIDs` from `NativeBackendTests.swift:986`; give the suite's `makeBackend()` an `injectedPerAppCapture: PerAppCaptureCoordinator? = nil` parameter passed to `NativeBackend.init`. Add `@Test func routeToAWiredRowIsHonouredUntilWholeSystemClaimsIt` — defect: `isRouteTargetReachableLocked` returning false for a wired UID (no engine handle), so a route to the headphones is silently demoted and the app keeps playing in the system mix. Flow: build with `workingPerAppCapture(bundleIDs: ["com.foo"])`, set `backend.captureCoordinator` to the capture fake, `start()`, fire one wired snapshot, wait for the device; `updateAppRoutes([route("com.foo", name: "Foo", toDevice: uid)])`; wait until `lastExcludedBundleIDs` contains `com.foo`, assert it; `setOutputSet([uid])`; wait until `test_scopeConflict(deviceID: uid) != nil`, assert `bundleIDs == ["com.foo"]` and `com.foo` is no longer excluded; `setOutputSet([])`; wait until `com.foo` is excluded again. Run `bash scripts/run-tests.sh --filter NativeBackendWiredDevicesTests` (timeout 600000); paste the failure (the first wait times out).

2. **`AudioutCore/Sources/AudioutCore/NativeBackend+PerAppRouting.swift:30`** — admit `device.isWired` beside `device.isBluetooth`. Extend the doc's second paragraph (`:15-18`) to name both positive kinds: a wired output, like a Bluetooth one, is fed by UID through the sink manager and never holds an `outputIDs` entry. Run the step 1 filter; paste the pass.

3. **Same file, `:1747` and `:1781`** — widen both `isBluetooth == true` filters to `isBluetooth == true || isWired == true`. Update the comment block at `:1734-1745` to say "a Bluetooth or wired speaker". Nothing else in the arm changes: same claim set, same arming call, same reference read at `:1759`.

4. **Per-app claim test, in ticket 03's `AudioutCore/Tests/AudioutCoreTests/NativeBackendWiredSinkTests.swift`** (03 step 1 copies `SpyBTSink` there). Add `routeToAWiredRowClaimsItForPerAppDelivery` — defect: the wired UID never reaches the sink manager's per-app claim set, so the app's stream has no delivery path and plays nowhere. Mirror `NativeBackendBTSelectionTests.swift:1245-1260`: build with `workingPerAppCapture(bundleIDs: ["com.foo"])`, `start()`, fire the jack snapshot, wait for the device, `updateAppRoutes([route("com.foo", name: "Foo", toDevice: jack.id)])`, wait for `sink.perAppClaimedUIDCalls.last == [jack.id]`; assert `sink.calls.contains("start")` and `sink.deviceSets.last?.map(\.uid) == [jack.id]`. Run `bash scripts/run-tests.sh --filter NativeBackendWiredSinkTests`; paste the pass. (Steps 2–3 already landed, so this test passes on first run; it pins step 3 rather than proving it — its before-fail is step 1's.)

5. **`AudioutCore/AGENTS.md:22`** — change to: a per-app Bluetooth or wired destination is fed by UID and reads the room's timing, never sets it. Nothing else in AGENTS.md.

6. **Pinning tests.**
   - `AudioutCore/Tests/AudioutCoreTests/AppRouteTargetEligibilityTests.swift`: add `wiredDeviceQualifies` beside `bluetoothDeviceQualifies` (`:46-53`) — defect: a later tightening of the kind rule (a positive list, or a `supportsAirPlay2`/`isBluetooth` check) drops wired rows from every app's destination menu and every group's resolved targets at once. `Device(id: "wired-1", name: "External Headphones", kind: .wired, supportsAirPlay2: false)` expects `true`.
   - `AudioutCore/Tests/AudioutCoreTests/CompanionSnapshotBuilderTests.swift`: add `aWiredRowReachesThePhoneAsANonLocalSpeaker` in the style of `:620-651` with `alignmentFor` returning nil — defect: a wired row sent as `isLocalDevice: true`, which makes the builder's local-row overlay (`CompanionSnapshotBuilder.swift:268-269`) substitute Main's volume for its fader and makes the phone treat it as the Mac. Build with `Device(id: "wired-a", name: "External Headphones", kind: .wired, supportsAirPlay2: false)`; expect `kind == "wired"`, `isLocalDevice == false`, `supportsAirPlay2 == false`. No alignment assertion.
   - Run both suites' filters; paste the passes.

7. **`.scratch/local-wired-outputs/issues/05-routing-scope.md` line 3**: `Status: ready-for-human (built <date>; live check owed)`, ticket 02's form.

## Out of scope — do not touch

- `AppRouteTargetEligibility.swift`, `GroupStore.swift`, `GroupController.swift`, `CompanionSnapshotBuilder.swift` source (tests only). No `audiout-shared` edit, no pin bump, no `audiout-remote` edit (the phone's chip mapping is workstream 07).
- `PopoverController.update(devices:)` route reset (`:944-964`) and deselect-on-loss edge (`:924`): no change is needed; the keep-while-used rule in `applyWiredSnapshots` (ticket 02b) makes the existing reset correct for wired rows, and `:924` stays Bluetooth-only.
- `AppDelegate.swift:2753` (`hasGroupRoute` guard), `pruneUnusedWiredLocked`, `NativeBackend+Wired.swift` — ticket 02b.
- `CompanionSnapshotBuilder.swift:234` alignment guard and `CompanionSnapshotBuilderTests.swift:650` — ticket 04.
- Any sink, composition, delay, drift or wizard code, `NativeBackend+Bluetooth.swift`, the `reportedLatencyUIDs:` argument at `:1760-1762` — ticket 03. Any popover file — ticket 04. Ticket 06; the public aggregate's sub-device choice.
- Scene-as-app-target: unchanged; wired members flow through `resolveGroupTargets` by construction.
- No new analytics event, no `analytics-events.md` edit, no AGENTS.md line beyond step 5.
- No cleanup, no abstractions, no error handling for impossible cases, no backwards-compat shims. Do not commit or push.

## Verification

Test seams: `NativeBackendWiredDevicesTests.swift` (step 1, the reachability defect), `NativeBackendWiredSinkTests.swift` (step 4, the claim-set defect), `AppRouteTargetEligibilityTests.swift:46-53` and `CompanionSnapshotBuilderTests.swift:620-651` (step 6).

```
bash scripts/run-tests.sh --filter "NativeBackendWiredDevicesTests|NativeBackendWiredSinkTests|AppRouteTargetEligibilityTests|CompanionSnapshotBuilderTests|NativeBackendBTSelectionTests"
```
→ all pass; the run must report `Test run with N tests` with N ≥ 4 new tests plus the existing ones. A no-match filter reports green, so a run listing 0 tests is a failure. Foreground, timeout 600000; on timeout run `bash scripts/capacity.sh status` once, retry once, then stop and report `blocked on capacity`.

## Execution plan

One track, steps 1–7. Files: `NativeBackend+PerAppRouting.swift`, `AudioutCore/AGENTS.md`, four test files, the ticket file. Model: sonnet. Effort: low (three one-line widenings plus tests that mirror cited code). SERIAL after tickets 02, 02b and 03 are on the branch: it consumes `Device.isWired`, `WiredOutputSnapshot`, `FakeWiredEnumerator` (02), the keep rule that makes the reset facts true (02b), and `NativeBackendWiredSinkTests` with its `SpyBTSink` copy (03). The branch holds ticket 02's uncommitted work; an isolated worktree forked from the last commit would not see it.

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

- [ticket-03 / NativeBackendWiredSinkTests.swift] The file is not on disk; step 4 assumes its `makeBackend` returns the spy sink and a wired enumerator fake, and accepts `injectedPerAppCapture:` plus the per-app doubles. If 03's harness lacks any of those, step 4 copies them from `NativeBackendBTSelectionTests.swift` (lines cited above) (affects step 4, Verification).

Working tree check: I made no edits; the modified files in `git status` are ticket 02's executor at work.