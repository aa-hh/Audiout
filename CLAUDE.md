# Audiout — Claude Code orientation

A native AppKit macOS app that sends system audio to multiple AirPlay 2 speakers with per-device volume, mute, saved groups, and per-app routing.

**Read [`AGENTS.md`](AGENTS.md) before doing anything.** It contains the architectural rules, constraint explanations, and traps that the code alone cannot convey. Each subdirectory has its own `AGENTS.md` with folder-level rules — read the nearest one before editing **or tracing** code in that folder. The trap you are chasing is often already written down there.

## Package layout

| Path | What it is |
|---|---|
| `AudioutCore/` | The whole app: Swift package with the core library, AppKit UI targets, and the shipping menu-bar executable |
| `AirPlayEngine/` | Standalone Swift package: vendored AirPlay 2 C sender wrapped in a Swift actor. Separate package on purpose — licensing boundary, no app concepts inside |
| _(external)_ `audiout-shared` | The companion wire protocol, at https://github.com/aa-hh/audiout-shared. MIT, not GPL — the closed-source iPhone app links the same code, so it has one home outside both apps. Pinned by version in `AudioutCore/Package.swift` |
| `dev/` | Offline dev tooling (fake speakers, dev scripts); `dev/notes/` holds research briefs |
| `docs/SPEC.md` | Product spec — the source of truth for *what* to build |
| `scripts/make-app.sh` | Wraps the executable into a signed `.app` bundle (required for TCC/process-tap) |

## iOS companion app

The iPhone companion now lives in its own private repository,
`aa-hh/audiout-remote` — this repo no longer contains it. Build it from here
with `scripts/ios.sh build --root <that checkout>`.

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

**Know what is being tested, then pick the bundle id — and say which you
picked and why when you hand the build over** (Alec, 2026-08-28):

- **Testing the permissions path itself** — onboarding, TCC grants (system
  audio capture, Bluetooth, Local Network), the PTP helper's Login Items
  approval, or any first-run gate: **fresh id every time**, so the flow starts
  from a virgin state and you see the real prompts.

  ```bash
  APP_NAME="Audiout Sync v2" BUNDLE_ID="com.audiout.Audiout.syncv2" bash scripts/make-app.sh
  ```

- **Everything else** — UI, layout, audio behaviour, bug fixes: **reuse the
  standing dev id**, approved once and silent thereafter.

  ```bash
  APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh
  ```

Why the split. macOS pins TCC grants to the bundle id AND the code signature,
but *how* it pins depends on the signature: an **ad-hoc** signature has no
stable identity, so the grant re-pins to the binary's hash and every rebuild
goes erratic — stale grants, silent denials, sometimes no prompt at all. That
is the failure this rule was originally written against. Builds are
**Developer ID** signed now (`make-app.sh` picks the identity up
automatically), and TCC then stores a signature-based requirement that
**survives every rebuild of the same id** — see the same reasoning at
`scripts/make-app.sh:132` and in `PermissionMode.swift`.

Reusing one dev id also dodges a second wall: since 2026-08-28 macOS refuses
`SMAppService` daemon registration for every NEW bundle id until someone
clicks Allow in the Background (System Settings › General › Login Items &
Extensions). One dev id = one approval, ever.

Run **one copy of the dev id at a time** — two copies under one id fight over
the same daemon identity and the loser's `register()` silently no-ops. Bare
`make-app.sh` builds the DEFAULT `com.audiout.Audiout`, which is the live
`/Applications` copy: never overwrite it for a test.

### Hold the live-test slot before touching the dev id

One agent at a time may build or launch `com.audiout.Audiout.dev`. Rebuilding
it under Alec overwrites the `.app` he is testing and starts a second copy
fighting the running one for the same daemon identity — both fail silently.
`scripts/livetest.sh` is the machine-wide slot; `make-app.sh` refuses to build
the dev id unless you hold it.

```bash
bash scripts/livetest.sh acquire --label <your branch>   # 0 = yours, 2 = busy
bash scripts/livetest.sh status                          # who has it, who is waiting
bash scripts/livetest.sh done                            # free it
```

- **Busy? Report and keep working.** `acquire` never blocks — exit 2 names the
  holder, how long they have held it, and your place in line. Say that in your
  next message, go do something else, retry later. Never sit in a wait loop.
- **Release the moment Alec gives a verdict** on the build you handed over.
  A slot nobody frees is 45 minutes of the machine's testing capacity gone.
- **Expiry is 45 minutes**, after which the next agent takes it over with a
  loud warning. That warning is not permission — if Alec may still be at the
  speakers, ask before you build.
- Only the shared dev id is gated. A **fresh handover id** is a different
  bundle and a different daemon identity, so it needs no slot and cannot
  clobber the dev build — reach for it when the slot is busy and you just need
  a build in someone's hands.

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
