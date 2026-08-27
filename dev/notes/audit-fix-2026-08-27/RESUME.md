# Audit-fix effort — resume playbook (written 2026-08-27, mid-execution)

If you are a fresh Claude session picking this up: this directory is the durable copy of
everything the coordinating session held in ephemeral scratch. The audit artifact (findings,
severities, fix waves) is at https://claude.ai/code/artifact/e2939139-1a85-48ec-8050-9297e487057d.

## What this effort is

The full go-live audit of the macOS app (reports in `audit/`) is being fixed as 10 parallel
tracks. Each track has a paint-by-numbers work order in `orders/` (T1–T9 + model-plan.md, which
holds the model assignments, merge order, wrap-up list, and every default decision taken).
Each track runs in its own worktree on its own branch, forked from main @ 59f2b044:

| Track | Worktree (under .claude/worktrees/) | Branch |
|---|---|---|
| T1 backend failures | fix-backend-failures | claude/fix-backend-failures |
| T2 data safety | fix-data-safety | claude/fix-data-safety |
| T3a popover entrance | fix-popover-entrance | claude/fix-popover-entrance |
| T3b popover rows | fix-popover-rows | claude/fix-popover-rows |
| T4 license/money | fix-license-money | claude/fix-license-money |
| T5 groups window | fix-groups-window | claude/fix-groups-window |
| T6 onboarding | fix-onboarding | claude/fix-onboarding |
| T7 shell | fix-shell | claude/fix-shell |
| T8 perf/anim | fix-perf-anim | claude/fix-perf-anim |
| T9 design tokens | fix-design-tokens | claude/fix-design-tokens |

All branches exist on origin. Executors commit + push as work lands, so origin holds everything
finished. If the coordinating session died mid-flight, some worktrees may hold UNCOMMITTED work.

## To resume after a dead session

1. For each worktree above: `git -C "<worktree>" status` (quote paths — the repo path has a
   space). Three possible states per track:
   - Branch has commits matching its full order → run the review step (below).
   - Dirty tree / partial work → diff against the track's order file; finish the remaining
     numbered edits exactly as the order writes them (an executor agent per track,
     model per model-plan.md), then commit/push.
   - Untouched → launch an executor per the order from scratch.
2. Executor rules (bind every agent): work only in its own worktree; tests/builds ONLY via
   `bash scripts/build.sh` / `bash scripts/run-tests.sh --filter <Suite>` (mule-routed —
   config keys are `audiout.remoteHost` / `audiout.testPrefer` in the shared .git/config;
   if the mule "stops being used", check those keys first — the audiouter.*→audiout.* rename
   already bit once); `bash scripts/self-review.sh` before commits (Guard 7); commit messages
   end "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"; push to the track's origin
   branch; NEVER merge — merges need Alec's explicit go-ahead.
3. Review step per finished track: a Fable work-order-reviewer diffs the branch against its
   order (spec compliance, real defects, honesty). Findings go back to the track's executor.
4. Merge sequence (Alec-approved, one at a time, local merge + GitHub PR both):
   T2 → T1 → T9 → T8 → T3b → T3a → T7 → T5 → T4 → T6. Expect trivial one-line conflicts where
   model-plan.md marks CONFLICT-EXPECTED (T9's token swaps in row/panel files).
5. After all merges, the WRAP-UP PASS in model-plan.md: snapshot regeneration ×3 (popover /
   settings / onboarding — window goldens are NEVER regenerated), PRODUCT.md "Main Out"→
   "Main Audio", wire T3a's localNetworkDeniedProvider seam in AppDelegate, audiout://register
   URL handler, Group-N naming helper + percent-formatter consolidation, PanelVC:773 comment,
   roadmap status updates.
6. Every default decision taken without Alec is listed in model-plan.md under "DECISIONS TAKEN
   AS DEFAULTS" — surface them at review; he can veto any.

## Facts that were expensively established (do not re-derive)

- License key prefix is AUDT (deployed worker verified, both prod + staging); the spec doc and
  old test fixtures said AUDR and are the stale side. Server canonicalises keys fully.
- About values: support@audiout.app; source URL https://github.com/aa-hh/Audiout (repo public).
- Naming: "Main Audio" is canonical (Alec 2026-08-27); PRODUCT.md still says "Main Out" until
  the wrap-up pass.
- Deployment floor: macOS 14.2 (T6 raises Package.swift; make-app.sh already ships 14.2).

## Review ledger
- T4 license-money: APPROVED (fable review, 0 findings, 3 deviations endorsed) — commits 3a8d4b65+4110e92d on origin. READY TO MERGE pending Alec.
- T2 data-safety: FIX-FIRST (1 medium: launch alert evaluated before groups/app-routes loads — fix agent running; everything else clean, async-write flag judged acceptable). WRAP-UP +1: inject temp-dir routing stores across GroupControllerTests (reviewer follow-up).
- T1 backend-failures: EXECUTED — 49ae524e on origin, full suite 2862/168 green (Guard 4, mule). Fable review running.
- T1 backend-failures: APPROVED (fable review, 0 findings; race audit clean) — 49ae524e on origin. READY TO MERGE pending Alec.
- T8 perf-anim: EXECUTED — bd20fbba on origin, full suite green (flake arbitration documented). Fable review running. WRAP-UP +3: NativeBackend:~3130 'emitLevel'→'onLevel drain' comment (T1 region); stale emitLevel comments NativeBackendTests:4133/:7096; T3a handoff PanelVC:772-774 replacement sentence recorded in T8 executor report. NOTE: git remotes still point at old Audiouter.git URL (redirect works) — wrap-up candidate: update remote URLs.
- T3b popover-rows: EXECUTED — 414adcb4 on origin, full suite 2854/168 green; relay executor finished edits 8-9 + fixed a real tooltip-teardown ordering bug. Fable review running.
- T8 perf-anim: APPROVED (fable review; 3 low observations, none blocking; screen-disconnect mid-fold self-heal noted as wrap-up-at-most) — bd20fbba READY TO MERGE pending Alec.
- T7 shell: EXECUTED — ceff5db0+e2b02cd9 on origin, all 20 steps, full suite 2872/169 green (serial retry). Fable review running. Live-check items owed to Alec listed in executor report (Touch Bar gating on real hardware, HUD RM/RT, reopen/translocation/retry paths).
- WRAP-UP +1: run-tests.sh remote leg parses unquoted --filter pipes as shell pipes (quote $@ into the remote command) — found by T7.
- MACHINE NOTE: Data volume 96% full, 8.9GB free; project caches total 50MB so housekeeping can't help — the space is in simulator runtime (protected), DVTDownloads, ~/Music, ~/Library/Caches. Freeing it is ALEC's call (user data). Builds still pass at this level; contention flake risk stays elevated until freed.
- T3b popover-rows: APPROVED (fable review, 0 defects; tooltip bugfix verified complete; VO composition intact) — 414adcb4 READY TO MERGE pending Alec.
- T7 shell: FIX-FIRST (1 defect: HUD fade race — fix agent running; + AGENTS Map row). Reviewer's consolidated 10-item live-check list for Alec is in its report. DISK: simulator runtime deleted on Alec's order — 15GB free now.
- T3a popover-entrance: EXECUTED — 78619c19 on origin, full suite 2868/168 green. Fable review running. WRAP-UP +3: AGENTS rule-40 prose (AirPlay now a second empty-render exception); PopoverController:2493 stale canSelectLocalSpeaker comment; T7-owed localNetworkDeniedProvider wiring (permission card dormant until wired).
- INFRA ROOT CAUSE (blocked T2 3x + T7 3x): corrupt Sparkle WORKING COPY in the MAIN checkout's AudioutCore/.build/checkouts/Sparkle (mirror intact) — Guard 4's local confirm leg resolves through it. Repaired by removing the checkout dir (SwiftPM re-materializes from mirror). If it RE-corrupts: concurrent local confirm legs are racing in the shared main .build — find the writer / serialize local legs. WRAP-UP: consider per-worktree local-leg scratch dirs.
- T3a popover-entrance: APPROVED (fable review, 0 fix-first; reveal race clean, occlusion teardown = ordered decision, live-check owed) — 78619c19 READY TO MERGE pending Alec. WRAP-UP +1: temp-dir blocker file leak in savingSelectedDevicesAsAGroupReportsAPersistenceFailure.
- INFRA ROOT CAUSE (FINAL, supersedes the checkout-repair note): mirrors fsck clean — the Sparkle 'unable to read tree' is a RACE between CONCURRENT commit gates' local confirm legs (suite lock allows 2 slots) materializing the same checkout in the shared .build. Remedy in force: commits serialize — one git-commit gate on the machine at a time (agents check pgrep before committing). WRAP-UP: make this structural — one guard slot, or per-run scratch checkout dirs in the runner script.
- INFRA ROOT CAUSE (v3, FINAL — supersedes both prior theories): the Sparkle 'unable to read tree' occurs ONLY when a guard run FRESHLY materializes .build/checkouts while ANY concurrent SwiftPM process races the shared user-level package cache. Warm checkouts never hit it (checkout step skipped). REMEDY: pre-warm each worktree once, solo, with 'swift package resolve' before its first guard run — done for fix-data-safety/fix-shell/fix-onboarding (T5/T9 warm their own via their builds). Commit serialization kept as belt+braces. WRAP-UP: pre-resolve step in the runner script.
- T2 data-safety: FIX LANDED per reviewer prescription — 870a8a32 on origin, full suite 2868/169 clean. READY TO MERGE pending Alec (ce28c6fa + 870a8a32).
- T5 groups-window: EXECUTED — c99028fd on origin, all 23 steps, full suite 2882/168 green. Fable review running. Deferred (deliberate): P2-10 scroll headroom, icon-grid arrows, NSUndoManager, membership legend.
- TRAP (cost ~1h idle): serializing commits via pgrep -f 'usr/bin/git commit' deadlocks — the pattern matches the WAITER LOOPS quoting it. Correct check: ps -axo comm=,args= | awk '$1 ~ /git$/ && / commit/' (executable-based). Chain unblocked T7→T6→T9.
- T5 groups-window: FIX-FIRST (2 defects: stale pin tooltip on reuse; stale snapshot persists wrong member volume — fix agent queued at chain end). Wrap-up +2: weak cell-reuse test (SidebarActionsTests), DeviceIconResolverTests cache-race note. Everything else verified clean incl. T2-merge simulation conflict-free.
- T9 design-tokens: EXECUTED — e9d4ffad on origin (30 files +602/-107). Fable review running (with ratio recompute + cross-branch merge simulation).
- T9 design-tokens: APPROVED (fable review; ratios independently recomputed, all match; ConnectBrighten deviation judged correct) — e9d4ffad READY TO MERGE. WRAP-UP +2 doc one-liners: Font.detail comment says four sites (three real); SharedUI AGENTS sync-chip bullet still says tertiaryLabel. MERGE NOTES (from reviewer's merge-tree sims): vs fix-groups-window CLEAN; vs fix-popover-rows 3 conflicts — ConnectionDiagnosisView suggestion label: ROWS' 13pt WINS (drop T9's Font.detail there, then detail has 2 consumers → touch up its doc), AGENTS rail bullet: union both edits, DeviceRowConnectionStateTests: take rows' deletion; vs fix-popover-entrance 1 modify-vs-delete: take entrance's deletion (T9's 2 swaps evaporate), third swap auto-merges.
- T5 groups-window: FIX LANDED per reviewer prescriptions — 15b23c23 on origin (both defects + pinning tests, full suite green on retry). READY TO MERGE (c99028fd + 15b23c23).
- T7 shell: FIX LANDED per reviewer prescription — 2cfdad81 on origin, full suite 2873/169 clean (quiet machine; the six prior refusals were confirmed load flakes). READY TO MERGE (ceff5db0 + e2b02cd9 + 2cfdad81).
- T6 onboarding: EXECUTED — f7c1a931 on origin (18 files), full suite 2874/168 green. Fable review running — LAST review of the effort. ALL TEN TRACKS LANDED.
- NOTE: every push prints the repo-moved notice (origin still aa-hh/Audiouter.git → moved to Audiout.git); wrap-up item already recorded.
