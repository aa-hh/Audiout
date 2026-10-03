# Bluetooth sync work, 2026-09-26

This note replaces three handoffs: the 1.2.0 fixes dev-build handoff on
`claude/project-thread-c0eru9`, the sync clock handoff on
`claude/project-thread-wk2iwa`, and the discovery thread's
`bt-sync-discovery/HANDOVER.md`. SHAs and PR states were checked against origin
on 2026-09-26.

## Three streams

**A. The 1.2.0 Bluetooth fixes.** All come from one customer log (app 1.2.0,
session D4C23DD3, two Sonos Moves). Eight one-commit branches, numbered as in
the fixes handoff:

| Fix | Commit | Branch | What it changes |
|---|---|---|---|
| 1 | `ed6f00aa` | `worktree-agent-a2a761b2a16d4c277` | Sink re-times itself when a device pulls unevenly |
| 2 | `4c82ef4b` | `worktree-agent-a3233199cfc7d4cea` | A trim the sink refused counts as latency |
| 3 | `2977e565` | `worktree-agent-ae5fc1d4b52d6b034` | Mic search window starts where the sweeps can be heard |
| 4 | `abc70072` | `worktree-agent-a4507b0b0d7890fc5` | Try again listens with the mic again |
| 5 | `090064a9` | `worktree-agent-a8e8b0fbcfbeb1d24` | Logs every alignment reset and who asked |
| 6 | `0bd29bff` | `worktree-agent-aa415409a92f0efc2` | Drawer stepper commits once, on release |
| 7 | `52eb5257` | `worktree-agent-ac04f32835da4ea92` | Drift window results go to PostHog |
| deselect | `3ae8fea2` | `claude/bt-deselect-no-rebuild-a066` | A deselected speaker is dropped before the reference moves |

All eight are combined on `claude/bt-sync-integration-2026-09-26` (tip
`893a8bae`, 17 commits ahead of main at `6c25af5c`). It was built as Audiout
Dev and had one 28-minute listen on 2026-09-26 at 01:22 UTC with zero clock
jumps. `claude/project-thread-c0eru9` combined seven of the same branches but
was never compiled; it is retired, and nothing should be built from it.

**B. The sync clock architecture.** Design doc
`dev/notes/sync-clock-architecture-2026-09-26.md` plus draft PR #228 on
`claude/project-thread-wk2iwa`: a slow Bluetooth speaker pushes AirPlay's room
delay later instead of playing late (delay-to-worst). The owner decided this
on 2026-09-26.

**C. The technical discovery.** `dev/notes/bt-sync-discovery/`: the report
(`discovery.md`), five research files and two runbooks. Read-only research.
Runbooks 1 and 2 wait on the owner's measurements.

**Adjacent.** PR #224 (a freshly connected Bluetooth speaker gets time to wake
before the sync sweeps) passed live at 09:18 UTC, is ready, and is not merged.
PR #229 (mic-probe confidence floor 20) merged at 12:32 UTC.

## Owner decisions, 2026-09-26

Each fix lands as its own PR, not as one merge of the integration branch.

Fix 1 (`ed6f00aa`) lands as an interim patch if it passes the listen.
Discovery option 1.1 (timestamped ring plus a phase-correcting control loop on
every Bluetooth sink) replaces it in a later release.

Merge order: fixes 3, 4, 5, 6, then the deselect fix, then fix 7 once the
audiout-shared analytics rows PR has merged (branch
`claude/analytics-rows-bt-sync`, `e90d3ff`, no PR open yet), then fix 2, then
fix 1 last.

## Milestones

**M0, no listening.**
- Integration branch merged with main and the full suite green.
- Audiout Dev rebuilt from the integration worktree.
- One PR open per fix.
- PR #228 compiled for the first time.
- Discovery docs in the repo, this note, the M1 runbook, and the drift-figure
  wording fix (discovery Tier 0 item 0.4). These four ship in one PR from
  `claude/bluetooth-handoff-consolidation-407902`.

**M1, one evening.** Both Moves run sections 1 to 4 of the fixes test script,
then one Move plus the Mac runs runbook 1 Run B. Runbook:
`bt-sync-discovery/runbooks/00-listening-evening-m1.md`. Outcome: fix 2 lands,
and fix 1 lands or is dropped. Runbook 1 Run A needs two different speaker
models, so the two identical Moves cannot run it.

**M2, 75 minutes, mostly unattended.** One Move plus the Mac runs runbook 2.
It picks the signal option 1.1 corrects against: the app's own
`bt_clock_deviation` line, or only a microphone.

**M3, when an AirPlay speaker is available.** PR #224 lands. PR #228 gets its
Bluetooth plus AirPlay listen, and its two open design questions are settled
by ear. Then the alignment wizard's range gets the follow-up that lets a slow
speaker be measured in an AirPlay room.

**M4.** Tier 1 from discovery section 4, after the owner rules on items 2, 3
and 4 in discovery section 7 (the calibration volume raise, app-initiated
measurement, a Bluetooth default output). Start with option 1.1, shaped by
what M1 and M2 found.

Discovery tests 3, 4 and 5 (section 6) stay unscheduled until a Cast device,
the phone and the time are all available.

## Open items

- The passive drift tracker scored 0.7 against a gate of 3 in the customer's
  room, so it cannot hear there.
- A second mic guard: require two listens that agree before accepting a
  reading.
- AirPlay sends stall for 222 to 232 ms during calibration. Undiagnosed.
- The iPhone app pins audiout-shared 0.14.0; the Mac is on 0.15.1.
- The Mac accepts any finite confidence from the phone, so the phone's own
  confidence floor is the only guard on phone readings.

## Where everything is

| What | Where |
|---|---|
| Integration branch | `claude/bt-sync-integration-2026-09-26`, worktree `.claude/worktrees/bt-sync-integration` |
| Integration dev build | `.claude/worktrees/bt-sync-integration/build/Audiout Dev.app` |
| Deselect fix branch | `claude/bt-deselect-no-rebuild-a066`, worktree `.claude/worktrees/agent-a06667ebf29cb7161` |
| Fixes 1 to 7 | `worktree-agent-*` branches on origin, table above; no local worktrees |
| Retired build branch | `claude/project-thread-c0eru9` (holds the old fixes handoff, `dev/notes/handoff-2026-09-26-bt-fixes-dev-build.md`) |
| Shared analytics rows | audiout-shared `claude/analytics-rows-bt-sync` (`e90d3ff`) |
| Sync clock design and PR | `claude/project-thread-wk2iwa`, worktree `.claude/worktrees/project-thread-wk2iwa`, draft PR #228 |
| Cold speaker wake | PR #224, `claude/project-thread-v03fgt` |
| Confidence floor 20 | PR #229, merged |
| Discovery report and research | `dev/notes/bt-sync-discovery/discovery.md`, `research/` |
| Runbooks | `dev/notes/bt-sync-discovery/runbooks/` (00 is M1, 01 and 02 from discovery) |
| Version comparison report | claude.ai project files only (`bt-sync-version-comparison/report.md`) |
| Customer session notes | Mac memory `trial-mac-bt-sync-session-2026-09-25.md` |
