# Handover — Per-app routing to Bluetooth, AirPlay 1, and Cast

**Branch:** `claude/per-app-nonap2-base`
**Commit:** `590dd033` — "One rule for "may this speaker take a single app?", and AirPlay 1 passes it"
**Status:** Phase 1 (AirPlay 1) built, behind a flag that ships off. Phases 2 (Bluetooth) and 3 (Cast) are not on this branch. Not merged — stacked on an unmerged branch, see below.

## What this is

Per-app routing (the "App Exceptions" card) could send one app to an AirPlay-2 speaker or a saved group of them. The ask was to open it to the other three destination kinds a speaker row can be: Bluetooth, AirPlay 1, and Cast. The three are not symmetric.

**AirPlay 1** needs no new delivery plumbing. An AP1 receiver is discovered through the same path as AP2 and picks up an `outputIDs` entry there — `NativeBackend.addOrUpdate`'s own comment: `"Streamable right now" = currently reachable (AP1 or AP2 — both drive through the shared engine)`. The vendored RAOP sender's `master_session_make` (`AirPlayEngine/Sources/CAirPlayEngine/sender/raop.c`) already keys a master session on `(stream_id, quality, encrypt)`, so two devices on different per-app streams never collide onto one session — covered since 2026-07-19 by `RaopMultiStreamMasterSessionTests.swift`. The only thing standing between AP1 and per-app routing was the eligibility predicate itself.

**Bluetooth** has no delivery path. Per-app mixed audio has exactly one consumer today — `AppRouteMixer`'s own topology comment says it plainly: `onMixedBuffer` → `engine.write(pcm:streamId:pts:)`. `BTSyncedSink`'s manager-level `enqueue` fans every buffer it gets to every device sink in `sinksByUID`; there is no notion of "this buffer is for app X only."

**Cast** has the same delivery gap — `CastFanOut.write` fans one buffer to every `CastFeedRing` it holds, the same shape as Bluetooth — plus a product hazard Bluetooth doesn't carry to the same degree. See Phase 3.

The encouraging structural fact: `AppRouteMixer.streamIDs(for:)` already fans one app across several destinations at different gains (a routed group's members can carry different per-speaker levels, and split onto separate streams when they do) — the hard half of "one app, many speakers" is already solved. What's left is only "destinations that aren't engine streams," and today that gap is enforced by one reachability predicate, `isRouteTargetReachableLocked` in `NativeBackend.swift`: `known[id]?.isAvailable == true && outputIDs[id] != nil`. `outputIDs` is populated only by the AirPlay discovery path, so a Bluetooth or Cast id can never pass it no matter what the UI offers.

## Base and branch topology

`claude/per-app-nonap2-base` branches from the tip of `claude/per-app-intercepts-groups-devices-25afc7` (per-app routing to a saved Group — finished, green, a live hardware check owed before merge) and then merges current `main` in on top (`60d41160`). That merge had exactly one conflict, in `DeviceRowView.swift`'s feed tooltip: the group branch had just added `feedNames(qualifiedByGroup:)` (naming the group an app reaches a speaker through), main had just added the stricter `isOlderAirPlayReceiver` check (narrowing the "Older AirPlay" tag to real AP1 receivers, since the Mac/Bluetooth/Cast rows also fail `supportsAirPlay2`). The merge kept both. A later `main` merge then removed the tag machinery outright, so the tooltip now carries only the group-qualified feed names. Landing this work means landing the group branch first.

## Phase 1 — AirPlay 1, shipped at `590dd033`

The eligibility rule — "may this device be a per-app route target?" — existed as two independent copies: `PopoverController.availableAirPlayDestinations` and `AppRoutingController.resolveGroupTargets`. Widening one without the other would let a saved group show an AirPlay 1 member as included and then never actually play on it. Both now read one predicate:

- **`Device.canBePerAppRouteTarget(allOutputs:)`** (`AudioutCore/Sources/AudioutCore/AppRouteTargetEligibility.swift`) — a KIND question only. It never reads `isAvailable`, because `resolveGroupTargets` deliberately keeps an unreachable group member (the backend's own effective-route pass subtracts it later); a caller that needs reachability, like the popover, filters on `isAvailable` itself at the call site. Inside it: local devices and the local Mac kind are always refused; Bluetooth and Cast are always refused regardless of the flag (their delivery path doesn't exist yet — routing to one would be silently demoted and look like it did nothing); an AirPlay device qualifies on `allOutputs || supportsAirPlay2` — AP2 always qualifies, AP1 only with the flag on.
- **`PerAppRouting.allOutputsEnabled`** — `static let`, reads env `AUDIOUT_PER_APP_ALL_OUTPUTS == "1"` once per process. Ships off. `public` because `AudioutPopoverUI` is a separate module that only depends on `AudioutCore` and must read it too. Temporary: disappears once no destination kind is gated (Phase 4).
- `NativeBackend.handleDestinationSetsChanged` had no AirPlay-1-specific refusal to remove — its only gate is `outputIDs[deviceID] != nil`, which structurally keeps Bluetooth and Cast ids out (their rows never get an `outputIDs` entry) and doesn't care about AP1 vs AP2. Widening the shared predicate was enough on its own.

**Test trap, worth recording:** because the flag is a `static let`, it can't be toggled per test. `AppRouteTargetEligibilityTests` calls `canBePerAppRouteTarget(allOutputs:)` directly with both `true` and `false` instead of setting the env var — its own header comment notes that running the suite with `AUDIOUT_PER_APP_ALL_OUTPUTS=1` actually set in the environment would fail three tests elsewhere, by design, since other suites assert the shipped-off behavior.

**Verified at this commit**: build clean on the remote Mac, and these filtered suites green — `AppRouteTargetEligibilityTests` 6, `AppRoutingControllerTests` 40, `NativeBackendTests` 227 in 3 suites, `PopoverControllerTests` + `FeedColumnTests` 169 in 2 suites, `BTSyncedSinkTests` + `BTFanoutTests` 42 in 5 suites. Static per-file `@Test` counts match: `AppRouteTargetEligibilityTests` 6, `AppRoutingControllerTests` 40, `PopoverControllerTests` 140, `FeedColumnTests` 29. `NativeBackendTests.swift` carries 227 `@Test`s total, split across two `@Suite` types in the one file: `NativeBackendTests` itself (210) and, nested inside `extension SerializedSharedState`, `NativeBackendGlobalStateTests` (17 — split out because those touch process-global state the rest of the file doesn't). `--filter NativeBackendTests` runs 227 tests across `NativeBackendTests`, `NativeBackendGlobalStateTests` and `SerializedSharedState`.

## Owner decisions — settled, recorded with their reasons

1. **All three device kinds surface together, not AirPlay 1 alone.** The flag is what holds that line while delivery for the other two lands in later phases.
2. **One timing path per speaker.** A speaker carrying one app's audio gets the same delay treatment it gets carrying the whole system — same `BTReferenceTimeline` composition, same `btOnlyBufferMs` reference, same measured latency, same by-ear trim. No separate per-app timing mode.
3. **A per-app destination reads the room's timing, never sets it.** A speaker that's only a per-app target is not in `btSelectedUIDs`, so it can't raise the shared reference computed from the whole-system selection. Accepted consequence: a per-app-only speaker whose measured latency exceeds the current reference hits `SyncTiming.totalDelayNanos`'s `max(0, …)` floor and plays late. This rarely bites in practice — real Bluetooth device latency runs 100–400 ms (`BTReferenceTimeline`'s own doc comment) against a `BTSyncedSink.defaultBTOnlyBufferMs` floor of 500 ms, and an unmeasured device contributes nothing. The alternative — letting a per-app-only speaker raise the floor — would re-anchor every other Bluetooth sink, the Mac's own sink, and the AirPlay pre-delay every time one app picked a new speaker. Rejected: sync stays predictable, not best-effort.
4. **The AirPlay 1 row carries no protocol tag.** The tooltip's "Older AirPlay — can't route single apps" consequence line went in `590dd033`. The "Older AirPlay" micro-tag itself was then dropped on `main` and is gone from `DeviceRowView` entirely: it keyed off `supportsAirPlay2`, which is false for Bluetooth, Cast and the Mac's own row as well as a genuine AirPlay 1 receiver, so it labelled a Chromecast as AirPlay. The feed column carries what a device is PLAYING; a protocol attribute was never that.
5. **No new warning for picking an AirPlay 1 speaker as a per-app destination.** A receiver on its own private per-app stream has nothing to be out of sync with. `PopoverController.sameSpeakerQualitySubtitle` ("Already in use — may reduce quality") is unchanged and still covers the real remaining case: two apps sharing one speaker.

## Phase 2 — Bluetooth, landed

A single app's audio reaches one Bluetooth speaker. `canBePerAppRouteTarget` no longer refuses `isBluetooth`, so a Bluetooth device answers whatever the flag says; Cast is still refused on its own branch.

- `isRouteTargetReachableLocked` accepts a discovered, available device holding either an `outputIDs` entry **or** `isBluetooth`. It discriminates on the positive kind, never on `!isCast` or `supportsAirPlay2` — those would also admit Cast and the local Mac.
- `BTSyncedSink` owns a per-app claim set (`setPerAppClaimedUIDs`). The whole-system fan-out skips claimed UIDs, and a UID-scoped `enqueue(interleavedFrames:frameCount:pts:forDeviceUIDs:)` feeds exactly the named devices. Both snapshot under `tableLock` and deliver after it drops, per the file's lock-order rule.
- `btArmingLocked()` arms the manager from the union of `btSelectedUIDs` and `btPerAppClaimedUIDs`, without widening either. `btSinkEnabled` keeps its whole-system-only meaning, which is what keeps decision 3 true.
- `handleDestinationSetsChanged` reconciles the per-app claim from the topology and rebuilds a per-stream delivery map; each entry carries its UIDs, a `feedsEngine` flag, a resampler and a `SyncedLocalPCMSink` adapter, all built once per stream rather than per buffer.
- `onMixedBuffer` reads that map under its own lock, releases it, then runs the engine write when the stream still feeds an engine device and additionally feeds the Bluetooth sink through `NativeCaptureCoordinator.fanOutToSyncedLocal`. Additive: one stream can span an AirPlay receiver and a Bluetooth speaker at once.

**A speaker cannot be fed twice, and cannot fall out of the system mix.** `effectiveAppRoutesLocked` demotes any route whose target is whole-system claimed, and `isWholeSystemClaimedLocked` reads `expectedSelected`, which `setOutputSet` fills regardless of device kind. So a selected speaker never enters the per-app claim set and the fan-out keeps feeding it. `perAppRouteToAWholeSystemSelectedBTDeviceNeverClaimsItAwayFromTheFanOut` pins this; removing the claim check in `effectiveAppRoutesLocked` turns it red.

Verified on the remote Mac with the full suite: **3204 tests in 184 suites passed**.

**Known ceiling, worth recording:** `BTGroupComposition.airPlayPresent` is computed from the whole-system selection alone (`NativeBackend.setOutputSet`'s `ids` parameter, or `expectedSelected` at other call sites) — never from per-app targets. A per-app group route spanning an AirPlay receiver and a Bluetooth speaker, with no whole-system AirPlay selection active, will not converge to a shared reference between them. Not fixed by the shape above; fixing it means re-anchoring every Bluetooth sink and the Mac's own sink off a per-app event instead of a whole-system one.

## Phase 3 — Cast, not started

Same delivery shape as Bluetooth: `CastFanOut` fans one buffer to every `CastFeedRing` it holds today with no per-destination addressing. Phase 3 needs per-ring addressing there, a per-app arming set, and lifting the `isCast` refusal — the same three moves as Phase 2, on Cast's own types.

**Hard invariant — record this prominently.** A receiver that is only a per-app destination must never enter `castSelectedIDs`. That list is the sole input to `NativeBackend.updateCastRoomDelayLocked`, which sets `_castTermMs`; `_castTermMs` in turn raises both `roomDelayLocked()` (feeds the AirPlay pre-delay) and `btReferenceDelayMs()` (feeds Bluetooth's own reference whenever Cast is present in the composition). A Cast receiver's lead is measured in whole seconds — the connect sequence's own comment in `CastOutputManager` cites "~5.5 s lead instead of ~7.9 s" for the measured recipe. A leaked per-app-only Cast id would drag every AirPlay speaker, the Mac, and every Bluetooth speaker back by seconds, not milliseconds.

## Phase 4 — reveal, not started

Delete `PerAppRouting.allOutputsEnabled` and the `allOutputs` parameter, and flip the claims that go false the moment all three kinds ship:

- `PRODUCT.md`: "AirPlay 2 multi-room sync is the shipping path (vendored OwnTone sender); AirPlay 1 (RAOP) supported but excluded from per-app routing."
- `AudioutCore/AGENTS.md`: "BT devices remain ineligible per-app route targets."
- `AudioutCore/Sources/AudioutSharedUI/AGENTS.md`: "BT rows are never per-app route targets, so one pill is still the ceiling" — this is also where the row-layout question below has to be resolved, since the ceiling and the layout are the same fact.

Then live-test all three kinds on real hardware.

## Open questions, not scoped

**Row layout.** A `showsSyncControls` row (Bluetooth, Cast, the Mac's own row) splits its trailing slot between the feed pill — capped at `PopoverColumnGrid.btFeedSlotWidth`, computed as `trailingControlWidth − syncChipWidth − btFeedToSyncGap` (140 − 84 − 4 = 52 pt today) — and the sync chip at a fixed `syncChipWidth` (84 pt), sized on the premise that these rows only ever show "System" in the pill. That premise holds today only because no route can target a Bluetooth or Cast id yet: once one can, the pill needs to render an app name in 52 pt and will clip long ones. No visual decision made yet; the fallback already in place elsewhere is honest clipping with the full name in the tooltip.

**Cast lag disclosure.** A Cast receiver plays several seconds behind live — fine for music, wrong for calls or video — and today nothing tells the user. Agreed direction: use the row's sublabel line during the connect wait, which already resolves to hidden in that state, so the space is laid out and empty exactly when the user is watching that row; it clears itself when the sublabel ladder re-resolves at connect completion, no dismissal or timer needed. Show it at most twice ever, across every Cast device — a new global counter, since there's no persisted "already seen" state for this today. Two things unresolved: the real lead is only measured once audio is actually flowing, through `CastOutputManager.onLeadSample` (fed from `reportLead`'s media-status poll), so the connect-time copy can only approximate it; and the measured number, once it exists, has an obvious second home on the row's own offset chip. Not scoped.
