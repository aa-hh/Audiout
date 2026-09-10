# Handover — live diagnostics (PR #148)

Written 2026-09-10 for whoever picks this up. Branch
`claude/sonos-move-no-sound-43b877`, worktree
`.claude/worktrees/sonos-move-no-sound-43b877`.

Plan: [`docs/plans/PLAN-LIVE-DIAGNOSTICS.md`](../../docs/plans/PLAN-LIVE-DIAGNOSTICS.md).
Roadmap entry 037.

## Where it stands

[PR #148](https://github.com/aa-hh/Audiout/pull/148) is **open, conflicting,
and 27 commits behind main**. Nothing is merged. Every live check is still
owed — no build from this branch has ever run on hardware, and the app in
`/Applications` is build 1603 from main, not this work.

Four slices are built, tested and pushed:

| Commit | What |
|---|---|
| `1c5ee2c2` | `Telemetry.fail(category, event, local:, shared:)`, six failure sites converted |
| `71f8720f` | The AirPlay sender's own C log goes to `~/Library/Logs/Audiout/engine.log` |
| `59f86867` | `stream_health` line: peak level and silent seconds per stream, every 5 s |
| `7f48e4c6` | `DiagnosticsBundle` + Settings › About › "Save diagnostics…" |

The branch also carries `ae0f5e66` (handled failures to PostHog error
tracking), merged in from `claude/posthog-exceptions-bc04a3`. **That commit is
still not on main**, so PR #148 is what lands it.

## Why the work exists

2026-09-05: the Sonos Move sat "connected" with packets flowing, the receiver
reported PLAYING, Spotify was playing, no sound. A relaunch fixed it. Every
live check read healthy. The local decision log had the cause (a mid-stream
drop and reconnect at 23:34:39) but could not say whether the audio sent
afterwards was silent, the sender's RTSP log was lost to an empty unified log,
and nothing on the Mac could have reached a support inbox.

## The merge is a design decision, not a mechanical fix

Main gained `54cdfea8`, "Forward the Telemetry decision log to PostHog Logs
under the usage-stats opt-in", on 2026-09-06 — the day after this branch was
written. It changes the same code, in a way that pulls against the branch's
design. **Resolve this deliberately; a careless merge leaks.**

Main's rule (denylist): `Telemetry.log` forwards *every* line to
`Analytics.log` except two Cast samplers, and `Analytics.log` drops fields
whose key is in `Analytics.deviceKeys` — `device`, `deviceID`, `uid`, `name`,
`host`, `address`.

This branch's rule (allowlist): `Telemetry.fail` takes two field sets, writes
both to the local file at `level:error`, and forwards **only `shared`** to
`Analytics.captureError`. Both call a shared private `write(...)` helper.

The leak, concretely: if the merged `write(...)` inherits main's forward, then
`fail`'s `local:` fields flow to PostHog Logs minus the denylist — and
`detail` and `reason` are **not** on that list. On this branch `detail` carries
an engine error description (can name a receiver) and `reason` carries a raw
Core Audio string.

Recommended resolution: keep main's forward inside `log` only, never in the
shared `write(...)` helper, and let `fail` forward `shared` alone. The
allowlist is the stronger rule; leave the denylist for `log`, which has no
allowlist to use.

### The six conflicting files

| File | The conflict | Note |
|---|---|---|
| `AudioutCore/Sources/AudioutCore/Telemetry.swift` | main added the forward in `log`; branch split `log`/`fail` over a shared `write` and added `level` to every line and a `settings` category | The one above. Resolve it first |
| `AudioutCore/Sources/AudioutCore/Analytics.swift` | both add a closure to `Analytics.Sink` — main adds `log`, the branch (via `ae0f5e66`) adds `captureError` | Keep all four: `capture`, `captureError`, `log`, `consentChanged` |
| `AudioutCore/Tests/AudioutCoreTests/AnalyticsTests.swift` | same, in the fakes | Every `Sink(...)` literal needs all four closures |
| `AudioutCore/Sources/AudioutOnboardingUI/UsageStatsConsentCard.swift` | both edit the consent copy | The copy must end up describing what actually ships: feature events, handled failures, *and* forwarded log lines |
| `PRODUCT.md` | both add to "Data Collection" | Same — keep both paragraphs, including the branch's "Diagnostics you send us" |
| `AudioutCore/Sources/AudioutCore/AGENTS.md` | both add rules | Keep both |

`AppDelegate.swift` auto-merges, but check it by eye: main wires
`Analytics.Sink.log` to the SDK, the branch adds `saveDiagnostics()` and moves
two `captureError` calls to `Telemetry.fail`.

## What each slice actually does

**S1 — one call for a failure the user felt.**
`Telemetry.fail(category, event, local:, shared:)` writes the local line at
`level:error` with both field sets merged, then forwards the event name and
`shared` to `Analytics.captureError` from the writer's queue (never the
caller's thread, so a `stateQueue` caller does not run the analytics sink under
its own lock). Every ordinary line now carries `level:info`, so a support
reader can grep for failures without knowing event names.

Six existing failure funnels converted, no new ones: the engine session drop,
the two connect-failure exits (converge catch and PTP gate), whole-system
capture failure, the two settings-store failures, the three Bluetooth connect
exits. Event names moved to the PostHog exception-type form —
`airplay:session_failed`, `airplay:connect_failed`,
`capture:whole_system_failed`, `settings:save_failed`,
`settings:file_corrupt`, `bt:connect_failed`. **Anything grepping the old
names (`engine_session_failed`, `bt_connect_failed`) needs the new ones.**

**S2 — the sender's log becomes a file.** `engine_logger_set_file(path, cap)`
in `shims/logger.c`, exposed as `AirPlayEngine.setLogFile`. The app names the
file where it builds the engine (`OwnToneBackend`), off under
`HeadlessRuntime`. Rotates to `engine.log.1` at 5 MB, one mutex across the
three logging threads, ISO timestamps matching `telemetry.jsonl` so the two
files read side by side. `AIRPLAYENGINE_LOG_FILE` still wins when set.

The shim deliberately has **no default path**: the engine package knows no app,
so it cannot know where an app keeps logs. Tests and `engine-probe` never call
`setLogFile` and write nothing — that is also what keeps the suites out of the
real log folder.

**S3 — did we send sound?** `StreamLevelTracker` (in `AirPlayEngine.swift`)
records the loudest sample per buffer and how long a stream has sat at or under
−60 dBFS, on `write(streams:)` — the delivery path where the bytes are already
being copied for the engine thread, never the capture render callback.
`NativeBackend`'s existing 5 s poller writes one `stream_health` line per
stream. `silent_s` is the field to read first.

Receiver-side liveness (packets acknowledged, keep-alive age) is deliberately
out: it lives in the C sender and needs a getter through the shim. The plan
records the ceiling and the upgrade path.

**S4 — one file a customer can attach.**
`DiagnosticsBundle.write(to:snapshot:)` zips both logs, a typed
`StateSnapshot`, the process's unified-log tail and recent crash-report names,
via `NSFileCoordinator` (nothing new linked). Settings › About gains "Save
diagnostics…"; `AppDelegate.saveDiagnostics()` runs the save panel, reveals the
zip and offers a mail draft. Never in the bundle: licence key, companion token,
`companion-approvals.json`, home paths. The test seeds a key and a token and
proves neither appears. No CLI adapter — an agent on this Mac reads the two
files directly.

## Live checks owed

All four need a build from this branch (after the merge) on real hardware.
None has been done.

1. One `$exception` visible in PostHog error tracking from a **notarised**
   build. Nothing has ever confirmed the path end to end; the unit test proves
   only that the sink is called.
2. `engine.log` appears beside `telemetry.jsonl` after a session, with a
   `[raop]` line per connect. **It does not exist on this Mac today** — check
   `ls ~/Library/Logs/Audiout/`.
3. `stream_health` lines show a real peak and `silent_s` at 0 while music
   plays.
4. Settings › About › Save diagnostics… produces a zip that opens, with
   `snapshot.json` naming the selected speakers.

## Traps

- **The app already has an always-on decision log.**
  `~/Library/Logs/Audiout/telemetry.jsonl` (+ `.1`), JSON lines, keys are
  `cat`/`evt`, one `sid` per launch, 10 MB cap. Read it first on any "it
  stopped working" question. Do not reach for `log show`.
- **`log show` returned nothing from the notarised app** for a whole session —
  cause never determined. That is why S2 exists.
- **Computer-use tools cannot see this app.** `request_access` rejects
  "Audiout" because it is menu-bar-only (`LSUIElement`). In-app volume and mute
  are not persisted anywhere, so they cannot be read from outside. Ask the
  owner what the panel shows.
- **Guard 4's full-suite run flakes under machine load.** On 2026-09-06 at load
  average 15 it refused three times on unrelated timing and colour assertions
  (`stopStopsCapture`, `retryWhileSecondDeviceConnecting`,
  `cardTitlesTintGoldWhileTheirRowsSound`), each passing alone. Any staged file
  with no `Foo*Tests.swift` twin — `AppDelegate.swift`, `AboutView.swift`,
  `GeneralSettingsViewController.swift` — forces the full run, so splitting the
  commit does not help. Retry with `AUDIOUT_TEST_MODE=serial git commit` and
  wait for the machine to quiet down.
- **A public type may not share a name with one in `audiout-shared`.** A commit
  guard refuses it. `DiagnosticsBundle.StateSnapshot` is named that way because
  `Snapshot` was rejected.
- Route every build and test through `scripts/build.sh` and
  `scripts/run-tests.sh` — other sessions run on this Mac, and only the
  wrappers know about the second machine.

## Loose end

`ROADMAP.jsonl` is modified and uncommitted in this worktree: entry 037 marked
in progress with the four commit hashes. Commit it with the merge, or drop it
and re-record 037 after the merge lands.
