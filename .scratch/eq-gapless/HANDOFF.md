# EQ work — handover

Written 2026-09-17. Everything below is verified state, not intention. Start at "What to do next".

## Situation in one paragraph

The owner reported that every EQ change on an AirPlay speaker caused ~2 s of silence. That was
diagnosed, fixed, reviewed and is sitting in **PR #204, open and unmerged**. While testing it the
owner reported a second, different fault: "whenever I put up the bass, the volume goes down and the
bass stays where it was." One cause of that was found and reverted (see 087 below). Whether the
symptom survives is **unknown** — the owner has not re-tested since 2026-09-15 05:58, and the
instrumentation that would answer it in seconds is built but has never run against a real speaker.

## What is on the branch (PR #204, `claude/equalizer-latency-optimization-d714da`)

16 commits, 19 code files, +992 / −713. Mergeable and clean against `main` (which has since moved
2 commits ahead; no conflict).

1. **Roadmap 056, the original fix.** Every AirPlay speaker now binds to its own whole-system
   engine stream at connect (`NativeBackend.connectTargetStreamLocked`) and keeps it while it is
   wanted. An EQ edit retargets that stream's `EQProcessor` in place instead of moving the session.
   Before, a flat↔shaped crossing did `unbind`+`bind`, a fresh RTSP session, discarding the
   receiver's ~2 s lead. Deleted: `EQStreamTopology`, `EQStreamAllocator`, `eqEditIsExpressibleLocked`,
   `enqueueEQRebindLocked`, `eqBudgetLocked`, and the `eq_rebind*` telemetry.
2. **Engine stream cap 6 → 16** (`shims/outputs.h` `OUTPUTS_MAX_QUALITY_SUBSCRIPTIONS` 5→15,
   `AirPlayEngine.maxSimultaneousStreams`, `NativeBackend.engineStreamCapacity`), gated on a headless
   benchmark that ships with it: `MultiStreamEncodeLoadTests` printed
   `ENCODE_BENCH streams=16 audio_s=5.0 wall_s=0.191 rtf=0.038` on the mule. Gate was rtf ≤ 0.25.
3. **Ticket 04 Track 1, observability** (the newest commits). Three local `Telemetry.log` events —
   `eq_edit`, `eq_plan`, `eq_plan_applied` — plus a fix to `stream_health.devices`, which named
   nobody for a whole-system stream because it read `streamBindings` (per-app) only.

Tests at the last full run: `3938 tests in 229 suites` (AudioutCore) and `208 in 31` (AirPlayEngine).
Latest scoped runs: NativeBackendTests `252`, NativeCaptureCoordinatorTests `75`, EQProcessorTests `19`.
Adversarial review ran five times across the branch; the last verdict was APPROVE, and the last
review of the observability commit was APPROVE WITH FIXES with all six fixes applied in `e7c0f72a`.

## Roadmap 087 — REJECTED, and this is a hard rule

An automatic makeup trim (attenuate a shaped curve by its own peak response so a boost cannot clip)
was built on `claude/eq-headroom-087`, reviewed twice, and **rejected by the owner at the live test**.
Peak-normalizing holds the boosted band still and drops everything else by the boost amount, which
is the owner's complaint verbatim. **PR #203 is closed. Do not rebuild this.** A boost must raise the
band it names and leave the rest alone. Clipping on a boosted stream is ordinary EQ behaviour and the
existing float→S16 clamp already prevents wrap. If boosts ever crunch audibly the answer is a
user-controlled preamp, which is the owner's call, not an automatic trim.

That branch and worktree still exist, for reference only.

## The open question

Does "bass up = quieter, no more bass" still happen on a build without the trim?

Ticket `.scratch/eq-gapless/issues/04-eq-inaudible-diagnosis.md` holds the ranked hypotheses and the
full evidence. Track 0 (its gate) has been run: the owner had been testing a stale process, so the
verdict that produced the ticket was about code that no longer exists. Tracks 1 is built. Track 2
(the fix) is deliberately **not** started, because nobody knows yet what to fix.

### How to answer it, without guessing

The owner does not need to describe what they hear. With the current build running, ask them to
connect the speaker, play music, and move the bass slider. Then read the log at
`~/Library/Logs/Audiout/telemetry.jsonl`:

- `eq_edit` — the edit arrived, with `commit`, `shaped`, `known`, and the device.
- `eq_plan` — what was published per stream, `<streamID>:shaped|flat`, and which device owns which.
- `eq_plan_applied` — the plan reached the delivery path's snapshot.
- `stream_health` — `peak_dbfs` per stream, now with `devices` naming the speaker.

The decisive measurement, which is what produced the evidence in ticket 04: for each 5 s window where
both stream 0 and the speaker's home stream carried audio, compare their `peak_dbfs`. `peak_dbfs` is
measured host-side on the exact bytes handed to the engine per stream, so **two streams reading the
same peak in the same window are the same bytes**, i.e. no processor ran. A shaped stream reading
consistently LOWER than stream 0 is the app attenuating. A shaped stream reading higher in the bass
is the app working, and the fault is then downstream in the speaker (a Sonos Move 2 runs its own
limiter and will duck everything when asked for bass it cannot produce).

## What to do next

1. **Rebuild and hand the owner a build.** The integration worktree `eq-livetest` has been pruned by
   housekeeping and its `.app` is gone, although `pid 80232` from 2026-09-15 is somehow still running
   out of the deleted path. Recreate it from the branch, build, then quit that pid and launch:
   ```bash
   git worktree add .claude/worktrees/eq-livetest -b claude/eq-livetest2 claude/equalizer-latency-optimization-d714da
   cd .claude/worktrees/eq-livetest
   bash scripts/livetest.sh acquire --label eq-livetest
   APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh
   ```
2. **Get the owner's verdict**, then either close ticket 04 (symptom gone) or run its Track 2 with
   the log evidence in hand.
3. **Merge PR #204 only on the owner's explicit go-ahead** (repo rule), and only after the live check:
   drag a band up from flat, Reset, and reconnect a speaker with a saved curve — none should go silent,
   and `engine_scope_rebind` must not appear in the log during the test.
4. Afterwards: close roadmap 056 via foreman, mark the worktrees `.prunable`, and release the slot.

## Traps, all paid for the hard way

- **A rebuilt `.app` never reaches a running process.** macOS keeps the launched image. On 09-15 the
  owner tested a revert twice and reported it unchanged, while running a binary built six minutes
  before the fix existed; two wrong diagnoses were built on that report. Before believing any verdict:
  `ps -o lstart= -p <pid>` against `stat -f '%Sm' <binary>`. A start time earlier than the binary's
  mtime means the verdict is about different code. Quit and relaunch it yourself, then confirm.
- **Check for two copies.** `pgrep -fl Audiout`. A production copy and a dev copy both capture system
  audio and fight over the same daemon identity; the owner had both running and quit the wrong one.
- **The live-test slot is EXPIRED** (held 64 h under label `eq-livetest`). Re-acquire before building
  the dev id; the expiry warning is not permission if the owner may be at the speakers.
- `stream_health` polls every 5 s and only sees the Mac's outbound signal, never the receiver. It
  cannot resolve a gap shorter than its cadence, and it says nothing about what the speaker did.
- A filtered test run that matches nothing reports green. Trust only a `Test run with N tests` line.
- Never log on the audio path. `eq_plan_applied` sits in `setEQPlan`, not in `deliver`, for that reason
  (`Telemetry.swift:32`).

## Files

- `.scratch/eq-gapless/spec.md` — the plan and its invariants.
- `.scratch/eq-gapless/issues/01..04` — tickets. 01 is the rejected trim, kept for its reasoning.
- `dev/notes/eq-live-apply-latency-research-2026-09-15.md` — the research: why the gap existed, how
  eqMac, EasyEffects, JUCE and vDSP apply EQ live, and the AirPlay protocol cost of a restart.
