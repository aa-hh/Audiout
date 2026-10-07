# Audiout — Claude Code orientation

A native AppKit macOS app that sends system audio to multiple AirPlay 2 speakers with per-device volume, mute, saved groups, and per-app routing.

**Read [`AGENTS.md`](AGENTS.md) before doing anything.** It contains the architectural rules, constraint explanations, and traps that the code alone cannot convey. Each subdirectory has its own `AGENTS.md` with folder-level rules — read the nearest one before editing **or tracing** code in that folder. The trap you are chasing is often already written down there.

## Package layout

| Path | What it is |
|---|---|
| `AudioutCore/` | The whole app: Swift package with the core library, AppKit UI targets, and the shipping menu-bar executable |
| `AirPlayEngine/` | Standalone Swift package: vendored AirPlay 2 C sender wrapped in a Swift actor. Separate package on purpose — licensing boundary, no app concepts inside |
| _(external)_ `audiout-shared` | Two products: ProbeKit (the sync-probe DSP) and AudioutProtocol (the companion wire protocol), at https://github.com/aa-hh/audiout-shared. MIT, not GPL — the closed-source iPhone app links the same code, so it has one home outside both apps. Pinned by version in `AudioutCore/Package.swift` |
| `dev/` | Offline dev tooling (fake speakers, dev scripts); `dev/notes/` holds research briefs |
| `marketing/video/` | Remotion demo videos for YouTube and the feeds — the only JavaScript in the repo. Rendered by the `Marketing videos` GitHub Actions workflow, not locally |
| `docs/SPEC.md` | Product spec — the source of truth for *what* to build |
| `scripts/make-app.sh` | Wraps the executable into a signed `.app` bundle (required for TCC/process-tap) |
| `scripts/make-staging.sh` | The staging environment: a standing `com.audiout.Audiout.staging` build pointed at the staging licence server |
| `scripts/run-on-vm.sh` | macOS 14 checks: builds a self-contained `.app`, starts the `sonoma-14.4` tart VM on the mule if it's off, and launches the app there with dummy devices (incl. a fake Bluetooth speaker). `scripts/guest-setup.sh` is the one-time ssh setup inside a new VM |

## iOS companion app

The iPhone companion now lives in its own private repository,
`aa-hh/audiout-remote` — this repo no longer contains it. Build it from here
with `scripts/ios.sh build --root <that checkout>`.

## First steps in a fresh clone

```bash
# Enable the pre-commit guards (once per clone)
git config core.hooksPath .githooks

# Keep local main a fast-forward mirror of origin/main (every 2 minutes)
cp scripts/launchd/com.audiout.sync-main.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.audiout.sync-main.plist
# Remove it with: launchctl bootout gui/$(id -u)/com.audiout.sync-main
```

Guards: **Guard 1** blocks every commit on `main`. **Guard 4/6** run the test suites on any commit touching Swift sources — Guard 4 runs only the suites covering the staged files (`.githooks/guard-test-scope.sh` derives them: a staged file matches tests by name with any `+Aspect` part dropped, so `NativeBackend+Bluetooth.swift` runs the `NativeBackend*Tests` files; a file that matches no test by name runs every test file importing its target or a target built on it, except for `AudioutCore` and the targets it depends on; a deleted file maps by its old name; a commit where no file maps to any test only compiles, through `scripts/build.sh`, and leaves testing to the pull request's full run. `bash scripts/test-guard-test-scope.sh` tests these rules and checks the script's target table against `AudioutCore/Package.swift`). `AUDIOUT_FULL_SUITE=1` forces the full run. The full suite runs on GitHub: the `tests` workflow, on every pull request and again in the merge queue. Guard 6 (AirPlayEngine, ~2s) always runs in full. **Guard 9** blocks any newly-added line that could put a window on a real screen during a test run (see "Tests must stay invisible" in [`AudioutCore/AGENTS.md`](AudioutCore/AGENTS.md)). **Guard 7** blocks a Swift commit whose added comments match near-certain slop patterns (rubric in [`docs/REVIEW-RUBRIC.md`](docs/REVIEW-RUBRIC.md)). **Guard 11** blocks a new test without its 'turns red' sentence, `print` in tests, a new one-test file, and a real-time wait in a test (sleeps, `asyncAfter`, `SuiteWait.settle(`, any `.wait(timeout:`, or a Timeout/Delay/Deadline/Interval/Grace/Window/Seconds value set to a fraction of a second; `real-time-ok: <reason>` exempts, and a hang ceiling is a reason); **Guard 12** blocks ruling phrasing or over-budget growth in a folder AGENTS.md and any rewrite of an AGENTS-HISTORY.md line.

## Build & run

```bash
# Compile check — use this, not a bare `swift build`:
bash scripts/build.sh

# Offline UI work (no hardware, no TCC):
bash scripts/run-app.sh

# Real hardware (needs a signed .app and TCC grant first):
bash scripts/make-app.sh
open build/Audiout.app

# Licence gate / purchase / resend, wired to the STAGING server:
bash scripts/make-staging.sh
```

`build.sh` and `make-app.sh` route the compile to the second Mac under the same
rule `run-tests.sh` uses (see Tests below). `make-app.sh` moves only the
compile — assembly, dylib bundling and codesigning always happen locally, so the
`.app` is identical either way. `AUDIOUT_BUILD_LOCAL=1` forces local.

**Know what is being tested, then pick the bundle id — and say which you
picked and why when you hand the build over** (owner's call, 2026-08-28):

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

- **Testing the licence gate, the purchase return or "I lost my key"** — none
  of it exists without a licence server in Info.plist, so `swift run` cannot
  reach any of it: **`bash scripts/make-staging.sh`**. Standing
  `com.audiout.Audiout.staging` id, pointed at `license-staging.audiout.app`,
  approved once and silent after. It is a different daemon identity from the
  dev id, so it needs no live-test slot and cannot clobber a dev build someone
  else is testing.

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
it under the owner overwrites the `.app` they are testing and starts a second copy
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
- **Release the moment the owner gives a verdict** on the build you handed over.
  A slot nobody frees is 45 minutes of the machine's testing capacity gone.
- **Expiry is 45 minutes**, after which the next agent takes it over with a
  loud warning. That warning is not permission — if the owner may still be at the
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

**Always go through `run-tests.sh` / `build.sh` / `make-app.sh` / `ios.sh` / `run-app.sh`, never a bare `swift test`, `swift build`, `swift run`, `xcodebuild`, or `swift package`** — filtered runs included. The Claude Code hook denies these bare commands; the wrapper scripts are the ONLY things that know about the machine-wide capacity permit pool, the second Mac, and the unchanged-sources cache; typing the bare command opts out of all three and pins the work to this machine, which is also the one running every other agent.

Both Macs' selected developer directory must be a full Xcode install, not
Command Line Tools — check with `xcode-select -p`; a path under
`/Library/Developer/CommandLineTools` cannot run `swift test` for any package
on macOS. `run-tests.sh` refuses with a message rather than let this surface as
a mysterious build failure, and its message names the exact command for the
Xcode it finds: `sudo xcode-select -s
/Applications/<Xcode>.app/Contents/Developer`. `AUDIOUT_TEST_MODE=serial`
runs the suite strictly one test at a time, for flake hunting only, never for a gate.

**Code a real-time test drives brings that test along.** Before committing a production change, run `bash scripts/real-time-tests.sh <changed source files>`; every test it lists gets converted to the wait helpers in root [`AGENTS.md`](AGENTS.md) ("How a test waits without the wall clock") in the same PR, or gets a roadmap entry naming the test, its wait and the code that drives it.

**Flaky tests are quarantined.** A test that fails in the merge queue and passes on rerun is skipped with a dated reason and a GitHub issue, in the same PR that hits it.

**A pass covers everything it ran.** The runner stamps each green run in `/tmp/audiout-suite-cache` and skips a later run on byte-identical sources that an earlier pass already covered: a green full run satisfies any later filtered run, and a green `--filter A` lets a later `--filter A|B` run only `B` (the runner prints which suites it skipped). This is how a filtered run while coding counts toward Guard 4 at commit. `AUDIOUT_TEST_NO_CACHE=1` turns the cache off for a run; `bash scripts/test-suite-cache.sh` tests the cache itself.

**A full run on the mule runs as several processes.** When a full run goes to the mule, the runner builds once there and then runs the suite as up to three `swift test` processes at the same time, one per free mule permit, so it may take every free mule permit; other sessions' runs fall back to this Mac as they do whenever the mule is full. The split is the one the GitHub `tests` workflow uses, from `scripts/lib/suite-shards.sh`. The workflow runs four shards; a local run of three processes covers list 3's suites in its last process, which skips lists 1 and 2. The runner prints one `Test run with N tests in M suites passed after T seconds` line summed over the shards. `AUDIOUT_TEST_SHARDS=1` runs one process as before; filtered runs, local runs and `AUDIOUT_TEST_MODE=serial` never shard. A shard that finds no free mule permit runs on this Mac by itself. `bash scripts/test-suite-shards.sh` tests it.

**Capacity.** Every compile and test run — local or on the mule — takes one capacity permit from a machine-wide pool. Local pool: `git config audiout.localSlots` (set to 2 on 2026-09-10). Mule pool: `git config audiout.remoteSlots` (set to 2 on 2026-10-04). When the mule is full, work falls back to local immediately (no wait). Which machine a job is offered to first is `git config audiout.testPrefer`: `remote` (set 2026-10-04, owner's call) offers every job to the mule first and runs it here only when every mule permit is held, because this machine also carries the agents, the editor and any app under live test. `permits` (the setting from 2026-09-11) sent each job to whichever Mac had more free permits, which gave this Mac an equal share instead of only the overflow. When the local pool is full, the runner waits up to 1800 seconds, printing progress; if the ceiling is reached, it proceeds uncapped with a loud warning (never refuses a commit). `bash scripts/capacity.sh status` shows who holds which permit on both machines and which setting is active. `bash scripts/test-capacity.sh` tests the permit pool itself. A mule job now dies with the local run that started it — the runner kills its own ssh client as soon as it is gone, and the mule-side job kills itself when its ssh session disappears — so an orphaned run gives its mule permit back within seconds instead of holding it for the 45-minute ceiling. Commands typed in a terminal outside Claude Code bypass the hook but not the permits, which live in the scripts.

The mule runs macOS 26.5 with only the Xcode 27 beta installed, so `remote_run` pins `SDKROOT` explicitly before the toolchain probe; if mule runs start reporting "environment not usable", that pin is the first thing to check.

## Critical workflow rules

- **`main` accepts nothing but the merge queue.** Never commit or merge into `main` locally (Guard 1 refuses a commit there) and never push to it; GitHub's ruleset refuses anything that does not come through the queue. Work in a worktree branch. Local `main` is a fast-forward mirror of `origin/main`, kept by `scripts/sync-main.sh` on a 2-minute launchd timer (`bash scripts/test-sync-main.sh` self-tests it); never commit on it (Guard 1 still refuses), and cut worktrees from `origin/main` after `git fetch`.
- **Work in worktrees, not the `main` checkout.** Worktrees live in `.claude/worktrees/<slug>/`. Never edit files in the `main` checkout.
- **Every worktree branch must have a GitHub counterpart.** When creating a worktree, immediately push the branch to origin:
  ```bash
  git fetch origin
  git worktree add .claude/worktrees/<slug> -b claude/<slug> origin/main
  cd .claude/worktrees/<slug>
  git push -u origin claude/<slug>
  ```
  Commits on the branch are pushed to `origin/<branch>` as work progresses. When the task is done, end with:
  ```bash
  git push -u origin HEAD
  gh pr create --fill
  bash scripts/review-branch.sh   # run the passes it prints as subagents, then: bash scripts/review-branch.sh --continue
  ```
  **Then stop and ask the owner before merging.** Only after a clear yes, run `gh pr merge --merge --auto`, which queues the PR to land on its own once both checks are green. Never queue a merge unasked; the merge-approval hook asks on `gh pr merge` and on the app's auto-merge switch either way. The two required checks are `tests` (the full suite on GitHub) and `review` (the commit status `--continue` posts, with one PR comment listing the findings). The reviewers run as subagents of your session because headless `claude -p` is refused on this account. Only a HIGH finding fails `review`: fix it, commit, push, and run the script again, which reviews only the fix; a third run refuses. A status belongs to one commit, so run the script after every push: when the push left the branch's own non-Markdown lines unchanged (main merged in, a docs-only commit) it re-posts the last round's status on the new HEAD without using a round; otherwise it is the next round. A PR whose two rounds are used up and whose head then changes needs either a `review` status posted by the owner or the ruleset's owner bypass; that is the intended point where the owner decides.
- **If you find uncommitted edits in the `main` checkout: stop and ask.** Never stash, reset, or discard them — they belong to another session.
- **Finished with a worktree (branch merged + live-verified, or abandoned-but-pushed)?** `touch .claude/worktrees/<slug>/.prunable` — `scripts/housekeeping.sh` removes it safely at the next build, and also collects stale build caches — every `.build` in the tree plus Xcode's `iOS DeviceSupport` and `DerivedData` (see AGENTS.md).

## Backend env var

`AIRPLAY_BACKEND=mock` (default for dev) · `AIRPLAY_BACKEND=native` (real hardware, needs TCC + signed app)

## Usage analytics (PostHog)

Feature usage is tracked through `AudioutCore/Sources/AudioutCore/Analytics.swift`, a consent-gated facade. PostHog itself is linked ONLY to the `AudioutApp` target (same scoping as Sparkle) — never `import PostHog` anywhere else. Event names are an external contract: PostHog insights reference them by string, so treat every `Analytics.capture("...")` name like a public API.

- **The full event list lives in `audiout-shared`.** `docs/analytics-events.md` in that repository is the one table of every event both this app and the iPhone app send, with properties and allowed values. Add a new event there before sending it from here.
- **Don't silently break tracking.** When you move, refactor, or delete code containing an `Analytics.capture` call, the call moves with the behavior — same event name, same properties, still success-gated (fire only after the action actually happened, never before its guard). If a feature is removed outright, say so in the task report so the event's dashboard owner knows the stream ends.
- **New user-facing features get instrumented.** Any new user action (button, toggle, gesture, funnel step) gets an `Analytics.capture` at its choke point, named `category:object_action` in snake_case (e.g. `scene:created`, `bt_sync:wizard_finished`). Grep `Analytics.capture` for the live event list and match its style.
- **Privacy fence (PRODUCT.md "Data Collection"):** properties never carry speaker/device names, bundle IDs, network identifiers, audio content, license keys, or free-text user input. Counts, enum-like strings, and booleans only.
- **A failure the user felt goes through `Telemetry.fail(category, event, local:, shared:)`**, never `Telemetry.log` plus `Analytics.captureError` as two calls. It writes the local decision-log line at `level:error` and forwards only `shared` to PostHog error tracking; `local` holds what may not leave the Mac (device ids, error descriptions). Its `event` is the PostHog exception type, so it follows the same `category:object_action` naming and the same external-contract rule. Grep `Telemetry.fail` alongside `Analytics.capture` for the live list.
- **Internal machines mark themselves.** If `~/Library/Application Support/Audiout/internal` exists, every build on that Mac stamps `internal: true` on its events; PostHog's test-account filter excludes those plus any bundle id other than `com.audiout.Audiout`. Touch that file on any Mac whose production copy must not count as a real user.
- Consent is on by default from first launch through the trial, and the Settings switch turns it off for good once flipped. A paid user is asked once — the onboarding card for a direct buy, a one-time popover when a trial converts. `Analytics.capture` is always safe to call (no-op without sink + consent) — never wrap it in your own consent checks, and never call `PostHogSDK` directly outside `AppDelegate`.

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

## Agent skills

### Issue tracker

Local markdown under `.scratch/<feature-slug>/`: `spec.md` plus one file per ticket in `issues/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary, recorded as a `Status:` line in each ticket file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` at the root plus `docs/adr/`. See `docs/agents/domain.md`.
