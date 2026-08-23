# AGENTS.md word-budget cleanup — brief for a fresh session

**Status: NOT STARTED. Diagnosis only, from a background research agent on
2026-07-25. No files have been edited. Hand this brief to a fresh agent in a
new session/worktree — this is a standalone docs-only cleanup, unrelated to
any in-flight feature work.**

## The problem

The root `AGENTS.md` states a hard rule: every folder's `AGENTS.md` should be
**≤300 words**, three sections (Purpose / Rules / Map), documenting only
constraints and traps an agent could break by accident — never implementation,
never step-by-step behavior, never signatures/types (the compiler owns those),
never a call-chain narration (it rots on every refactor), never dates/
changelogs/task-ids (git owns history), never a test-coverage table (test names
own that).

**This rule is being violated repo-wide, not by one file.** A research pass
found:

| File | Word count | vs. 300-word budget |
|---|---|---|
| `AudioutSharedUI/AGENTS.md` | ~3132 | ~10x |
| `AudioutCore/AGENTS.md` | ~2496 | ~8x |
| root `AGENTS.md` | ~1410 | ~5x (over its OWN rule) |
| `dev/AGENTS.md` | ~467 | ~1.5x |
| `AudioutOnboardingUI/AGENTS.md` | ~296 | within budget |
| *(other `Sources/Audiout*UI/AGENTS.md` files — not yet individually audited)* | — | — |

**This has grown incrementally, not all at once.** `AudioutCore/AGENTS.md`
was deliberately trimmed once (commit `9bf9e06`, 2026-07-17: "10.6k → 3.6k
words" per its own log), then crept back up through roughly 14 subsequent
commits, each adding 5–30 lines to document one fix or new subsystem (T3
telemetry, T5 TCC divergence, T6 PTP helper daemon, T7 per-app routing, a
volume-reseed regression, and most recently `d1dc310` on 2026-07-25 alone
added 27 lines for the TCC permission-detection rewrite). Nobody has done a
second trim pass since the first one. `AudioutSharedUI/AGENTS.md` shows the
same pattern and is worse — it has drifted into a changelog with **dated
entries** ("2026-07-22"), which the root rule explicitly bans.

## Why this matters (not just tidiness)

The whole point of an AGENTS.md, per the root rule, is that an agent reads it
**before editing that folder** and internalizes the constraints. A file this
long defeats that purpose — it becomes something agents skim or skip rather
than actually absorb, which is exactly the failure mode "docs orient, code
decides" is supposed to prevent. It also means genuine traps are diluted
inside padding, making them easier to miss than if the file were short.

## What the research pass found, concretely

### Every AGENTS.md needs re-auditing, but two are the worst offenders
Start with `AudioutCore/AGENTS.md` and `AudioutSharedUI/AGENTS.md`. Also
check every other `Sources/Audiout*UI/AGENTS.md` (SettingsUI, PopoverUI,
WindowUI, App) — the initial pass did not individually audit all of them, only
spot-checked word counts.

### Classification framework (apply to every paragraph/bullet)
- **(a) Genuine constraint/trap — keep, but likely condense.** The
  "obvious reading is wrong" test from the root rule. Examples already
  identified in `AudioutCore/AGENTS.md`: `Device.isSelected` meaning,
  `AudioProcessResolver` multi-process requirement, `AppRouteDestination
  .isDeviceRoute`, the `.currentDevice` anti-feedback guard, `TCCAccessPreflight`
  being cached for the calling process's lifetime, `IsolatedTestCase`'s
  parallel-test isolation. These earn their place but are each padded 2–4x
  with mechanism detail that isn't the trap itself.
- **(b) Implementation description or changelog — delete outright.** Anything
  narrating a call chain (e.g. "`AppRoutingController.onRoutesDidChange` →
  `AppDelegate.pushAppRoutesToBackend` → `NativeBackend.updateAppRoutes`"),
  anything phrased as "no longer does X" (that's a commit message), any dated
  entry, any incident-history aside. One was found and flagged as worth
  removing specifically: a `RemoteControlPriming` Map entry containing a
  paragraph about a branch-name mix-up ("`claude/speaker-input-responsiveness-
  b8123f` does NOT hold this work") — pure incident history, banned by the
  root rule, and reads oddly to a future reader.
- **(d) Real trap, but buried in excess mechanism — MOVE, don't delete.** Two
  worst examples in `AudioutCore/AGENTS.md`: the volume-reseed bullet
  (~340 words) and the metering bullet (~230 words). Each contains a
  load-bearing one-sentence trap (a zero-initialized engine volume produces
  −30dB silent connect; meters read pre-volume so a low fader slider never
  shows an empty bar) wrapped in a full race-condition/call-site write-up that
  belongs in `dev/notes/` — which already hosts exactly this kind of
  write-up (see `dev/notes/stability-audit-2026-07-18.md` as the existing
  pattern) — with a one-line pointer left inline, the same convention the file
  already uses for its `STABILITY(id)` markers.
- **Map section discipline.** The root rule caps Map entries at ≤12 words
  each ("name → what it is"). Most current entries run 30–100+ words
  (`SetupModel`, `SystemAudioCaptureTCC`, `PermissionStateObserver` were
  named as examples). This alone is an estimated 400–500 words of low-risk,
  high-value trimming in `AudioutCore/AGENTS.md` — likely proportionally
  similar in others.

### Estimated result for `AudioutCore/AGENTS.md` after cuts
Purpose (~60w, unchanged) + condensed Rules (~800–900w) + trimmed Map
(~350–400w) ≈ **1200–1300 words** — roughly half the current size, but still
~4x the nominal 300-word target.

### On the 300-word target itself — likely needs to be revised, not enforced
The research pass's view: 300 words is not a realistic target for
`AudioutCore/AGENTS.md` specifically, because the root `AGENTS.md` itself
describes that package as spanning the `Device` model, the `OutputBackend`
seam and its implementations, per-app routing, AND the AppKit UI targets —
materially more surface than a single-subsystem child file like
`AudioutOnboardingUI`. The recommendation is to **explicitly raise and
document** an acknowledged budget for this file (~800–1000 words) rather than
mechanically forcing it to 300, while still cutting the genuine bloat.
Whoever picks this up should form their own view rather than take this as
given — it's a judgment call, not a measured fact.

## Explicitly flagged as NOT verified — re-check before trusting

The research pass read the docs only; it did **not** re-verify every named
trap against current Swift source. Two specific open risks it flagged:

1. Whether condensing the volume-reseed/metering write-ups down to a single
   trap sentence (plus a `dev/notes/` pointer) preserves enough protective
   value to actually stop the regression they document (a `startOp`
   continuation leak) from recurring. Move the detail rather than delete it,
   specifically to hedge this — don't summarize away the mechanism that
   explains WHY the trap exists if that's what makes it memorable enough to
   avoid.
2. Whether every cited trap is still literally true against current source
   (e.g., a claim that "`NativeBackend` has no `ConnectionDiagnosing` seam").
   This was a word-budget diagnosis pass, not an accuracy pass — treat every
   retained sentence as needing a `git grep` / read-the-code check before
   being kept, per the root `AGENTS.md`'s own stated policy ("if an AGENTS.md
   names a symbol you cannot find in source, believe the source and fix the
   doc").

## Suggested approach for the next session

1. Re-read the root `AGENTS.md` rule in full before touching anything — it is
   short and is the actual spec for this work.
2. Audit ALL `AGENTS.md` files in the repo (`find . -name AGENTS.md`), not
   just the two named here, and get a real word count + classification for
   each before deciding scope. This brief's numbers are from a first pass on
   a subset.
3. Per file, apply the (a)/(b)/(c)/(d) classification above. Delete (b),
   condense (a), move (d) to a linked `dev/notes/` doc with a one-line
   pointer left behind (following the existing `STABILITY(id)`-marker
   pattern), trim every Map entry to ≤12 words.
4. Verify every retained backticked symbol still exists via `git grep` before
   finalizing — this is what pre-commit Guard 2 checks anyway, so failing to
   do it manually just means discovering it at commit time instead.
5. For any file whose genuine, irreducible scope exceeds 300 words even after
   honest trimming (candidate: `AudioutCore/AGENTS.md`), document the raised
   budget and the reasoning for it — plausibly in the root `AGENTS.md`'s own
   rule section, so future readers know it's a deliberate exception and not
   drift.
6. This is a **docs-only** change — no code should need to move or change
   behavior. `main` is merge-only per the root `AGENTS.md`'s hard rule; do
   this work in its own worktree/branch, not directly on `main`, and land it
   as its own focused merge rather than folding it into unrelated feature
   work.
