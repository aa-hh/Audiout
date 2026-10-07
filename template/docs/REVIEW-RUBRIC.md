# Readability rubric (Guard 7 and the branch review)

Two consumers. Guard 7's deterministic screen runs at commit and blocks only
the near-certain slop patterns below. The branch review,
`scripts/review-branch.sh`, runs on each pull request; its instruction files
in `docs/review/` carry a digest of this file. Readability is one category of
that review; bugs come first.

## Remove before committing

1. **Change-log narration** — "replaces the old X", "previously", "used to",
   "(fixed 2026-07-26)", commit hashes, "this session". Git owns history.
   EXCEPTION: a past live regression cited as the WHY a guard exists is a
   trap doc — keep it, present tense.
2. **Stale claims** — "a later task wires this", "no caller passes true yet".
   If you touched a comment's neighborhood, verify its claims still hold; a
   wrong comment is worse than none.
3. **Narration** — restating the adjacent line ("// Start the timer").
4. **Reviewer-speak** — "correctly handles", "to be safe", "purely additive".
   You are talking to the diff reviewer, not the next reader.
5. **Redundant doc comments** — adding nothing beyond the signature. Public
   API keeps one, but it must say something (units, lifecycle, ownership).
6. **Hedges** — "for now", "might not be ideal". A real ceiling becomes one
   terse sentence naming the ceiling and the upgrade path.
7. **Orphan tags** — task ids that grep to nothing under `docs/`.
   Doc-anchored tags (ADR numbers, spec sections) are live — keep them.
8. **Commented-out code** and debug leftovers.

## Naming (the part that bites hardest)

- **Misleading names** — says X, does Y. Highest value; fix or flag, never
  ship silently.
- Journey names (`finalResult`, `updatedItem`, `tempX`), type echo
  (`itemArray`), generic nouns in specific roles (`data`, `info`, `result`).
- Match the file's existing vocabulary and the glossary in `CONTEXT.md`.
- Scope-length rule: single letters die outside tight loops.

## Protected — never "clean up"

- Why-heavy trap comments: ordering constraints, races, platform gotchas,
  "NEVER/ONLY/must" invariants. Length alone is never a finding.
- Doc-anchored tags; `razor:` notes (a deliberate simplification with its
  upgrade path); trailing `slop-ok` markers; license headers; vendored code;
  string literals of every kind (UI copy, event names, config keys).

## Mechanics

- The screen hard-blocks only near-certain slop ("this session", dated
  changelog parentheticals, banner rules). A rare legitimate hit takes a
  trailing `slop-ok` comment. `git commit --no-verify` is the emergency escape.
- The reviewing models run once per pull request (twice at most), never
  inside a hook, as subagents of the session that owns the branch:
  `bash scripts/review-branch.sh`, run the passes it prints, then
  `bash scripts/review-branch.sh --continue`. `/pr-review` is the deliberate,
  manual PR-comment review; it never runs automatically.
- Fewer correct findings beat many doubtful ones, and a complexity finding
  must name exactly what to delete and what replaces it.
