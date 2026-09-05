# HANDOVER — Leveled volume for un-redirected apps (`claude/per-app-intercept-volume-aba1ad`)

Written 2026-08-29. Single session, no prior handover exists for this branch.

---

## 0. Status — LIVE-VERIFIED 2026-08-29

The owner tested the finished branch on Move 2 and confirmed it: "amazing its
perfect". Turning an app down keeps it playing on the speaker, quieter;
dragging across 100 is smooth; returning to 100 is silent. What follows
records how it got there, because the first design did not work at all and
the reasons are not obvious from the code.

**Awaiting the owner's go-ahead to merge.** Nothing has been merged to `main`, and
no PR is open.

### What the original commit got wrong

`a0a74ba6` shipped with a green suite and a confident handover, and its
central behaviour had never been heard. It did not work. Three findings, in
the order they were proven:

1. **The injector had no carrier.** `LeveledAppInjector.mix()` was only ever
   called from inside the whole-system tap's buffer callback. Turning an app
   down excludes it from that tap and mutes it — so when it is the ONLY thing
   playing, the tap has nothing left to capture, Core Audio stops calling us,
   and the app's audio piles into a full ring and is discarded. Silence
   everywhere. Proven by `leveled_health` telemetry: the tap sat in
   `capturing` while `mix_calls` read 0 for four consecutive windows against
   a ring pinned at its 22050-sample capacity, with buffers arriving at the
   correct rate throughout. Fixed in `42e8ddde` by giving the program feed
   its own clock, modelled on the wizard pacer.
2. **Crossing 100 thrashed.** Every slider tick across the boundary swapped
   the app between the `.unmuted` metering tap and the `.mutedWhenTapped`
   levelling one. `muteBehavior` is fixed at tap creation, so each crossing
   destroyed and rebuilt two Core Audio aggregates — eight full cycles in
   1.1 s of dragging, 18 exclusion changes, audibly dropping to the Mac each
   time.
3. **The exit blipped.** Leaving the levelled set destroys the app's tap and
   rebuilds the whole-system tap; while that tap is down the Mac's own
   speakers are unmuted, so the app is briefly heard on the Mac. Delaying the
   exit only moved the blip.

2 and 3 are both fixed by stickiness (`0ac856bc`): once turned down, an app
stays intercepted for the session, injected at unity gain when the slider is
back at 100. `scaledStereoSamples` is exact identity at 100, so it
contributes sample-for-sample what the whole-system tap would have carried.
There is no exit, so there is no transition to glitch.

Note stickiness was tried FIRST (`885e92ab`) and reverted (`33ceb207`) —
correctly, because finding 1 was still live and stickiness made the resulting
silence permanent. It only became viable once the carrier was fixed.

### Why the tests did not catch any of it

They still pass with the feature completely silent. Every levelled test hands
the tap a buffer first, so none of them can see a tap that never delivers.
The one test that now covers it —
`aLeveledAppIsStillHeardWhenTheTapItselfGoesSilent` — deliberately pushes
NOTHING through the tap. Every fix on this branch was red-checked: the fix
disabled, the test confirmed failing on the right assertion, then restored.
Do that for anything you add here.

### Diagnostics left in place

- `leveled_health` (every 5 s while capturing) — `mix_calls` at 0 means the
  tap never asked; `buffers_in` climbing with `samples_mixed` at 0 means the
  rings fill and nothing reads them; `dropped_*` names the guard eating
  buffers.
- `engine_session_failed` — the AirPlay engine's own session death, which
  produces the user-visible "engine state: failed". It logged nothing before
  `5066ccc2`, which is why a dropped session had to be inferred and was
  initially blamed on the wrong cause.

### Two traps for whoever is next

- **`main` had build-script fixes this branch lacked.** Remote builds died on
  a missing resource bundle and silently fell back to compiling locally.
  `5bd58060` and `feafaf45` bring `make-app.sh` and `livetest.sh` across.
  Take them together — the first calls the second.
- **The live-test slot is owned by a worktree path.** Acquire it from the
  worktree you will build in, not from the main checkout, or `make-app.sh`
  refuses the shared dev id even while you hold the slot.

---

## 1. Where you are (original, pre-fix — kept for the record)

- **Worktree:** `.claude/worktrees/per-app-intercept-volume-aba1ad`.
- **Branch:** `claude/per-app-intercept-volume-aba1ad`, pushed to origin.
  **HEAD is `a0a74ba6`** (committed, pushed). Working tree clean — nothing
  uncommitted.
- `main` is **merge-only**. This branch has NOT been merged and has NO PR
  open. It reaches `main` as both a local `git merge` and a GitHub PR, on
  the owner's go-ahead only.
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

**Product decisions (settled with the owner, don't re-litigate):**
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

## 7. What was owed — NOW DONE (live-verified 2026-08-29, see §0)

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

1. The owner runs the live-verification checklist in §7.
2. If it holds up by ear, this merges via the normal branch → `main` +
   GitHub PR flow — not before.
3. `touch .claude/worktrees/per-app-intercept-volume-aba1ad/.prunable` once
   merged (or abandoned-but-pushed) so housekeeping reclaims the worktree.
