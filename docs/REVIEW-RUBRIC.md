# Staged-diff readability rubric (Guard 7)

Every commit that stages Swift code gets a self-review against this rubric
BEFORE committing: run `scripts/self-review.sh`, read your full staged diff
with these categories in mind, fix what you find, restage, re-run the script,
then commit. Guard 7 refuses the commit until the script has been run against
the exact staged state. This is a readability review — bugs and tests are
Guard 4/6's job.

Born from the 2026-08-06 audit (`dev/notes/verbosity-audit-2026-08-06.md`):
240 findings, of which the two biggest categories were comments narrating
git-owned history and comments that had drifted into being *wrong*.

## Remove before committing

1. **Change-log narration** — "replaces the old X", "previously", "used to",
   "(fixed 2026-07-26)", "(architecture review …, defect B)", commit hashes,
   "this session". Git owns history. EXCEPTION: a past live regression cited
   as the WHY a guard exists is a trap doc — keep it, present tense.
2. **Stale claims** — "a later task wires this", "no caller passes true yet",
   "BUILD-ONLY scope" on shipped code. If you touched a comment's
   neighborhood, verify its claims still hold; a wrong comment is worse than
   none.
3. **Narration** — restating the adjacent line ("// Start the timer").
4. **Reviewer-speak** — "correctly handles", "to be safe", "purely additive,
   no new locking", "not a regression from …". You are talking to the diff
   reviewer, not the next reader; it is noise the moment the branch merges.
5. **Redundant doc comments** — `///` adding nothing beyond the signature.
   Public API keeps a doc comment, but it must say something (units,
   lifecycle, retention).
6. **Hedges** — "for now", "might not be ideal". A real ceiling becomes one
   terse sentence naming the ceiling and upgrade path.
7. **Orphan tags** — task ids that grep to nothing under `docs/`,
   `AirPlayEngine/docs/`, `dev/notes/`. Doc-anchored tags (SPEC §, D#, Q#,
   R-*, STABILITY(...), plan T-*) are live traceability — keep them.
8. **Commented-out code** and debug leftovers (bare `print` in library code —
   CLI/snapshot tools print by design).

## Naming (the part that bites hardest)

- **Misleading names** — says X, does Y (`updateRouting` that syncs
  exclusions; `displayHeight` that returns a width). Highest value; fix or
  flag, never ship silently.
- Journey names (`finalResult`, `updatedDevice`, `tempX`), type echo
  (`deviceArray`, `-State` suffixes), generic nouns in specific roles
  (`data`, `info`, `result`).
- Match the file's existing vocabulary and the domain glossary (device vs
  speaker vs output distinctions in `AudiouterCore/AGENTS.md` are deliberate).
- Scope-length rule: single letters die outside tight loops.

## Protected — never "clean up"

- Why-heavy trap comments: ordering constraints, races, TCC / Core Audio /
  AppKit gotchas, "NEVER/ONLY/must" invariants, ALL-CAPS emphasis inside
  them. This repo's long constraint comments are deliberate. Length alone is
  never a finding.
- `SPEC.md §N` citations and doc-anchored decision tags; `STABILITY(...)`;
  `razor:`; trailing `isolation-ok` / `slop-ok` markers; license headers;
  vendored C (byte-identical rule); `test_*` seam names; string literals of
  every kind (UI copy, telemetry event names, defaults keys, dlsym symbols).

## Mechanics

- `scripts/self-review.sh` writes a receipt hashed over the staged Swift
  diff; Guard 7 verifies it. Restaging Swift changes invalidates the receipt
  — review again (the re-review is the point, not the ceremony).
- The deterministic screen hard-blocks only near-certain slop ("this
  session", dated changelog parentheticals, `=====` banners). A rare
  legitimate hit takes a trailing `slop-ok` comment.
- `git commit --no-verify` remains the documented emergency escape, same as
  every guard.
- razor: ceiling — the reviewing intelligence is the committing agent itself
  reading its own staged diff; there is no LLM call in the hook (latency and
  cost train people to bypass gates — 2026 consensus). Upgrade path if this
  proves too weak: an async second-model review at PR time in CI, not a
  synchronous hook call.
