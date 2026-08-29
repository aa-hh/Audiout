# Handover — App Exceptions may target a saved Group

**Branch:** `claude/per-app-intercepts-groups-devices-25afc7` (pushed to origin, in sync)
**Commit:** `7001f176` — "App Exceptions may target a saved group"
**Status:** Built, full suite green (3091 tests, 48 new). **Not merged.** Live speaker check owed before merge.

## What this is

Per-app routing (the "App Exceptions" card in the popover) could previously send one app to one individual AirPlay speaker. This adds saved **Groups** as a destination too — reversing the old locked decision "no Groups in the per-app menu" (`docs/plans/PLAN-POPOVER-ROUTING.md` decision 4, `docs/SPEC.md`), both updated in this commit.

Design process: three divergent proposals (minimal/first-class/set-based) were drafted, reviewed with Alec, and a hybrid was approved via structured questions on 2026-08-28. See memory `per-app-group-routing-direction.md` for the full decision record.

## Approved semantics (do not re-litigate these)

- `AppRouteDestination` gains `.group(id:)`. It's a **live reference** — editing the group changes what the app plays on immediately, no membership is ever snapshotted to disk.
- Schema stays v1: `destinationKind: "group"` + new `destinationGroupID` key.
- **Volume = app's own slider × that speaker's per-member level inside the group.** The group's master volume slider is deliberately excluded — Alec's explicit call, flaggable/reversible.
- **Main Out overlap = partial + disclose.** If some group members are claimed by the main output, the app plays on the rest; menu says "Plays on 2 of 4 — the rest are in the main mix." `.group` routes are NOT cleared by group/Main-Out activation (unlike `.device` routes, which still clear as before).
- Group deleted → route falls back to `.noRedirect`. Launch reset (`clearAllRedirectsAtLaunch`) unchanged. App-to-app speaker sharing rules unchanged (no new sharing was opened up).

## Key traps for whoever picks this up

- **`isDeviceRoute` vs `isRoutedAway`** — `isDeviceRoute` is true only for `.device(id:)` (use when you need one specific `Device.id`); `isRoutedAway` is true for `.device` or `.group` (use for "is this app out of the main mix"). Picking the wrong one silently miscounts group routes.
- **`streamID(for:)` → `streamIDs(for:)`** — one app can now feed multiple engine streams at once, because group members can have different per-speaker gains (identical-gain members still collapse onto one stream; differing ones split).
- **`TCCProbeRunnerTests`** — 3 tests with fixed 2s callback waits flake under load on a clean tree too. Pre-existing, unrelated to this change, don't chase it here.
- Only build/test via `bash scripts/build.sh` / `bash scripts/run-tests.sh` — never bare `swift build`/`swift test` (routes through the remote Mac + concurrency cap + cache).

## Disclosed deviations from spec (all deliberate, reversible)

1. Analytics fires **two** events per group pick: the existing `app_routing:destination_selected` gains `destination:"group"`, plus a new `app_routing:group_selected` with `members`/`dropped` counts (no names). If the dashboard owner wants one event, drop the new one.
2. `routedAppCount` (drives the App Exceptions card's default expand state) now counts group routes too.
3. Device discovery now re-pushes the app-route table whenever any app has a group route, so a speaker that joins the group's Wi-Fi network *after* the route was picked still gets included.

## What's NOT built (explicitly out of scope)

- "Both-at-once" — a speaker playing the main mix *and* an app's stream simultaneously. Still a roadmap item, blocked on a per-speaker combined-stream engine change.
- No change to app-to-app speaker sharing/warning rules.
- No ad-hoc multi-device picking, no group creation from the popover, no group `masterVolume` in the app path.
- No iOS work.

## Owed before merge — live hardware check (5 items)

1. App routed to a 2+ speaker group: all members play, in sync.
2. Per-speaker levels inside the group audibly differ for that app's stream; the group's *master* volume slider does nothing to it.
3. Pull one group member into Main Out mid-play: app keeps playing on the rest, no dropout; speaker rejoins the app when released from Main Out.
4. Edit group membership mid-play: newly added member joins, removed member stops, untouched members don't reconnect/glitch.
5. Change a member's per-speaker level mid-play: re-levels without an audible gap (stream-id stability is unit-tested; only the audio behavior needs ears).

## Docs updated in this commit

`AudioutCore/AGENTS.md`, popover/shared/window `AGENTS.md` files, `docs/SPEC.md`, `docs/plans/PLAN-POPOVER-ROUTING.md` — all record the reversed decision and the new semantics inline.
