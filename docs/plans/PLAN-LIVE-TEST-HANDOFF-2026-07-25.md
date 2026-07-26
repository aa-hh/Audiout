# Handoff — Live-test session 2026-07-25 (post-merge audio bugs)

**Read this first if you're picking up where this session left off.** Written at ~02:50 local
(00:50 UTC) after several hours of live testing on `claude/memory-leak-live-testing`, branched
from the fully-merged `claude/memory-leak-investigation-396ac3` (which already has `main` merged
in — see `PLAN-MEMORY-LEAK-AUDIT.md` / `PLAN-MEMORY-LEAK-LIVE-TESTS.md` for that history).

## TL;DR

- **4 real bugs found and fixed tonight**, all committed, hermetic suites green. One is
  **live-confirmed by Alec**; the others are telemetry-confirmed but not fully ear-confirmed.
- **1 serious, unresolved mystery remains**: a per-app capture's own state machine appears to
  diverge from reality — it logs `idle` for extended periods while audio keeps audibly playing.
  This is now precisely evidenced (see below) but NOT diagnosed. This is the most important
  thing for the next agent to chase.
- Everything is committed. Working tree is clean. Nothing is lost.

## Where things live

- **Worktree:** `.claude/worktrees/memory-leak-live-testing`
- **Branch:** `claude/memory-leak-live-testing` (branched from `claude/memory-leak-investigation-396ac3` @ `08b0a7b`, which has `main` fully merged via `893938d`)
- **App build:** `./build/Audiouter.app` — rebuild with `scripts/make-app.sh ./build` (the old
  `CPATH=...` workaround from earlier tonight is **obsolete**; main's `5c55386` already fixes the
  include-path issue). If `xcrun`/SDK errors appear, `xcode-select` needs to point at
  `/Applications/Xcode-beta.app/Contents/Developer` (this Mac runs a beta OS; that's the correct
  Xcode for it, not a mistake to "fix").
- **Launch:** `open ./build/Audiouter.app` (never launch from a shell directly — TCC grants need
  the `open` path). It's a menu-bar app, no Dock icon, no window after setup.
- **Telemetry:** `~/Library/Logs/Audiouter/telemetry.jsonl` — **shared across every Audiouter
  build on this Mac**, not per-worktree. Always-on (no env var), JSONL, `cat`/`evt` fields. This
  is the primary diagnostic tool now — see "Diagnostic tooling" below.

### Constraints to respect

- **Single-instance native live testing** — PTP ports 319/320 are exclusive. Never launch a
  second `Audiouter.app` while one is running live. There were 5 stale build artifacts across
  worktrees tonight from parallel sessions; I deleted 4, kept this one. Check
  `find .claude/worktrees -name Audiouter.app` before assuming you're the only one.
- **Live audio testing is Alec-only.** Claude never plays/captures audio itself. Diagnosis must
  go through Telemetry, `process-audio-dump`, `ps`/`system_profiler`, and asking Alec what he
  hears — not by trying to drive audio directly.
- A parallel session titled **"Reliability plan execution"** (worktree `competent-kare-f71af6`,
  branch `claude/reliability-audit-0defe7`) was told to stand down on live-testing and on the
  pitch-up/judder bugs specifically, with the root cause hand-delivered so it wouldn't re-derive
  it. If you see that session active again, check whether it re-engaged appropriately.

## The 4 fixes landed tonight (all committed, all hermetic-suite green)

| Commit | Fix | Live status |
|---|---|---|
| `d415381` | Per-app capture rebuild storm: `PerAppCaptureCoordinator`'s sample-rate listener rebuilt on EVERY HAL notification, including set-to-same-value re-announcements (no compare-before-rebuild guard, unlike the whole-system tap's `TapRebuildDecision`). | Superseded/completed by `196e5b7` below — the guard alone didn't work because the rate it compared against was itself wrong (see next row). Not independently re-verified after the fix below landed. |
| `196e5b7` | **Per-app pitch-up/judder** (~8.8% sharp + fast + juddery + cut out after a couple seconds): `PerAppCaptureCoordinator.createTapAndReadFormat` reads `kAudioTapPropertyFormat` off the bare tap BEFORE it joins the aggregate; the aggregate resamples onto its own clock, so a tap reading 44100 pre-aggregate can deliver 48000 post-aggregate. Main already fixed this for the whole-system tap (`0a9d00e`) but never for the per-app path. Ported `reconcileFormatWithAggregate` from `CoreAudioSystemTap` to `PerAppCaptureCoordinator`. | **✅ Live-confirmed by Alec**: "sound is at the right speed and does not get cut off and no judder." This also fixed the storm guard above, since the guard now compares against the *correct* reconciled rate instead of the stale one. |
| `22a25f7` | **Silent redirect at launch**: a per-app route restored at launch (~tens of ms in) is applied before Bonjour discovers the AirPlay target (~hundreds of ms to ~1s later), and `handleDestinationSetsChanged` only binds "discovered devices" with no recovery path (the whole-system `desiredOn` re-kick doesn't cover per-app targets — they're deliberately excluded from that set, per T7). Cached the last destination-set topology and re-drive the binding pass when a still-unbound target is discovered. | Telemetry-confirmed firing correctly (`app_route_rebind_on_discovery` event at the right moment, ~900ms after launch). Not independently re-verified by ear since — folded into the general confusion below. |
| `ef4ffa2` | **Diagnostic only, no behavior change.** The engine's write-backpressure guard (T14, prior memory-leak wave) already tracked `droppedWrites`/`maxInFlightSeconds` but nothing read it — invisible. Wired `EngineControlling.writeBacklogSnapshot()` through to `NativeBackend`, sampled (rate-limited, emit-on-change-only) from the mixer's `onMixedBuffer` callback, logged as `airplay write_backlog_drop`. | Working as designed — used during tonight's CPU-load correlation test (see below), though that test's results are now in question (see mystery). |

Plan-doc-only commit: `cdb452d` corrected `PLAN-MEMORY-LEAK-LIVE-TESTS.md` (removed a claim about a
popover diagnostic counter that doesn't exist; pointed at Telemetry instead of the env-gated
`AudioDiag`).

## The open mystery — READ THIS CAREFULLY, this is the important part

### The claim being tested
Alec reported: after playing a while, audio develops **judder and dropped milliseconds**
(distinct from the pitch-up bug, which is fixed). Hypothesis under test: CPU contention starving
the engine thread, causing the write-backpressure guard to drop audio.

### What actually happened instead
While trying to correlate a synthetic CPU load (`yes` × 13 processes, load avg ~15, run
02:18–02:26 local) against `write_backlog_drop` events, the investigation found something more
fundamental: **`PerAppCaptureCoordinator`'s own state machine does not reliably reflect whether
audio is actually flowing.**

### The precise evidence (all times UTC, session `21205581-B51D-4A69-9A69-DFF5AA3CAE10`, filter
`grep '"sid":"21205581..."' ~/Library/Logs/Audiouter/telemetry.jsonl`)

```
00:21:33.378Z  Music: capturePA -> capturing (rate-reconciled 48000->44100, correct)
00:21:48.337Z  captureWS: capturing -> stopping        [whole-system tap]
00:21:48.337Z  airplay set_output_set removed:[Move 2]  [Move 2 deselected from Selected Devices —
                                                          Alec confirmed he switched it from
                                                          "Selected Device" to per-app "bypass"
                                                          redirect at roughly this moment]
00:21:51.151Z  Music: capturePA creatingTap -> capturing, THEN capturing -> stopping
               (same millisecond — a rebuild that immediately re-stops)
00:21:51.160Z  Music: capturePA stopping -> idle
00:21:51.161Z  captureWS: exclusion_changed excluded=[Music]   [bookkeeping only; captureWS itself
                                                                 is already idle, so this has no
                                                                 live effect]

  >>> 25-MINUTE GAP: ZERO capturePA events for Music between 00:21:51 and 00:46:24 <<<

  During this gap: Alec reported ~15 minutes of continuous, audible Sonos Move 2 playback.
  The popover UI showed a GREEN "live" indicator on both the Music row and the Move 2 row,
  with "Move 2" selected in Music's Redirect dropdown.
  `swift run process-audio-dump` independently confirmed Audiouter's process (PID 70940) was a
  live, audio-producing Core Audio process object at that time.

00:46:24.998Z  Music: capturePA "from":"capturing" -> "stopping"   <-- NOTE: the immediately
                                                                        preceding logged state
                                                                        was "idle" (from 25 min
                                                                        earlier). No intervening
                                                                        idle->resolvingProcess->
                                                                        creatingTap->capturing
                                                                        was ever logged. The
                                                                        transition log itself
                                                                        claims "from: capturing"
                                                                        with no corresponding
                                                                        prior "to: capturing".
00:46:25.019Z  Music: capturePA stopping -> idle
00:46:25.019Z  Music: capturePA idle -> resolvingProcess -> creatingTap
00:46:25.048Z  Music: capturePA creatingTap -> capturing (rate-reconciled again, correct)
00:46:25.048Z  captureWS: exclusion_changed excluded=[]   [Music no longer excluded]
00:46:34.106Z  Music: capturePA capturing -> stopping (only ~9s of "capturing" logged)
00:46:34.118Z  Music: capturePA stopping -> idle
```

**This exact anomaly shape — a `"from":"capturing"` transition with no logged prior
`"to":"capturing"`, appearing after a long silent gap — is the single most important clue.** It
is not a one-off: an earlier, separate app session tonight (before this one) showed the same
shape (`capturing→stopping` events with no preceding `idle→...→capturing` sequence visible,
around 18:05–18:09 in an even earlier telemetry stretch — check the full log if you want that
instance too).

### Three hypotheses, none yet confirmed or ruled out

1. **Stale/delayed closure bug.** Something captured a reference to `.capturing` state (a
   `DispatchWorkItem`, a device-change listener callback, a completion handler) well before the
   formal `idle` transition, then fired 25 minutes later and logged based on its OWN stale belief
   of state — never having observed or caused the intervening `idle` period at all. If true, the
   REAL underlying Core Audio tap may never have stopped; only the telemetry/log path glitched.
   This would mean the state machine is fine and this is a logging-only artifact — but that
   doesn't explain why the tap would sit "idle" (per the state var) for 25 minutes while
   apparently still delivering real audio the whole time, unless "idle" itself is also wrong.

2. **The whole-system tap (`captureWS`/`CoreAudioSystemTap`) has the same "stop doesn't
   actually stop" class of bug**, and Move 2 was still being fed by the OLD whole-system tap
   this whole time, DESPITE the explicit `captureWS: capturing -> stopping -> idle` +
   `airplay set_output_set removed:[Move 2]` at `00:21:48` claiming it was torn down. Worth
   checking `CoreAudioSystemTap.teardown()` for the same failure-swallowing risk as hypothesis 3
   below, applied to the whole-system path instead of the per-app one.

3. **`PerAppCaptureCoordinator.teardown()` (or the aggregate/tap C-level teardown calls it makes)
   silently fails** — the Swift state machine transitions to `.idle` believing teardown
   succeeded, but `AudioDeviceStop`/`AudioHardwareDestroyProcessTap`/
   `AudioHardwareDestroyAggregateDevice` (or equivalent) didn't actually release the underlying
   object, which keeps delivering real IOProc buffers that the app has lost track of. This is
   the "silent-destroy" bug class the ORIGINAL memory-leak audit was built around (12
   ignored-OSStatus destroy sites, L1–L5) — this could be a NEW instance of that same class,
   possibly regressed or newly exposed by tonight's fixes, or possibly pre-existing and never
   caught because nothing before tonight compared telemetry against real audible state this
   closely.

4. **The green "live" UI indicator is simply cosmetic** — sourced from "is a redirect
   configured" rather than "is capture actually alive" — and is independently misleading,
   unrelated to whether the coordinator's state is accurate. Worth ruling in/out early since
   it's cheap to check (grep the popover/row-view code for what drives the green dot) and would
   at least remove one variable.

### Concrete next steps for whoever picks this up

1. **Find what drives the green live-indicator dot** in the popover UI
   (`AudiouterPopoverUI` — likely `AppRowView.swift` / `DeviceRowView.swift`). Confirm whether it
   reads `PerAppCaptureCoordinator.state(for:)` directly or something else (route config). This
   is hypothesis 4, cheap to rule in/out first.
2. **Audit `PerAppCaptureCoordinator.teardown()`** for any place a Core Audio call's error is
   logged/swallowed rather than propagated — specifically whether `AudioDeviceStop`,
   `AudioHardwareDestroyProcessTap` (or the CATap equivalent), and aggregate-device destruction
   all check their `OSStatus` returns. Compare against the ORIGINAL audit's "12 silent-destroy
   sites" list in `PLAN-MEMORY-LEAK-AUDIT.md` — is this one of the originally-fixed ones, or a
   new one?
3. **Do the same audit for `CoreAudioSystemTap.teardown()`** (whole-system side) — hypothesis 2.
4. **Find whatever logs `transition` events** and check whether there's a plausible path for a
   delayed/stale closure to fire long after the formal state changed — hypothesis 1. Look at
   anything capturing `self.state` (or a local snapshot of it) inside a `DispatchWorkItem` or
   completion handler with no cancellation on teardown.
5. **Re-run the CPU-load correlation test properly** once the state-tracking question is
   resolved — the `write_backlog_drop` data collected tonight is unreliable until we know
   whether "idle" in telemetry means "actually not capturing." If capture was secretly still
   alive during the 25-minute gap, the backlog sampler (wired to the mixer's `onMixedBuffer`,
   which is driven by the PER-APP route's registered stream — see `ef4ffa2`) may or may not have
   been sampling real data during that window; this needs to be understood before trusting a
   "zero drops" result as meaningful.
6. Consider: **use `swift run process-audio-dump` repeatedly across a state-transition boundary**
   (e.g., trigger a de-route/re-route while polling the dump every second) to see if the live
   Core Audio process object count/state changes in lockstep with telemetry, or lags/diverges —
   this would directly distinguish hypothesis 1/4 (log-only issue) from 2/3 (real orphaned
   object).

## Diagnostic tooling now available (all added tonight, all reusable)

- **Telemetry categories relevant here:** `capturePA` (per-app coordinator transitions),
  `captureWS` (whole-system coordinator transitions), `airplay` (engine-level: `set_output_set`,
  `session_reset`, `rebind`, `app_route_rebind_on_discovery` [new], `write_backlog_drop` [new]).
  Always-on, `~/Library/Logs/Audiouter/telemetry.jsonl`, JSONL with `ts`/`sid`/`cat`/`evt` plus
  event-specific fields. Filter by `sid` to isolate one app run.
- **`swift run process-audio-dump`** (from `AudiouterCore/`) — silent, no audio, dumps every live
  Core Audio process object with pid/parent/`NSRunningApplication?`. Useful for independently
  verifying whether a given process is genuinely live at the OS level, bypassing the app's own
  self-reported state entirely.
- **Backlog watcher pattern** (used tonight via the `Monitor` tool, not currently running — restart
  if needed): poll `wc -c` on the telemetry file every 30s, tail new bytes since last offset, grep
  for `write_backlog_drop` / unexpected `session_reset`/`rebind`, and independently check
  `pgrep -f <AudiouterApp binary path>` for liveness so silence isn't mistaken for "still fine."

## Housekeeping already done tonight (don't redo)

- Deleted 4 duplicate `Audiouter.app` build artifacts across other worktrees (bundle-id
  collision risk); this worktree's build is the one alive.
- Told the "Reliability plan execution" session to stand down on the pitch-up/judder bugs with
  the root cause handed over, so it doesn't re-derive `196e5b7`'s fix independently.
- `xcode-select` is already pointed at `/Applications/Xcode-beta.app/Contents/Developer` — that's
  correct for this Mac's beta OS, not a mistake.
