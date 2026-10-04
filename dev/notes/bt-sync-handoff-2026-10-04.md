# Bluetooth sync: handoff after the 2026-10-03 listening night

Read `bt-sync-workstream-2026-09-26.md` first for the three-stream history and
the milestones. This note is what changed on 2026-10-03/04 and what is left.
SHAs checked against origin/main at 997090ea.

## Landed on main (2026-10-03/04)

| PR | What | Commit |
|---|---|---|
| #232 #234 #235 #236 #237 | 1.2.0 trial-log fixes 3, 4, 5, 6, deselect | 2026-10-03 |
| #238 | fix 7 (after audiout-shared #22 rows) | 2026-10-03 |
| #224 | cold Bluetooth wake | 95e53e31 |
| #242 #244 #246 | drift-tracker test clock, merge-hook pass cache, nine timing flakes | 71d99c73 |
| #239 | fix 2: a trim the sink cannot seek to applies on commit | 05e0a8e7 |
| #250 (carries #248) | sink notices a dead or replaced CoreAudio device; reconnect at launch waits for the Bluetooth id | 10a1df5d |
| #240 | fix 1: sink re-aligns when the device pulls unevenly | 997090ea |

Still open: #228 (sync clock, delay-to-worst), #247 (listening driver), #241, #251.

## Listening night results (mule, two Sonos Moves, M3 Air)

Results on the mule: `~/listening/results/2026-10-03_2115/` (Blocks A, B) and
`2026-10-03_2203/` (Block C). Build under test: integration branch with all
eight fixes plus #228, Developer ID signed, `~/Applications/Audiout Dev.app`.

- Block A, both Moves, 25 min: clean median offset between the Moves 36 / 50 /
  22 / 22 ms per five-minute window. No slide, no step. `bt_clock_deviation`
  slopes +3.5 and 0 ppm. Fix 1 passes.
- Block B, Move + Mac, play 60 s / pause 90 s / play 60 s: median offset
  18.6 ms before, 23.6 ms after. A pause loses nothing. No re-anchor at resume.
- Block C, Move on Bluetooth + the other Move in Wi-Fi mode (AirPlay), 60 min:
  medians 23 / 27 / 28 / 20 / 19 ms per ten minutes. Flat. Clock slope +3.3 ppm,
  absorbed by the sink. Runbook row 3: no common-mode drift on this hardware.
  The rate servo (discovery option 1.1) is not needed for these speakers.
- The passive drift tracker rejected every window on the click track as
  `referenceTooNarrowband`. It needs music; the click track cannot exercise it.

Trap: `summary.md` in both folders reports a linear fit and before/after
averages that are WRONG. The analyzer keeps periods whose "second arrival"
matched the neighbouring click (offsets of about ±2400 to ±2700 ms; 93 of 422
periods in A, 252 of 959 in C). Fix in #247: drop |offset| >= 500 ms and report
medians. Until then, recompute medians from `block<X>.txt` by hand.

Two live product bugs found, both now fixed in #250 but NOT live-tested:

1. Reconnect at launch left Bluetooth speakers selected but silent (the restore
   ran through the discovery-filtered id list before the links were up).
2. After a Bluetooth link drop and reconnect (Block A, minute 22), the Move
   showed anchored and clock lines for a moment, then went fully dead: zero sink
   lines, zero clock lines, zero clicks on the mic until the app was quit and
   reopened. #250's cause: a drop and return inside one device refresh left the
   sink rendering into a dead CoreAudio object id because the merge compared
   speaker ids, not object ids. #250 also adds `bt_sink_health` every 30 s per
   sink (render cycles, peak) and `bt_sink_dead` with a cause.

Also seen: QuickTime's player rebuild at a loop boundary escapes the capture
aggregate; the driver uses afplay for that reason.

## Review debt (found by the Guard 10 reviewers, dropped by the scorer, not fixed)

Guard 10 ran four reviewer passes on #239 and #240. Fifteen findings came back;
the Haiku scorer gave every one 65 to 75 and the gate drops anything under 80,
so none blocked and none were fixed. Three matter:

1. **Fix 1, forward re-alignment has no safety margin.**
   `AudioutCore/Sources/AudioutCore/BTSyncedSink.swift`,
   `realignToDevicePulls(cycleStartMonotonicNanos:frameCount:)` (near line
   1449) calls `delayLine.shift(byFrames: +n)` with no clamp, while
   `applyTrimDelta(ms:)` (near line 1253) stops every forward seek
   `seekSafetyMarginMs` (100 ms) short of the write pointer because reaching it
   empties the ring. After a stall just under
   `BTClockStability.lostBaselineThresholdMs` the re-alignment can ask for up to
   ~1 s forward. Two reviewers found it independently. IN PROGRESS on branch
   `claude/btfix-1-seek-margin` (worktree `.claude/worktrees/btfix-1-seek-margin`,
   forked from 997090ea): clamp the positive branch to room minus margin with a
   consumer-side room helper on `BTDelayLine`, one red-then-green test in
   `BTSinkClockStormTests.swift`. Check that branch's state before starting.
2. **Fix 1 keeps re-aligning on an empty ring.** Same function. With the ring
   empty (music paused, capture tap asleep, which the keep-alive path treats as
   normal) a device pulling 20 ms or more ahead of wall time seeks backward into
   played history and replays it during the silence; an under-pull's forward
   shift applies 0 frames, is never booked, and later skips that much of the
   resumed audio. Proposed fix: when the ring holds no frames, re-base
   (`pullOriginNanos = t`, `framesPulledSinceOrigin = frameCount`,
   `pullRealignedNanos = 0`) instead of shifting; add a test that drains the ring
   under an over-pulling device and asserts no non-zero frame comes out. Related:
   a render cycle turned away by `stateLock.try()` drains nothing but is booked
   as pulled (near line 1235); take it back out in the lock-fail branch.
   Block B's 90 s pause showed neither symptom on the Moves.
3. **Fix 2 contradicts the folder rule and leaves stale links.**
   `AudioutCore/Sources/AudioutCore/AGENTS.md` line 17 says "A Bluetooth trim is
   a ring seek and must never clear session state", but
   `reanchorIfTrimClamped()` (BTSyncedSink.swift near line 1120) rebuilds on a
   clamped commit, and a negative trim that moves the Bluetooth-only floor
   re-anchors every sink (`NativeBackend+Bluetooth.swift` near line 1340).
   Amend the rule: a live trim is a seek; a COMMITTED trim may re-anchor when its
   seek was clamped or when it moves the floor, with the reason in one clause.
   Doc links to ``btOnlyReferenceMs(latencies:uids:)`` at `NativeBackend.swift`
   lines 624 and 636 and `NativeBackend+Bluetooth.swift` line 1167 point at a
   signature that is now `latencies:trims:uids:`; line 854 still says the floor
   is "slowest measured latency + headroom" (add the negative trim); the
   `setBTSyncTrim` doc comment (near line 1331) still promises "no silence" on a
   committed trim. Test `theReplayedPullsAreTheLoggedJumps` in
   `BTSinkClockStormTests.swift` names no defect; fold it into the storm test
   as a precondition or delete it.

Product call the deep reviewer raised, not a bug: with fix 2, every committed
negative trim on the floor-setting speaker rebuilds every Bluetooth sink and
re-anchors the Mac's own sink, a group-wide gap of about the full delay
(~0.6 s) per stepper click. Only the owner's ears can say whether that is
acceptable. Owner (Alec) has not ruled.

## Guard 10 flow that worked (merging onto main)

1. In the branch's worktree: `git merge main` first. The review script lives on
   main, and this runs the full suite once (about 3 min on the mule; a local run
   under load took 6 min and threw three flakes that vanished on the mule).
2. `bash scripts/review-branch.sh` prints four passes (deep on Opus, rules /
   history / comments on Sonnet). Run each as a read-only subagent that reads
   the `.prompt` file and saves its reply with a Bash heredoc to the `.out`
   path (the Write tool may refuse paths in another worktree; one Haiku scorer
   returned its reply without saving, so check the `.out` files exist).
3. `bash scripts/review-branch.sh --continue` prints N Haiku scoring passes;
   run them the same way; `--continue` again writes the receipt (or prints fix
   groups).
4. In the main checkout: `git merge --no-ff --no-edit <branch>` (Guard 10
   reads the receipt, Guard 4 skips on the cached full pass), `git push origin
   main`, push the branch too so GitHub marks the PR merged.

Traps: a Guard 10 refusal ("does not contain the latest main") leaves
`MERGE_HEAD` and staged files in the main checkout; confirm they are yours,
then `git merge --abort` there before retrying. Main moved under me once
tonight (#250 landed between my review and my merge); step 1 then repeats.
The scorer threshold (80) versus Haiku's habit of answering 75 needs a look
before the gate means anything.

## Mule and driver state

- Mule: `alechamilton@SUMUP-M9Y197RFVG.local`. Permits `audiout.remoteSlots=2`,
  `audiout.testPrefer=remote` (Alec's choice 2026-10-04). Set remoteSlots to 0
  only AFTER a listening driver has started, never before, and restore after.
- Driver: `~/listening/unattended-night.sh` on the mule = branch
  `claude/unattended-listening-driver` (PR #247, d76ee532, worktree
  `.claude/worktrees/listening-driver`). Run it from the mule's own Terminal
  (processes started over ssh get no microphone). Flags: `--only-c`,
  `--c-move <bt id>`, `--airplay-id <id>`, `--move1/--move2` (all four ids are
  required even for `--only-c`), `--smoke`, `--dry-run`, `--list-devices`.
  Manual selection mode: at each `WAITING` line, deselect and reselect the
  named rows in Audiout Dev, then press Enter; the check only trusts
  `set_output_set` / `connect_requested` lines written AFTER the prompt. Three
  failed tries abort the block.
- Ids: Move 089E `54-2A-1B-79-08-9E:output`; Move 2 BF4A
  `C4-38-75-0E-BF-4A:output` (Bluetooth) / `C4:38:75:0E:BF:4A` (AirPlay, in
  Wi-Fi mode); This Mac `local-mac`. Move 2 was left in Wi-Fi mode at 23:14.
- Stores: `~/Library/Application Support/com.audiout.Audiout.dev/bt-sync-trims.json`
  (`latencyMs` 286 and 435 for the two Moves), `routing.json`. Telemetry
  `~/Library/Logs/Audiout/telemetry.jsonl`, UTC timestamps.

## Still owed, in order

1. Finish `claude/btfix-1-seek-margin` (review debt 1), fold in 2 and 3, Guard 10,
   ask Alec for the merge go.
2. Live test of #250: build Audiout Dev from main, repeat Block A's link drop
   (`--smoke` reproduces it in two minutes) and watch for `bt_sink_dead` /
   `bt_sink_health`; also quit and relaunch with reconnect-at-launch on.
3. #228's own listen: runbook `bt-sync-discovery/runbooks/00-listening-evening-m1.md`
   Part 3 (stored latency 950 ms on one Move, music, by ear, five minutes). Then
   merge #228; expect the `updateBTRoomTermLocked()` conflict noted in the
   workstream note.
4. #247: analyzer fix (drop |offset| >= 500 ms, medians), then merge.
5. Direction (Alec, 2026-10-03): PostHog shows 11 production Macs in 90 days,
   7 of them Alec's or agents'; the 4 outside Macs never selected Bluetooth or
   ran the wizard; `bt_sync:drift_corrected` fired twice, dev build only. Alec:
   absence of users is not absence of demand; if this works it is a marketing
   claim nobody else can make. Next is validation on two or three other speaker
   brands with the driver, plus a competitor check (Airfoil and the Windows and
   Android tools claim Bluetooth sync; what do their users complain about?),
   before any more sync engineering (servo, delay-to-worst, Tier 1).
