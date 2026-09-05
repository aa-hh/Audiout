# PLAN — Live diagnostics: what a support request needs

Status: DRAFT, scoped 2026-09-05 from a real failure. Decisions in §D are owed
before slices S3 and S5 start; S1, S2 and S4 can start now.

## A. The case that scoped this

2026-09-05, Audiout 1.0.0 (5), macOS 27.0. Spotify playing to the Sonos Move
over AirPlay. The owner asked "why is there no sound" at 23:36 local. Quitting
and relaunching the app fixed it at 23:39.

What the machine could tell us at 23:37, live:

| Check | Result |
|---|---|
| Routing file | Sonos Move selected, nothing else |
| AirPlay session | TCP to the Move open, audio packets flowing at ~60 KB/s |
| Sonos itself | PLAYING on its AirPlay input, volume 55, not muted |
| Spotify | playing, going into the Audiout output device |
| Unified log (`log show`) | nothing from the process, at any level, for the whole session |

Every live check read as healthy. The answer was in
`~/Library/Logs/Audiout/telemetry.jsonl` (the always-on decision log,
`Telemetry.swift`), read after the fact:

| Local time | Decision-log line | Meaning |
|---|---|---|
| 23:34:39 | `airplay engine_session_failed cause=droppedMidStream wasStreaming=true` | the Move dropped a live stream |
| 23:34:40 | `ptp_activate` → `connect_addoutput_resolved` | app reconnected in 1.6 s |
| 23:34:45 | `handoff_release reason=userDeselected` | owner clicked the Move off |
| 23:35:03 – 23:35:10 | resume, remove, reselect | owner toggling |
| 23:35:11 | `connect_addoutput_resolved` | "connected", packets flowing, no sound, until quit |
| 23:38:56 | last line of that session | quit |
| 23:39:06 | new session: `connect_addoutput_resolved` | connected, sound |

What the record could NOT say, and which a customer's email would need:

1. **Was the audio we sent after 23:35:11 silent?** No line records signal
   level anywhere between the tap and the encoder. The engine's own send
   scheduling line (`send_sched`, every 5 s) proves packets left on time, not
   that they held sound. Q4 of `PLAN-TELEMETRY-SYSTEM.md` chose not to touch the
   render path; the gap that leaves is exactly this one.
2. **Why did the Move drop the session at 23:34:39?** The engine's C sender
   logs RTSP failures (`raop.c`, `DPRINTF(E_LOG …)`) to the unified log only.
   The unified log held nothing from the process. Whether that is a persistence
   setting or a signing/entitlement effect is not determined; either way it is
   not a channel support can rely on.
3. **Nothing leaves the Mac.** The decision log is local. A customer has no
   button that produces it, and the About screen says only "Email
   support@audiout.app". The handled-failure reporting that would have put
   `engine_session_failed` in PostHog (`claude/posthog-exceptions-bc04a3`,
   `ae0f5e66`) is built, unmerged, and never live-checked.

## B. What exists today

| Channel | What it holds | Leaves the Mac? | Gap for support |
|---|---|---|---|
| Decision log (`Telemetry`) | always-on JSON lines, 8 categories, 204 call sites, 10 MB cap, session id per launch | no | no severity field; no engine-side lines; no signal-level evidence; nobody but an agent on this Mac reads it |
| Unified log (`os.Logger`, 12 loggers; engine C shim → `com.airplayengine/engine`) | companion, DACP, Bluetooth, PTP clock, write cadence; all engine RTSP warnings | no | empty for tonight's session; needs Console skills the customer does not have |
| PostHog (`Analytics`) | 46 feature events, crash autocapture; opt-in, off by default | yes, with consent | handled failures unmerged; no way to tie an event to a customer's email |
| Env-gated dev diagnostics (`AudioDiag`, `AIRPLAYENGINE_LOG_FILE`, `AIRPLAYENGINE_LOG_LEVEL`, `AUDIOUT_TCC_DIAG`) | deep traces | no | off in release; a customer cannot switch them on |
| About screen | "Questions or problems? Email support@audiout.app." | — | no attachment, no version line in the email, no diagnostics |

The bones are good: one always-on structured log with a small interface
(`Telemetry.log(category, event, fields)`), one consent-gated analytics
facade with a small interface (`Analytics.capture`, `captureError`). This plan
adds three things behind those seams and one user-facing door.

## C. Design

Vocabulary: module = interface + implementation; seam = where the interface
lives; adapter = a thing that satisfies the interface at the seam.

### C1. One seam for "a failure the user felt" — `Telemetry.fail`

**Interface.** `Telemetry.fail(_ category: Category, _ event: StaticString,
_ fields: [String: String] = [:])`. Same shape as `Telemetry.log`. Writes the
line with `"level":"error"` and forwards the same name and fields to
`Analytics.captureError`. `Telemetry.log` gains `"level":"info"` on every line
(one added key; no caller changes).

**Why one seam.** Tonight the local line existed and the PostHog event did not,
because they are two calls at two sites. A single call cannot drift. The
deletion test: remove `fail` and every failure site grows two calls and a
privacy decision of its own.

**Privacy at the seam.** `fail` sends `fields` to PostHog as-is, so the fence
(PRODUCT.md "Data Collection": no speaker names, bundle ids, paths, typed
text) is enforced by the caller choosing fields, exactly as `captureError`
does today. The decision log keeps cleartext device ids (Q6 of the telemetry
plan). Two field sets per call would be the honest shape:
`fail(category, event, local: [...], shared: [...])`, where `shared` is the
subset that may leave the Mac. Take that shape; the local set is the union.

**Sites to convert** (all existing failure funnels, none new):

| Site | Event | Shared fields |
|---|---|---|
| `NativeBackend` engine session failure (line ~8929) | `engine_session_failed` | `cause`, `wasStreaming`, `state` |
| `NativeBackend` connect timeout / `timingUnavailable` / `notResponding` / `refusedOrBusy` | `connect_failed` | `cause` |
| `NativeCaptureCoordinator` `.failed` | `capture:whole_system_failed` (already on the branch) | `kind` |
| `StoreRecovery` two modes | `settings:save_failed`, `settings:file_corrupt` (already on the branch) | Cocoa domain + code |
| `BTConnectionManager` `.failed` | `bt_connect_failed` | `cause` |
| PTP helper not approved / not bound at connect | `ptp_helper_unavailable` | `reason` |

**Prerequisite.** Merge `claude/posthog-exceptions-bc04a3` and live-check that
one `$exception` lands in PostHog from a notarised build. Nothing here works
until that is proven.

### C2. Engine log becomes a file, always, in release

**Seam already exists.** `shims/logger.c` has an optional append-to-file sink
opened from `AIRPLAYENGINE_LOG_FILE`. Today that env var is unset in release,
so every RTSP `E_LOG` and `E_WARN` line (TEARDOWN failed, SET_PARAMETER
failed, dropped packet, receiver closed) goes to the unified log and is lost.

**Change.** When the env var is unset, default the sink to
`~/Library/Logs/Audiout/engine.log`, at the existing default threshold
`E_LOG`. Add the same two-file rotation the decision log uses (5 MB active +
one rotated). Keep os_log and the stderr mirror as they are. Prefix each line
with the ISO timestamp the decision log uses so the two files interleave by
eye.

**Why not route it into the decision log.** The C shim would need a callback
into Swift, a serialisation choice per line, and the JSON writer's queue on
the engine thread. A second plain file is one `fopen` and a size check, and
the reader (a grep, or the bundle in C4) does not care which file a line is in.
Razor: ceiling is "two files, same cap"; upgrade path is a `.engine` category
if a query ever needs both in one stream.

### C3. Signal-level evidence — `stream_health`

**The gap.** Nothing records whether the audio we send carries sound.

**Where the number comes from.** Not the IOProc. The engine's write path
already measures every write (`write_cadence_drift`, `WriteLatencySnapshot`);
the mixed buffer is in hand there, off the render thread. Add one running
peak-absolute-sample per output stream, reset every window.

**Interface.** One decision-log line per output, every 5 s, alongside the
existing `send_sched`:

```
{"cat":"airplay","evt":"stream_health","device":"54:2A:1B:79:08:9E",
 "peak_dbfs":"-12.4","silent_s":"0","packets":"2153","dropped":"0",
 "rtsp_alive":"true","last_feedback_ms":"812"}
```

`silent_s` counts consecutive seconds under −60 dBFS while the output is
bound; it is the field a support reader looks at first. `last_feedback_ms` is
the age of the last answered keep-alive (`raop_keep_alive_timer_cb`,
`raop.c`), which is the only receiver-side liveness the sender has.

**Rule.** This line is written from the engine's existing periodic reporter,
the one that writes `send_sched`. It adds a `max(abs())` over the window on a
thread that already touches the buffer; nothing new runs on the IOProc.

**Which module's interface widens.** `AirPlayEngine` exposes one more
snapshot type next to `WriteLatencySnapshot`; `NativeBackend` writes the line.
The engine keeps no app concept (licensing boundary in `AirPlayEngine/AGENTS.md`).

### C4. The diagnostics bundle — one function, one button

**Interface.** `DiagnosticsBundle.write(to directory: URL) throws -> URL`.
Returns the path of `Audiout-diagnostics-<date>.zip`. That is the whole
interface; the About screen is its first adapter, a `scripts/` CLI is its
second.

**Contents.**

| File | Source | Why |
|---|---|---|
| `telemetry.jsonl`, `telemetry.jsonl.1` | copied | the decision log |
| `engine.log`, `engine.log.1` | copied | C2 |
| `snapshot.json` | built at call time | app version + build, macOS build, backend, consent state, install id, licence STATUS (never the key), selected devices with `ConnectionState`, groups, routing, every audio device with transport / rate / running / default, capture coordinator state, permission status (reported and silent probe), PTP helper state, Bluetooth-connected speakers |
| `unified-log.txt` | `OSLogStore(scope: .currentProcessIdentifier)`, last 500 entries | whatever the unified log did keep |
| `crashes.txt` | list of `~/Library/Logs/DiagnosticReports/Audiout*` names, newest 5 | pointer only; contents stay on the Mac |

Speaker and app names stay in cleartext (same call as Q6 of the telemetry
plan: the user chooses to send this file, and names are what make it
legible). The licence key, the companion token and any file path under the
home directory are never written; `snapshot.json` is built from typed fields,
not from dumping stores.

**Door.** Settings › About, below the support line:

> Questions or problems? Email support@audiout.app.
> **Save diagnostics…** — saves a file you can attach to your email. It
> contains your speaker names, your app list and the app's recent activity;
> nothing is sent until you attach it.

`Save diagnostics…` opens `NSSavePanel` defaulting to the Desktop, writes the
zip, reveals it in Finder, and offers **Email support** which opens a `mailto:`
with the subject `Audiout 1.0.0 (5) on macOS 27.0` and a body that says to
attach the saved file. (`mailto:` cannot attach; the copy says so.)

Analytics: `support:diagnostics_saved` with no properties.

**Also a CLI.** `scripts/diagnostics.sh` calls the same function through the
existing headless harness pattern, so an agent on this Mac makes the same
bundle the customer would. Same seam, two adapters.

### C5. (Decision D1) Upload instead of email attachment

An upload route on the licence server (`POST /diagnostics`, body = the zip,
header = licence key hash, storage = the release R2 bucket) would give the
About button a "Send to Audiout" path that returns a six-character code the
customer pastes into the email. It removes the attach-a-file step, which is
where non-technical customers drop off. It is also a new public endpoint on
the only backend we own, with abuse and retention questions, in the backend
lane. Not in this plan's slices; D1 decides whether it joins.

## D. Decisions owed

Recommended option first.

- **D1 — Upload or attach?** Attach (C4) for v1. Upload (C5) only if support
  email shows customers failing to attach.
- **D2 — Engine log always-on at `E_LOG` in release?** Yes. It is the level the
  shim already defaults to; the file is capped at 10 MB like the decision log.
  Alternative: `E_WARN` only, which loses the TEARDOWN / SET_PARAMETER
  failures that explain a drop.
- **D3 — Measure peak level on the engine write path (C3)?** Yes, with the
  rule that nothing new runs on the IOProc. Alternative: keep Q4 of the
  telemetry plan as-is and accept that "connected but silent" stays
  undiagnosable from logs.
- **D4 — Field split in `Telemetry.fail` (`local:` / `shared:`)?** Yes. The
  alternative, one field set fenced by convention, is how tonight's line came
  to carry a cleartext device id that could never go to PostHog.

## E. Slices

Each slice merges alone and is useful alone.

| Slice | Work | Test that buys its place |
|---|---|---|
| S1 | Merge `claude/posthog-exceptions-bc04a3`; live-check one `$exception` in PostHog from a notarised build; add `Telemetry.fail` with the local/shared split; convert the six sites in C1 | `TelemetryTests`: a `fail` line carries `level:error` and the installed analytics sink receives exactly the `shared` fields; a `log` line carries `level:info` |
| S2 | `logger.c` default file sink + rotation; timestamp prefix | `AirPlayEngineTests`: with the env var unset the sink opens under the Logs directory; a write past the cap rotates once and the active file restarts |
| S3 | `stream_health` snapshot in the engine; line written from `NativeBackend`'s periodic reporter | engine test feeds a silent buffer and a −6 dBFS buffer through the write path and reads back `peak_dbfs` and `silent_s`; no assertion on timing |
| S4 | `DiagnosticsBundle.write`; About button + save panel + mailto; `scripts/diagnostics.sh`; PRODUCT.md "Data Collection" gains the paragraph "Diagnostics you send us" | bundle test: the zip contains the five entries; `snapshot.json` never contains the licence key or the home directory path (assert on a seeded key and `NSHomeDirectory()`) |
| S5 | C5 upload, if D1 says so | backend lane |

Docs that land with the code: `AudioutCore/Sources/AudioutCore/AGENTS.md` gets
the `fail` rule ("a failure the user felt goes through `Telemetry.fail`, never
`log` plus `captureError`"), `AirPlayEngine/AGENTS.md` names the engine log
file, PRODUCT.md gains the diagnostics paragraph.

## F. What this does not do

- No live dashboard, no remote log streaming, no per-customer identity in
  PostHog. Support still starts with an email.
- No change to the opt-in default. A customer who declined analytics sends
  nothing automatically; the bundle is the only channel, and it is their click.
- No render-path instrumentation. C3 measures on the write path, after the mix.
