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
