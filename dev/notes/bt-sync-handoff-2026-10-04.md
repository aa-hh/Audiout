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

## Review debt: what happened to it (2026-10-04, 00:30 to 04:30)

PR #256 (`claude/btfix-1-seek-margin`) MERGED at ef56d711 via the merge queue.
It took eleven Guard 10 rounds, which is why the root `AGENTS.md` now says a
change inside a Guard 10 risk path is scoped before it is built. What landed in
`BTDeviceSink.realignToDevicePulls`:

- a forward re-alignment is clamped like a trim seek, margin = min(100 ms, the
  ring's steady holding), where the holding is a lock-free word
  (`steadyRoomFramesPtr`) set at release from the ring's room less one render
  cycle, moved by every requested trim, cleared with the session;
- when the move is clamped and the cycle followed a device gap of at least the
  20 ms threshold beyond the cycle's own length (a joint stall), the ring is
  cut to its release holding and the measurement restarts; any other clamped
  shortfall takes what fits, books it, and stays pending for a later cycle;
- tests in `BTSinkClockStormTests.swift`: storm rows at 60/100/400 ms, late
  chunks at 752/1680 frames (512-frame cycle) and 2400 (1024), a trim after
  release, the 900 ms joint stall at 100 and 400 ms; the storm fixture drains
  `graphQueue` before each render (a telemetry block holding `stateLock` made
  one cycle silent at random).

Still open, in GitHub issue #261 (both scored at or above 75 and were
overridden by the owner to land the rest): a sub-second joint stall that still
fits the room shifts the full move and leaves the speaker early until the next
re-anchor (take the gap branch on `excess` alone); a forward trim publishes its
holding before posting its shift, so a re-alignment in that window over-cuts
(post the shift first, read the holding word before the room). Fix 2's doc
debt (the AGENTS.md trim rule and the three stale `btOnlyReferenceMs` links)
is untouched; the folder `AGENTS.md` is over budget and Guard 12 now checks it,
so the rule change needs a trim elsewhere in the same file.

Gate defects seen: passes have no memory across rounds (a declined item came
back as a MEDIUM three rounds later; the rules pass demanded removing an
AGENTS.md clause that the comments pass later demanded adding); the Haiku
scorer, recalibrated at 8ef9797c (keep line 75, evidence sentence, examples),
kept 9 of 12 findings afterwards. A per-branch review ledger fed into every
rerun is the proposed fix (#261). Guard 4's name mapping misses
`BTSinkClockStormTests` for `BTSyncedSink.swift` (a commit there ran 2 tests).

## Landing a branch now (main is GitHub-protected since 02:36, PR #255)

`git push origin main` is REJECTED by the ruleset "Main via PR checks". The
local hooks still run on `git merge --no-ff` in the main checkout, but the
result cannot be pushed; do not merge locally any more. Flow: push the branch;
the `tests` workflow runs (three macOS suite shards plus AirPlayEngine, about
20 to 40 minutes, no path filter, so docs PRs pay it too); after the local
Guard 10 run, post the `review` commit status on the PR head by hand:

    gh api repos/aa-hh/Audiout/statuses/<head sha> -f context=review -f state=success -f description="<what the review found>"

then `gh pr merge <n> --merge --auto`. The merge queue's `review-relay` job
copies the status onto the queue commit. Afterwards `git fetch` and
`git merge --ff-only origin/main` in the main checkout.

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

1. Issue #261: the two open re-alignment findings, as ONE scoped round (the
   scoper's case table is in the PR 256 conversation), plus fix 2's doc debt.
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
