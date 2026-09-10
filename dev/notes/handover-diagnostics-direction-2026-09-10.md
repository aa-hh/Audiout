# Handover: diagnostics and what leaves the Mac

Written 2026-09-10. Replaces three notes: the live-diagnostics handover in this
folder, `HANDOVER-posthog-connection-errors.md` on
`claude/postfog-connection-errors-85597b`, and
`HANDOFF-posthog-logs-2026-09-10.md` in the website repo. Read this one.

Mac branch `claude/resolve-handover-conflicts-31aa60`, worktree
`.claude/worktrees/resolve-handover-conflicts-31aa60`, at `bf3b3d22`.
Plan: [`docs/plans/PLAN-LIVE-DIAGNOSTICS.md`](../../docs/plans/PLAN-LIVE-DIAGNOSTICS.md).
Roadmap entry 037.

## The ruling

The owner ruled on 2026-09-10 that the app's diagnostic log stops going to
PostHog. Main had gained `54cdfea8` on 2026-09-06, which forwarded every
`Telemetry.log` line to PostHog Logs under the usage-stats opt-in and stripped
six field names on the way out (`device`, `deviceID`, `uid`, `name`, `host`,
`address`). It shipped in 1.1.1. Live records from the owner's own Mac carried
app bundle ids (`org.mozilla.firefox`, `com.spotify.client`), speaker names
rendered by `NativeBackend.telemetryDeviceList`, and raw error strings such as
`processNotYetAudible(bundleID: "com.apple.Music")`. PRODUCT.md "Data
Collection" promises none of those ever leave the machine.

Widening the strip list was rejected. The forward is deleted, and the rule is an
allowlist with one implementation:
`Telemetry.fail(category, event, local:, shared:)` writes both field sets to
`telemetry.jsonl` at `level:error` and sends only `shared` to
`Analytics.captureError`. Ordinary log lines never leave the Mac; the user ships
them by hand through Settings › About › Save diagnostics.

Three sub-rulings came with it:

- `connection:failed` and `connection:connected` capture only for a speaker the
  user wants audio on (`wantsAudio`). `connection:connected` keeps its existing
  skip for `device.isLocalDevice`.
- `config.preloadFeatureFlags = false` in `configurePostHog()`. The pinned SDK
  posted to `/flags` at every launch regardless of opt-out, carrying the install
  id, bundle id and OS and app version. It is harmless only while the project
  has zero feature flags.
- The Setup spine copy drops its "network details" promise. Network type is
  sent, and the consent card already says so.

## Branches and PRs

| Where | Branch or PR | State |
|---|---|---|
| Mac | `claude/resolve-handover-conflicts-31aa60`, `bf3b3d22` | the merge, plus these docs |
| Mac | `claude/rhc-fix1-connection-gate`, `278f0975` | connection gate, merges into the branch above |
| Mac | `claude/rhc-fix2b-flags-preload` | feature-flag preload, being built 2026-09-10 |
| Mac | `claude/rhc-fix3-setup-copy`, `84a08ce7` | Setup copy, merges in the same way |
| Website | PR #38 | privacy and support pages |
| audiout-shared | PR #11 | `docs/analytics-events.md` |
| Licence server | PR #6 | its own logging docs |
| Mac | PR #148 | superseded by `bf3b3d22`, close it |

The three PR numbers came with the handover and were not re-checked from this
worktree.

Four documents state what leaves the Mac and move together with any change to
it: `PRODUCT.md` "Data Collection", `UsageStatsConsentCard.bodyText`, the
website's privacy page and its support page about usage statistics, and
`audiout-shared/docs/analytics-events.md`.

## What is merged

Four slices from PR #148, all built, tested and pushed, none live-checked.

**S1, one call for a failure the user felt** (`1c5ee2c2`). `Telemetry.fail`
writes the local line with both field sets merged, then forwards the event name
and `shared` to `Analytics.captureError` from the writer's queue, so a
`stateQueue` caller never runs the analytics sink under its own lock. Every
ordinary line now carries `level:info`, so a support reader can find failures
without knowing event names. Six existing failure funnels converted, none new:
the engine session drop, the two connect-failure exits, whole-system capture
failure, the two settings-store failures, the three Bluetooth connect exits.
Event names took the PostHog exception-type form: `airplay:session_failed`,
`airplay:connect_failed`, `capture:whole_system_failed`, `settings:save_failed`,
`settings:file_corrupt`, `bt:connect_failed`. Anything grepping the old names
(`engine_session_failed`, `bt_connect_failed`) needs the new ones.

**S2, the sender's log becomes a file** (`71f8720f`). `engine_logger_set_file`
in `shims/logger.c`, exposed as `AirPlayEngine.setLogFile`, written to
`~/Library/Logs/Audiout/engine.log`. The app names the path where it builds the
engine; the shim deliberately has no default, because the engine package knows
no app. Rotates at 5 MB, ISO timestamps matching `telemetry.jsonl` so the two
files read side by side.

**S3, did we send sound** (`59f86867`). `StreamLevelTracker` records the loudest
sample per buffer and how long a stream has sat at or under minus 60 dBFS, on
the delivery path where the bytes are already being copied, never on the capture
render callback. `NativeBackend`'s existing five-second poller writes one
`stream_health` line per stream. Read `silent_s` first.

**S4, one file a customer can attach** (`7f48e4c6`).
`DiagnosticsBundle.write(to:snapshot:)` zips both logs, a typed state snapshot,
the process's unified-log tail and recent crash-report names. Settings › About
gains "Save diagnostics…". Never in the bundle: licence key, companion token,
the approved-phone list, home paths. The test seeds a key and a token and proves
neither appears.

The branch also carries `ae0f5e66`, handled failures to PostHog error tracking,
which was never on main on its own.

## Live checks owed

Nothing here has run on hardware. The first one runs unattended; the rest need
the owner.

Unattended recipe for the settings-corruption path, verified by discovery on
2026-09-10:

```bash
bash scripts/livetest.sh acquire --label resolve-handover-conflicts
cp ~/Library/Application\ Support/com.audiout.Audiout.dev/groups.json /tmp/groups.backup.json
APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" APP_VERSION=99.0.0 bash scripts/make-app.sh
printf 'not json' > ~/Library/Application\ Support/com.audiout.Audiout.dev/groups.json
ls -l ~/Library/Logs/Audiout/telemetry.jsonl
open build/Audiout\ Dev.app
```

Never launch the binary inside the bundle; `open` is what gives it its TCC
identity. After about 45 seconds expect one
`"cat":"settings","evt":"settings:file_corrupt","level":"error"` line and an
empty `posthog.logsFolder` under the dev id's Application Support. The app
blocks in a modal alert, so wait out the SDK's 30-second flush and then
`pkill -f "Audiout Dev.app/Contents/MacOS"`. Restore the backup and delete the
`groups.corrupt-*.json` the app wrote. In PostHog expect an error-tracking issue
`settings:file_corrupt` with `$app_version = 99.0.0`, and zero `audiout-mac` log
records at that version. Release the slot with `bash scripts/livetest.sh done`.

Still owed after that:

1. One `$exception` in PostHog error tracking from a notarised build. The unit
   test proves only that the sink is called.
2. `engine.log` appears beside `telemetry.jsonl` after a session, with a `[raop]`
   line per connect. It does not exist on this Mac today.
3. `stream_health` shows a real peak and `silent_s` at 0 while music plays.
4. Save diagnostics produces a zip that opens, with `snapshot.json` naming the
   selected speakers.
5. A selected speaker dropping still captures `connection:failed`, and an
   unselected one does not.

## Owner only

- Freeing TCP port 5000 from Control Center so the fake speaker can bind.
- Any real stream, which is what proves `engine.log`, `stream_health` and the
  `airplay:*` failures.
- Anything Bluetooth.
- Save diagnostics, which needs the save panel.
- `scripts/purge-stale-ptp-helpers.sh --apply`, which needs `sudo`.

## Traps

- Dev builds write the same `~/Library/Logs/Audiout/telemetry.jsonl` as the
  shipping app. Filter by the launch's `sid` before believing a line is yours.
- The dev id's `routing.json` names a real speaker, so never turn on
  `general.reconnectAtLaunch` unattended: the app will connect to it and play.
- `dev/README.md` used to say AP1-only receivers are never driven. That was
  false and is fixed; `NativeBackend.swift:39-48` is the truth.
- An error report from `Telemetry.fail` has no usable stack trace. The send runs
  on the telemetry writer's queue, so the trace the SDK builds shows that queue
  and not the failing code. The exception type is the only locator.
- `connection:failed` never meant "the user's connection failed". It fired for
  any AirPlay 2 speaker on the network losing its `_airplay._tcp` advert for
  more than three seconds. One install produced 357 of them, 356 with cause
  `vanished`, largest burst 16 events in 20 milliseconds, zero user actions
  during the bursts, the same pattern on 1.1.0 and 1.1.1. That was the defect;
  consent was working the whole time.
- No git tags exist. Identify a release by commit: 1.1.1 is `f7cde25c` build
  1603, 1.1.0 is `c3584c8a` hand-numbered build 7. PR #163 is not in 1.1.1.
  `54cdfea8` and the three-second advert debounce `2632ad41` both are.
- PostHog cannot join logs and events in one query, different clusters. Use
  `execute-sql`.
- A `--filter` matching nothing exits 0 and prints "passed". Grep the output for
  a `Test run with N tests` line instead.
- Never a bare `swift build` or `swift test`. Only `scripts/build.sh` and
  `scripts/run-tests.sh` know about the second Mac, the concurrency cap and the
  cache.
- The `AudioutApp` target is invisible to the test suite, so anything in
  `AppDelegate.swift` verifies with a build and a grep, not a test.
- The Agent tool's worktree isolation forks from `main`, not from your branch.
- Guard 4's full-suite run flakes under machine load. Any staged file with no
  test twin forces the full run, so splitting the commit does not help. Retry
  with `AUDIOUT_TEST_MODE=serial`.
- Computer-use tools cannot see this app: it is menu-bar only, so
  `request_access` rejects it. Ask the owner what the panel shows.

## Still true elsewhere

The licence server and the website keep their PostHog logging; only the Mac's
was removed. Filter the PostHog Logs view by `service.name`: `license-server`
(always on, one record per `log.*` call) and `website` (always on, errors only).
`audiout-mac` records exist for 1.1.1 and stop there.

Three licence-server rules, in `~/Projects/Audiout License Server`:

1. The message is a fixed string and everything variable goes in the attributes
   object. That is what keeps the Workers Logs alerts armed.
2. Three messages are matched by those alerts: `EMAIL SEND FAILED`,
   `WEBHOOK SIGNATURE REJECTED`, `WEBHOOK DISPATCH FAILED`. Renaming one
   silently disarms an alert.
3. Never a licence key, a companion token, a raw email or a raw IP. Emails go in
   as `to_hash` and IPs as `ip_hash`, through `hashEmail()` and `hashIP()` in
   `env.ts`. Hashing rather than dropping was the owner's call, so one
   customer's lines can still be found when they write in.

The iPhone app has no PostHog SDK, no analytics and no consent screen, and was
left alone. `audiout-shared/docs/analytics-events.md` lists nine phone events as
though they exist; they do not.

## Loose ends inherited

- `dev/notes/trial-spec-2026-09-05.md` has an uncommitted one-line edit
  belonging to the owner: the trial validate body carries `companion_token`. It
  is not on main. Commit it or ask.
- Main is several commits past the published 1.1.1. A local test build reaches
  nobody; a release notarizes and flips the manifest every installed copy polls,
  and needs a version number from the owner. Ask which before building.
