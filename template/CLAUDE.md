# {{PROJECT_NAME}} — Claude Code orientation

{{ONE_LINE_DESCRIPTION}}.

**Read [`AGENTS.md`](AGENTS.md) before doing anything.** It holds the
architectural rules, constraints and traps the code alone cannot convey. Each
subdirectory may have its own `AGENTS.md` — read the nearest one before
editing **or tracing** code in that folder.

## First steps in a fresh clone

```bash
sh scripts/setup.sh               # enables the git hooks
sh scripts/setup.sh --sync-main   # macOS: also keep local main mirroring origin/main
```

## Build & test

```bash
sh scripts/build.sh               # compile / typecheck
sh scripts/test.sh                # fast run (what Guard 4 runs at commit)
sh scripts/test.sh --full         # full suite (what pre-push runs)
```

**Always go through these wrappers, never the bare build or test command.**
The Claude hook in `.claude/hooks/guard-bash.sh` denies the bare commands.

There is **no CI**. The pre-push hook is the full-suite gate, and
`scripts/land.sh` is the merge queue.

## Critical workflow rules

- **Never commit on or push to `main`.** Guard 1 and pre-push refuse it.
- **Work in worktrees, not the `main` checkout.** Worktrees live in
  `.claude/worktrees/<slug>/`:
  ```bash
  git fetch origin
  git worktree add .claude/worktrees/<slug> -b claude/<slug> origin/main
  cd .claude/worktrees/<slug>
  git push -u origin claude/<slug>
  ```
- **Finish every task with** a push, `gh pr create --fill`, and
  `bash scripts/review-branch.sh` (run the passes it prints as subagents,
  then `bash scripts/review-branch.sh --continue`).
- **Then stop and ask the owner before merging.** Only after a clear yes, run
  `sh scripts/land.sh`. The hook asks on any merge either way.
- **Uncommitted edits in the `main` checkout: stop and ask.** Never stash,
  reset or discard them — they belong to another session.

## Agent skills

- **Issue tracker:** local markdown under `.scratch/<feature-slug>/` — see
  `docs/agents/issue-tracker.md`.
- **Triage labels:** `docs/agents/triage-labels.md`.
- **Domain docs:** `CONTEXT.md` plus `docs/adr/` — see `docs/agents/domain.md`.
- **`/pr-review`:** manual adversarial PR review (`.claude/skills/pr-review/`).
