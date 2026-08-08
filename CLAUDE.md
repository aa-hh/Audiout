# Audiouter — Claude Code orientation

A native AppKit macOS app that sends system audio to multiple AirPlay 2 speakers with per-device volume, mute, saved groups, and per-app routing.

**Read [`AGENTS.md`](AGENTS.md) before doing anything.** It contains the architectural rules, constraint explanations, and traps that the code alone cannot convey. Each subdirectory has its own `AGENTS.md` with folder-level rules — read the nearest one before editing in that folder.

## Package layout

| Path | What it is |
|---|---|
| `AudiouterCore/` | The whole app: Swift package with the core library, AppKit UI targets, and the shipping menu-bar executable |
| `AirPlayEngine/` | Standalone Swift package: vendored AirPlay 2 C sender wrapped in a Swift actor. Separate package on purpose — licensing boundary, no app concepts inside |
| `dev/` | Offline dev tooling (fake speakers, dev scripts); `dev/notes/` holds research briefs |
| `docs/SPEC.md` | Product spec — the source of truth for *what* to build |
| `scripts/make-app.sh` | Wraps the executable into a signed `.app` bundle (required for TCC/process-tap) |

## First steps in a fresh clone

```bash
# Enable the pre-commit guards (once per clone)
git config core.hooksPath .githooks
```

Guards: **Guard 1** blocks direct commits on `main` (merges only). **Guard 4/6** run the test suites on any commit touching Swift sources. **Guard 7** blocks Swift commits until the staged-diff readability self-review has run — `scripts/self-review.sh`, rubric in [`docs/REVIEW-RUBRIC.md`](docs/REVIEW-RUBRIC.md).

## Build & run

**Always pass `--build-system native`** to every `swift build` / `swift test` /
`swift run` in this repo. It is not a preference: the default engine
(`swiftbuild`) relinks all 9 executables on *every* invocation even when nothing
changed, and each engine keeps its own ~800 MB cache — so one command using the
default undoes the caching for all the others. Measured: inner loop 15.5s → 10.6s,
no-op build 5.0s → 0.76s. Full rationale at the `swift test` call in
[`scripts/run-tests.sh`](scripts/run-tests.sh).

```bash
# Offline UI work (no hardware, no TCC):
AIRPLAY_BACKEND=mock swift run --build-system native --package-path AudiouterCore AudiouterApp

# Real hardware (needs a signed .app and TCC grant first):
bash scripts/make-app.sh
open build/Audiouter.app
```

## Tests

```bash
# Inner loop — scope to the suite(s) you touched:
swift test --build-system native --package-path AudiouterCore --filter PopoverControllerTests

# Full suite (use this, not bare swift test):
bash scripts/run-tests.sh
```

## Critical workflow rules

- **`main` is merge-only.** Never `git commit` on `main`. Work in a worktree branch; reach `main` via merge only. Guard 1 enforces this.
- **Work in worktrees, not the `main` checkout.** Worktrees live in `.claude/worktrees/<slug>/`. Never edit files in the `main` checkout.
- **Every worktree branch must have a GitHub counterpart.** When creating a worktree, immediately push the branch to origin:
  ```bash
  git worktree add .claude/worktrees/<slug> -b claude/<slug>
  cd .claude/worktrees/<slug>
  git push -u origin claude/<slug>
  ```
  Commits on the branch are pushed to `origin/<branch>` as work progresses. The branch merges into `main` BOTH as a local `git merge` AND as a GitHub PR — so origin/main and local main stay in sync.
- **If you find uncommitted edits in the `main` checkout: stop and ask.** Never stash, reset, or discard them — they belong to another session.
- **Finished with a worktree (branch merged + live-verified, or abandoned-but-pushed)?** `touch .claude/worktrees/<slug>/.prunable` — `scripts/housekeeping.sh` removes it safely at the next build, and also collects stale `.build` caches (see AGENTS.md).

## Backend env var

`AIRPLAY_BACKEND=mock` (default for dev) · `AIRPLAY_BACKEND=native` (real hardware, needs TCC + signed app)
