# {{PROJECT_NAME}}

## Purpose

{{ONE_LINE_DESCRIPTION}}. `CONTEXT.md` defines the domain words; `docs/adr/`
records decisions. This file orients an agent to where things live and the
rules that apply everywhere.

## What belongs in an AGENTS.md (HARD RULE)

An AGENTS.md tells an agent what the **code cannot**, before it edits that
folder. It is not a summary of the code.

**The test, applied to every line: would this become wrong if someone changed the
code without thinking about docs?** If yes, it does not belong. Document intent,
constraints and traps — never implementation.

**Three sections, ≤300 words per folder AGENTS.md:**

1. **Purpose** — what lives here, why it is separate, what it must never do.
2. **Rules** — constraints an agent breaks by accident: architectural
   boundaries, invariants, and **traps** (where the obvious reading is wrong).
   This is the highest-value content in the file; give the *why* in a clause.
3. **Map** — one line per type or file, ≤12 words: name → what it is.

**Never document:** signatures, parameters, defaults or types (the compiler owns
them) · what a function does step by step (read it) · flows narrating a call
chain (they rot on every refactor) · dates, changelogs, "NEW", task or decision
ids (git owns history) · test-coverage tables (the test names own that).

**Every symbol you name is a rot point** — Guard 2 verifies each one exists, so
name only what earns it. Over budget means you are describing code.

**Over-budget history goes in a sibling file, never here.** Dated decisions,
incident write-ups and long-form trap explanations live in that folder's
`AGENTS-HISTORY.md` (append-only, not maintained, never scanned by Guard 2),
and `AGENTS.md` links it in one line. A one-line trap may keep its date. This
root file carries repo-wide policy and is exempt from the three-section cap.

Corollary for readers: **docs orient, code decides.** If an AGENTS.md names a
symbol you cannot find in source, believe the source and fix the doc.

## Folder Map

<!-- One line per top-level folder: path → what it is. Each folder with
     rules of its own gets an AGENTS.md. -->
- `scripts/` → the only sanctioned way to build, test, review and land.
- `.githooks/` → commit and push guards; settings in `project.conf`.
- `docs/review/` → instructions for each branch-review pass.
- `.scratch/` → local issue tracker (`docs/agents/issue-tracker.md`).

## Rules (all targets)

- **Build and test only through `scripts/build.sh` and `scripts/test.sh`.**
  They are the one place that knows how this repo builds; a Claude hook denies
  the bare commands.
- **"Does this code exist anywhere?" needs more than `git grep`.** Unreachable
  commits and other worktrees' uncommitted work are invisible to it. Also
  check `git stash list`, the reflog, `git fsck --unreachable` and the other
  worktrees before concluding something was never written.
- **When a fix rests on a claim about live system state, verify the claim with
  a real command before writing the fix.** Tests encode what you believed; a
  running system in the failing state shows what is true.
- **Flag finished worktrees; never hand-delete them.** A worktree can hold
  another session's only copy of unpushed work. When a branch is merged (or
  abandoned with everything pushed), `touch .claude/worktrees/<slug>/.prunable`
  and leave removal to a cleanup step that refuses a dirty or unpushed tree.
- **Dev tooling that outlives its session is labelled, parked and purgeable.**
  Anything that keeps running after the session that made it (a launchd/cron
  job, login item, file watcher, watchdog) must (a) carry a name starting
  `{{PROJECT_SLUG}}.dev.`, (b) live in the repo's `dev/`, never inside the
  app's own data directory, and (c) be removable by a purge script updated in
  the same change. Unlabelled tooling dropped onto a machine runs unnoticed
  for days.
- **A busy shared resource is reported, not waited on.** When a lock, slot or
  device another agent holds blocks you, say who holds it, go do other work,
  and retry later. Never sit in a wait loop.

## Tests

Tests are a tool for catching regressions where they are likely and costly,
not a coverage target. Every test is a permanent tax on every commit and every
refactor, so write one when it pays for itself.

**Write a test when the code:**
- carries logic with branches or edge cases a reader could get wrong:
  parsing, validation, calculations, state machines, date/time, money;
- guards something whose failure is expensive or silent: persistence formats
  and migrations, auth/permissions, billing, data loss, security boundaries;
- is a public contract other code or other teams depend on (an API, a CLI's
  output, a wire or file format);
- just broke: a bug fix gets a regression test that fails without the fix;
- sits in a review risk path (`is_risk_path` in `scripts/review-branch.sh`).

**Usually skip a test for:** thin glue that only wires other tested parts
together, straight-line code with no decisions, framework or library
behaviour, configuration, one-off scripts, prototypes, and UI layout or copy
(check those by eye). If the only way to test it is to mock everything around
it, the test checks the mocks — test the logic underneath instead, or skip it.

**When you do write one:**
1. **It names its defect.** One comment sentence stating the code change that
   would turn it red. Can't write that sentence, don't write the test.
2. **Test behaviour through the public surface,** not private helpers or call
   order, so a refactor that keeps behaviour keeps the test green.
3. **Test the axis that varies.** A value that is constant across cases gets
   one assertion, not one per case.
4. **Extend before adding:** a row in an existing table beats a new test; a
   new test beats a new file.
5. **A test that cannot fail is deleted, not patched** — self-comparisons,
   asserting a constructor's own argument, reading back a value the code just
   wrote. They read as coverage and cover nothing.
6. **No wall-clock waits.** Drive time through an injectable clock, or poll
   until the condition holds with a generous ceiling. Never sleep for a fixed
   interval and hope; when real timing is the thing under test, mark the line
   `real-time-ok: <reason>`.
7. **Tests don't share mutable global state** (env vars, temp paths, shared
   databases, singletons) without isolating it; shared state is how suites
   that pass alone flake together.

**Flaky tests are quarantined, not ignored.** A test that fails and then
passes on a rerun — at pre-push or anywhere else — is skipped in the same PR
that hit it, with a dated reason and a ticket in `.scratch/`. Rerunning until
green is not a fix.
- **A change inside a review risk path is scoped before it is built.** The
  paths are `is_risk_path` at the top of `scripts/review-branch.sh`. State
  the function's invariants and enumerate the cases first; write those cases
  as tests; then the code.
<!-- Add project-wide rules here: architectural seams, boundaries, traps. -->

## `main` takes changes only through reviewed pull requests (HARD RULE)

**Never commit, merge or push onto `main` yourself.** Everything is authored
and committed in your own worktree and reaches `main` only through a pull
request. Guard 1 refuses any commit on `main`; the pre-push hook refuses a
push to it. End every task with:

```bash
git push -u origin HEAD          # pre-push runs the full suite
gh pr create --fill
bash scripts/review-branch.sh    # run the passes it prints as subagents, then:
bash scripts/review-branch.sh --continue
```

Then **stop and ask the owner before merging.** Only after a clear yes, run
`sh scripts/land.sh`, which refuses unless the full suite passed on the PR's
head and the `review` status there is green. This repo has no CI: the
pre-push hook is the test gate and `land.sh` is the merge queue.

**Do not work in the `main` checkout at all.** Merely *editing* it starts the
accident: another agent that cannot merge past loose edits commits them to
unblock itself, and `main` then carries docs or half a feature whose other
half lives in a different session's worktree.

**If you find uncommitted edits in the `main` checkout: stop and ask.** Never
`reset --hard` / `checkout --` / `stash` them away. They belong to another
session and are unrecoverable once discarded.

**Guards** (`.githooks/`; enable once per clone with `sh scripts/setup.sh`,
override once with `--no-verify`):

- **Guard 1 blocks** any commit on `main`.
- **Guard 2 warns** when an AGENTS.md names a symbol absent from the commit
  being created (not `main`, not the working tree).
- **Guard 7 blocks** added comments matching near-certain slop patterns
  (`slop-ok` exempts a line; rubric [docs/REVIEW-RUBRIC.md](docs/REVIEW-RUBRIC.md)).
- **Guard 12 blocks** a folder AGENTS.md that gains ruling phrasing or grows
  while over its 300-word budget, and any removed line in an
  AGENTS-HISTORY.md; `bash scripts/test-guard-agents-docs.sh` self-tests it.
- **Guard 4 blocks** a commit staging code under `SOURCE_PATHS` whose
  `scripts/test.sh` run fails.
- **pre-push blocks** a push to `main` and a push whose full suite fails.
- **The review** (`scripts/review-branch.sh`, not a hook) picks skip, cheap
  (one pass) or full (four parallel reviewers plus a confidence scorer) from
  the diff size and risk paths, posts one PR comment and the `review` commit
  status. Only a surviving HIGH fails it; fix, push and run it again — round
  2 reviews only the fix, a third run refuses. A push that leaves the
  branch's own non-Markdown lines unchanged re-posts the last status without
  using a round.
