# Audiout — Claude Code orientation

A native AppKit macOS app that sends system audio to multiple AirPlay 2 speakers with per-device volume, mute, saved groups, and per-app routing.

**Read [`AGENTS.md`](AGENTS.md) before doing anything.** It contains the architectural rules, constraint explanations, and traps that the code alone cannot convey. Each subdirectory has its own `AGENTS.md` with folder-level rules — read the nearest one before editing **or tracing** code in that folder. The trap you are chasing is often already written down there.

## Package layout

| Path | What it is |
|---|---|
| `AudioutCore/` | The whole app: Swift package with the core library, AppKit UI targets, and the shipping menu-bar executable |
| `AirPlayEngine/` | Standalone Swift package: vendored AirPlay 2 C sender wrapped in a Swift actor. Separate package on purpose — licensing boundary, no app concepts inside |
| `dev/` | Offline dev tooling (fake speakers, dev scripts); `dev/notes/` holds research briefs |
| `docs/SPEC.md` | Product spec — the source of truth for *what* to build |
| `scripts/make-app.sh` | Wraps the executable into a signed `.app` bundle (required for TCC/process-tap) |
| `ios/` | iPhone companion app (SwiftUI). **Not in this checkout** — staged on `claude/ios-staging` until the whole app is ready to merge into `main`. See "iOS companion app" below. |

## iOS companion app

The iPhone companion (`ios/AudioutRemote/`) is built entirely on
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
AIRPLAY_BACKEND=mock swift run --package-path AudioutCore AudioutApp

# Real hardware (needs a signed .app and TCC grant first):
bash scripts/make-app.sh
open build/Audiout.app
```

`build.sh` and `make-app.sh` route the compile to the second Mac under the same
rule `run-tests.sh` uses (see Tests below). `make-app.sh` moves only the
compile — assembly, dylib bundling and codesigning always happen locally, so the
`.app` is identical either way. `AUDIOUT_BUILD_LOCAL=1` forces local.

**Every build handed over for testing gets its OWN bundle id and app name —
every time, even for a one-line change.** Bump a version suffix on each
rebuild; never reuse an id that has already been launched:

```bash
APP_NAME="Audiout Sync v2" BUNDLE_ID="com.audiout.Audiout.syncv2" bash scripts/make-app.sh
```

macOS pins TCC grants (system audio capture, Bluetooth, local network) to the
bundle id AND the code signature. Re-signing the same id with changed code
invalidates the grant, and the failure mode is erratic — stale grants, silent
denials, sometimes no prompt at all — so the tester ends up debugging
permissions instead of the feature. A fresh id always gets a clean prompt.
Bare `make-app.sh` builds the DEFAULT `com.audiout.Audiout`, which is the
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
- **Finished with a worktree (branch merged + live-verified, or abandoned-but-pushed)?** `touch .claude/worktrees/<slug>/.prunable` — `scripts/housekeeping.sh` removes it safely at the next build, and also collects stale build caches — every `.build` in the tree plus Xcode's `iOS DeviceSupport` and `DerivedData` (see AGENTS.md).

## Backend env var

`AIRPLAY_BACKEND=mock` (default for dev) · `AIRPLAY_BACKEND=native` (real hardware, needs TCC + signed app)

## Usage analytics (PostHog)

Feature usage is tracked through `AudioutCore/Sources/AudioutCore/Analytics.swift`, a consent-gated facade. PostHog itself is linked ONLY to the `AudioutApp` target (same scoping as Sparkle) — never `import PostHog` anywhere else. Event names are an external contract: PostHog insights reference them by string, so treat every `Analytics.capture("...")` name like a public API.

- **Don't silently break tracking.** When you move, refactor, or delete code containing an `Analytics.capture` call, the call moves with the behavior — same event name, same properties, still success-gated (fire only after the action actually happened, never before its guard). If a feature is removed outright, say so in the task report so the event's dashboard owner knows the stream ends.
- **New user-facing features get instrumented.** Any new user action (button, toggle, gesture, funnel step) gets an `Analytics.capture` at its choke point, named `category:object_action` in snake_case (e.g. `scene:created`, `bt_sync:wizard_finished`). Grep `Analytics.capture` for the live event list and match its style.
- **Privacy fence (PRODUCT.md "Data Collection"):** properties never carry speaker/device names, bundle IDs, network identifiers, audio content, license keys, or free-text user input. Counts, enum-like strings, and booleans only.
- Consent is opt-in and off by default. `Analytics.capture` is always safe to call (no-op without sink + consent) — never wrap it in your own consent checks, and never call `PostHogSDK` directly outside `AppDelegate`.

## Paddle integration

Paddle lives in **one place**: the Node.js license server (private repo
`aa-hh/audiout-license-server`). The Mac and iOS apps are Swift — they do a
**soft license check** against that server and carry **no Paddle SDK**. So a
"Paddle task" almost always means the license server, not this repo.

When writing or modifying license-server code that integrates with Paddle:

- Always check current Paddle documentation via the `paddle-docs` MCP server before suggesting code. The Paddle API and SDKs evolve frequently — do not rely on training data alone.
- Use the official Node.js SDK — `@paddle/paddle-node-sdk`. (The server is Node; there is no Python/Go/PHP surface here. If that ever changes, pull the right SDK from Paddle's docs.)
- All development uses the sandbox environment. Sandbox API keys contain `_sdbx`; sandbox client-side tokens are prefixed with `test_`.
- Always verify webhook signatures before acting on the payload — `paddle.webhooks.unmarshal()`.
- For destructive account changes (updating prices, archiving products, canceling subscriptions), ask for explicit confirmation before calling the `paddle-sandbox` or `paddle-live` MCP server.
- Use `paddle-sandbox` by default — nothing is live yet. Only call `paddle-live` when the prompt explicitly mentions live, production, or real customer data.
- API keys and webhook secrets live in environment variables — never inline credentials into code.
