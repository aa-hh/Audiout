# HANDOVER — Leveled volume for un-redirected apps (`claude/per-app-intercept-volume-aba1ad`)

Written 2026-08-29. Single session, no prior handover exists for this branch.

---

## 1. Where you are

- **Worktree:** `.claude/worktrees/per-app-intercept-volume-aba1ad`.
- **Branch:** `claude/per-app-intercept-volume-aba1ad`, pushed to origin.
  **HEAD is `a0a74ba6`** (committed, pushed). Working tree clean — nothing
  uncommitted.
- `main` is **merge-only**. This branch has NOT been merged and has NO PR
  open. It reaches `main` as both a local `git merge` and a GitHub PR, on
  Alec's go-ahead only.
- Build & test through the wrappers ONLY: `bash scripts/build.sh`,
  `bash scripts/run-tests.sh --filter <Suite>` (or `AUDIOUT_FULL_SUITE=1` for
  the full run). Never bare `swift build`/`swift test`. Never pipe their
  output through `| tail` and read that exit code — it's tail's, not the
  suite's.
- Read root `AGENTS.md` and `AudioutCore/Sources/AudioutCore/AGENTS.md`
  before editing.

## 2. What this branch does

Today, an app's per-app volume slider only works if the app is redirected —
to a specific AirPlay device, or explicitly to "Current Device" (Bug T2). An
app left on the default "No Redirect" state has a dimmed, dead slider: it
just plays in the whole-system mix, unlevelable.

This branch makes that slider live for EVERY app, including "No Redirect."

**Product decisions (settled with Alec, don't re-litigate):**
1. Volume 100 = the app is completely untouched — no tap, no mute, no
   exclusion, byte-identical to today's behavior.
2. Below 100, the app is intercepted (`.mutedWhenTapped`, same as
   `.currentDevice`/`.device` routes) and its own captured audio is summed
   back into the whole-system program, scaled, at ONE injection point that
   feeds every consumer identically — the AirPlay engine, the synced-local
   Mac sink, Bluetooth sinks, and Cast. So the app keeps playing everywhere
   the mix goes, just quieter — it is NOT pulled onto the Mac like
   `.currentDevice` apps.
3. When the whole-system capture isn't running at all (nothing streaming),
   a leveled app falls back to local Mac playback via the existing
   `LocalPlaybackEngine` (the same pipeline `.currentDevice` already uses).

## 3. The new piece: `LeveledAppInjector`

`AudioutCore/Sources/AudioutCore/LeveledAppInjector.swift` — new file, ~330
lines including comments. Sibling of `AppRouteMixer`, deliberately simpler:

- No destination-set topology (one destination: the whole-system program).
- No presentation-time alignment — a plain FIFO ring per app. `razor:`
  comment in the file names this ceiling: both the per-app tap and the
  system tap ride the same output device clock, so they can't drift apart;
  if that ever stops being true, the upgrade is `AppRouteMixer`'s
  frame-indexed `MixTimeline`, not a second alignment scheme.
- `mix(into:frameCount:)` is called from the whole-system tap's REAL-TIME
  delivery thread inside `NativeCaptureCoordinator.handleBuffer`. It takes
  its lock non-blockingly (`try()`) and drops the contribution on a miss —
  same discipline `LocalPlaybackEngine.receive` and the coordinator's own
  buffer handling already use. Never blocks the audio thread.
- Injection point is **before the Main Out EQ**, in
  `NativeCaptureCoordinator.swift` — a leveled app is program material and
  must be shaped by the user's tone stage (the align tick, by contrast, is
  deliberately injected AFTER the EQ — it's a measuring tool, not program
  material).

## 4. Where `NativeBackend` changed

`updateAppRoutes` (~line 4148) now also computes a `leveledBundleIDs` set:

```
leveled = { bundleID : route in RAW routes,
            route.destination == .noRedirect,
            route.volume < 100,
            !excludedBundleIDs.contains(bundleID) }
```

**TRAP, already fixed but know why:** this reads the RAW route table, not
`effectiveAppRoutesLocked`'s output. A `.device` route the effective pass
demoted (target unreachable, or whole-system-claimed per roadmap 008) must
rejoin the mix at FULL volume — if the leveled set were computed from the
effective table, every demotion would silently become an attenuated
intercept instead. Excluded (privacy denylist) apps are never leveled
either, regardless of a volume set before they were excluded.

**TRAP found and fixed during the build:** three separate "is this capture
still wanted?" guards — `handlePerAppCaptureHealthChange`'s orphan check,
`handleAppTerminated`, `handleAppLaunched` — only tested
`routedBundleIDs ∪ localBundleIDs`. A leveled app is in neither set, so its
successful `.capturing` transition was being refused as an orphan and its
tap stopped immediately — the feature silently could not work at all until
this was found. Fixed at the root with one shared predicate,
`wantsPerAppCaptureLocked(_:)`, used at all three sites. **If you add a
FOURTH per-app audio consumer later, it must join that same predicate or
this bug reappears for it.**

`captureRunning` (whether the whole-system capture is actually running —
this is the gate deciding "sum into the mix" vs "play locally") flips in
**three** places, not the two you'd expect: `reconcileCaptureGate`,
`suspendSessionsKeepingIntentLocked` (sleep / AirPlay-handoff release), and
`stop()`. All three now reconcile the leveled injector/local-player
transition.

## 5. Files touched (full list)

Created:
- `AudioutCore/Sources/AudioutCore/LeveledAppInjector.swift`
- `AudioutCore/Tests/AudioutCoreTests/LeveledAppInjectorTests.swift`

Modified:
- `AudioutCore/Sources/AudioutCore/NativeBackend.swift`,
  `NativeCaptureCoordinator.swift`, `AppRouteStore.swift`,
  `OutputBackend.swift`, `AGENTS.md`
- `AudioutCore/Sources/AudioutSharedUI/AppRowView.swift`,
  `AudioutCore/Sources/AudioutPopoverUI/PopoverController.swift`,
  `AudioutCore/Sources/AudioutApp/AppDelegate.swift`,
  `AudioutCore/Sources/popover-snapshot/main.swift`
- Tests: `NativeBackendTests.swift`, `NativeCaptureCoordinatorTests.swift`,
  `AppRowViewTests.swift`, `WarmFaderCellTests.swift`,
  `PopoverControllerTests.swift`

No renames, no deletions. 16 files, +1245/-106.

## 6. Test state — verified independently, twice, not just by the build agent

Every suite touching this feature is green, confirmed by me re-running from
a fresh session with `AUDIOUT_TEST_NO_CACHE=1`:
`LeveledAppInjectorTests`, `NativeBackendTests`,
`NativeCaptureCoordinatorTests`, `AppRowViewTests`, `PopoverControllerTests`,
`WarmFaderCellTests`.

**Flaky, unrelated to this change, seen across three full-suite runs:**
`CaptureCoordinatorTests` (OwnTone subprocess path), `TCCProbeRunnerTests`,
`CastLiveAudioServerTests`, `BTSyncedSinkTests` — all timing/spawn tests, all
green in isolation and on the healthy remote test Mac. The shared test
machine was under heavy load / low disk during most of this session; when
the wrapper's remote leg fails it re-runs locally, and the local box was the
one throwing extra flakes.

**One test worth remembering if it fails again:**
`NativeBackendTests.orphanedCaptureAfterDeRouteIsStoppedNotAccepted` — its
second assertion races a late-arriving async bind Task from the de-route
step. Failed once under machine load, passed on the healthy remote and 3/3
in isolation afterward. It sits in the exact code path this branch widened
(`wantsPerAppCaptureLocked`), so it's not automatically dismissible — but
check machine load before suspecting a regression here.

## 7. What's owed — nothing has made a sound

**No `.app` has been built. No live hardware verification has happened.**
Everything above is hermetic (unit/integration tests with mock backends and
spy converters). Before this merges:

1. Build a fresh-bundle-id test app (`APP_NAME=... BUNDLE_ID=... bash
   scripts/make-app.sh` — never overwrite the default `com.audiout.Audiout`
   dev build).
2. With at least one AirPlay device selected and streaming, pull a
   No-Redirect app's slider below 100 and confirm by ear it gets quieter
   EVERYWHERE (the speaker AND the Mac if "play everywhere" is on), not
   silenced or moved.
3. Push it back to 100 and confirm it's audibly identical to an app that
   was never touched (no residual attenuation, no artifact from the
   tap/untap transition).
4. With nothing streaming, confirm a leveled app plays locally at the
   scaled volume (the `LocalPlaybackEngine` fallback path).
5. **De-route a leveled app while it's playing** — this is the path the
   flaky test above covers; worth confirming by ear that nothing glitches.
6. Multiple leveled apps at once, different volumes, confirm they sum
   correctly and don't clip or crackle.

## 8. Docs updated as part of this work

- `AppRouteStore.swift`'s header comment previously said `.noRedirect` and
  `.currentDevice` were unconditionally "engine/capture-equivalent." That
  stopped being fully true — they're equivalent only at volume 100; below
  100 a `.noRedirect` route now engages the leveled intercept. Comment
  updated to say so.
- `AppRowView.swift`'s slider-dimming doc comments and
  `test_isSliderDimmed` were rewritten — the slider is now always live;
  `isNoRedirect` still gates the gold "armed" fader fill (that predicate is
  UNCHANGED: routed ∧ running), just no longer the slider's enabled state.

## 9. Next steps, in order

1. Alec runs the live-verification checklist in §7.
2. If it holds up by ear, this merges via the normal branch → `main` +
   GitHub PR flow — not before.
3. `touch .claude/worktrees/per-app-intercept-volume-aba1ad/.prunable` once
   merged (or abandoned-but-pushed) so housekeeping reclaims the worktree.
