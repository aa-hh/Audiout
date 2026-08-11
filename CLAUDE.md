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
| `ios/` | iPhone companion app (SwiftUI). **Not in this checkout** — staged on `claude/ios-staging` until the whole app is ready to merge into `main`. See "iOS companion app" below. |

## iOS companion app

The iPhone companion (`ios/AudiouterRemote/`) is built entirely on
`claude/ios-staging` — a long-lived integration branch, not a one-off
feature branch — kept off `main` on purpose so Mac-only changes keep
merging without waiting on the whole iOS app. `main` has no `ios/`
directory at all right now.

**Before any iOS task, start from that branch, not `main`:**

```bash
cd .claude/worktrees/ios-staging   # already checked out; git pull if stale
# or, if that worktree doesn't exist yet:
git worktree add .claude/worktrees/ios-staging claude/ios-staging
```

Commit iOS work there (merging other `claude/ios-*` branches into it as they
land), and push to `origin/claude/ios-staging`. It merges into `main` as one
unit later, on Alec's go-ahead — not per-branch.

## First steps in a fresh clone

```bash
# Enable the pre-commit guards (once per clone)
git config core.hooksPath .githooks
```

Guards: **Guard 1** blocks direct commits on `main` (merges only). **Guard 4/6** run the test suites on any commit touching Swift sources. **Guard 7** blocks Swift commits until the staged-diff readability self-review has run — `scripts/self-review.sh`, rubric in [`docs/REVIEW-RUBRIC.md`](docs/REVIEW-RUBRIC.md).

## Build & run

```bash
# Compile check — use this, not a bare `swift build`:
bash scripts/build.sh

# Offline UI work (no hardware, no TCC):
AIRPLAY_BACKEND=mock swift run --package-path AudiouterCore AudiouterApp

# Real hardware (needs a signed .app and TCC grant first):
bash scripts/make-app.sh
open build/Audiouter.app
```

`build.sh` and `make-app.sh` route the compile to the second Mac under the same
rule `run-tests.sh` uses (see Tests below). `make-app.sh` moves only the
compile — assembly, dylib bundling and codesigning always happen locally, so the
`.app` is identical either way. `AUDIOUTER_BUILD_LOCAL=1` forces local.

**Every build handed over for testing gets its OWN bundle id and app name —
every time, even for a one-line change.** Bump a version suffix on each
rebuild; never reuse an id that has already been launched:

```bash
APP_NAME="Audiouter Sync v2" BUNDLE_ID="com.audiouter.Audiouter.syncv2" bash scripts/make-app.sh
```

macOS pins TCC grants (system audio capture, Bluetooth, local network) to the
bundle id AND the code signature. Re-signing the same id with changed code
invalidates the grant, and the failure mode is erratic — stale grants, silent
denials, sometimes no prompt at all — so the tester ends up debugging
permissions instead of the feature. A fresh id always gets a clean prompt.
Bare `make-app.sh` builds the DEFAULT `com.audiouter.Audiouter`, which is the
live `/Applications` copy: never overwrite it for a test.

## Tests

```bash
# Inner loop — scope to the suite(s) you touched:
bash scripts/run-tests.sh --filter PopoverControllerTests

# Full suite:
bash scripts/run-tests.sh
```

**Always go through `run-tests.sh` / `build.sh`, never a bare `swift test` or
`swift build`** — filtered runs included. These wrappers are the ONLY things
that know about the second Mac, the machine-wide concurrency cap and the
unchanged-sources cache; typing the bare command opts out of all three and pins
the work to this machine, which is also the one running every other agent.

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
