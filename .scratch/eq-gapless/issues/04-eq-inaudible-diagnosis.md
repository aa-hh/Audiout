# 04 — "Bass up = quieter, no more bass" on the Move 2: find out why, then fix

Status: scoped, not started — Track 0 is a GATE the owner has to run before any code
Blocked by: 03 (Track C is the code under suspicion)
Worktree: `.claude/worktrees/equalizer-latency-optimization-d714da` (branch
`claude/equalizer-latency-optimization-d714da`, HEAD d7828aa2). The live-test slot is
already held under label `eq-livetest` — inherit it, do not re-acquire, do not release
it without the owner's verdict.

Symptom, owner, Sonos Move 2 over AirPlay: "whenever I put up the bass, the volume goes
down and the bass stays where it was." Reported against the 087 build (an automatic
makeup trim, since REJECTED and reverted) and reported again afterwards.

Every anchor below was re-grepped at d7828aa2.

## Hard constraints for every track

- Never change what the EQ does to the sound without an owner ruling. 087 was rejected
  because an automatic trim makes a boost quieter; a boost must raise its band and leave
  everything else alone. Levels, curve shapes and defaults are the owner's call.
- A flat `DeviceEQ` stays byte-identical passthrough and never constructs an
  `EQProcessor` (`EQProcessor.swift:27-30`, `NativeBackend.swift:3490-3494`).
- Tests only through `bash scripts/run-tests.sh --filter <Suite>`; quote the
  `Test run with N tests` line in every report — a filter that matches nothing is green.
- Every new test names, in one comment sentence, the code change that turns it red.
- Rebuild for the owner as the standing dev id:
  `APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh`.
- Adversarial review of this ticket before it is called done.

## Evidence already gathered (do not redo)

1. `EQProcessorTests` passes in the eq-livetest tree: `Test run with 19 tests in 1 suite
   passed`, including `bassShelfLiftsFiftyHertz`. The filter maths is right.
2. UI wiring is right: `EQEditorView.swift:536` sets `eq.bassDB` from the bass slider,
   `configureGainSlider` (`:264`) is −12…+12, `quantizedGain` (`:583`) has no sign flip.
   The only path from the editor to a backend is
   `AppDelegate.swift:2334 backend.setEQ(eq, for: deviceID, commit: committed)`.
3. Nothing in the EQ path writes volume: `setEQ` (`NativeBackend.swift:3283-3310`)
   touches no volume state.
4. `stream_health.peak_dbfs` is measured host-side on the exact bytes handed to the
   engine per stream (`AirPlayEngine.swift:1270` records
   `entry.cbuf`; `StreamLevelTracker.record`, `:2601-2621`). Two streams reading the
   same peak in the same window means the same bytes.
5. Session `F6B3B999-5885-47FF-AE1C-CD4B0651476C`, every window where stream 0 and a
   home stream both carried audio, home-minus-stream-0 peak in dB:
   - 02:45–03:16 Z and the two windows right after the 03:24:54 Z reconnect: deltas run
     0.0 to −12.4, essentially never positive (one +0.4, one +1.4).
   - 03:20:08 Z onward for home 2147483650, and 03:25:34 Z onward for home 2147483651
     (sixty consecutive windows to the end of the log): delta EXACTLY 0.0.
   - Write counts advance at the same rate on both streams in those windows, so the
     equality is not a stream being written less often.
6. The running app is NOT the build that is on disk. pid 5166 started
   `Tue Sep 15 04:44:22` local and its mapped executable is inode 155001821 /
   15091616 bytes; the file at that path is now inode 155017826 / 15089984 bytes,
   mtime 04:50. The `eq-livetest` worktree had `claude/eq-headroom-087` merged in at
   04:37:27 (reflog c75a3716) and was reset back to the feature branch at 04:48:32,
   after the app was launched. So the process the owner has been listening to was
   built from a tree that CONTAINED the rejected 087 trim, and the trim-free build
   made at 04:50 has never been run.
7. `~/Library/Application Support/com.audiout.Audiout.dev/device-eq.json` (written
   05:25 local = 03:25 Z) holds three entries — `C4:38:75:0E:BF:4A`,
   `C4-38-75-0E-BF-4A:output`, `A4:E9:75:F1:F0:DA` — each with every gain 0, balance 0
   and `loudness: true`. `DeviceEQ.isFlat` requires `!loudness` (`DeviceEQ.swift:47`),
   so all three are non-flat and each should build a processor with a +6 dB shelf at
   100 Hz and +3 dB at 10 kHz (`EQProcessor.sections(for:)`, `:383-391`). The store
   drops flat entries, so these were written deliberately by a commit.
8. Same session: `engine_bind {"output":"0x0000C438750EBF4A","stream":"1"}` and
   `scope_conflict {"device":"C4:38:75:0E:BF:4A","stage":"routeDemoted","stream":"2",
   "bundleIDs":"[com.apple.Music]","winner":"wholeSystem"}` — Music was routed per-app
   to this speaker at least once. A device with a live per-app binding is skipped by
   `pushEQPlanLocked` (`:3458`) and bypassed with `.perAppRouting` (`:3352-3356`).
9. `stream_health`'s `devices` field is empty on every line, including home streams,
   because it is built from `streamBindings` alone (`NativeBackend.swift:8617`) — the
   per-app map. After Track C the whole-system map is `wholeSystemStreamByDevice`, so
   the log can no longer say which speaker a home stream belongs to.

## Hypotheses, ranked

- **H0 — the owner was listening to the 087 build all along.** Evidence 6 dates the
  running image before the revert; evidence 5's negative deltas are exactly what an
  automatic peak-response trim does (hold the boosted band, drop everything else),
  and that IS the reported symptom. Settled by Track 0 alone.
- **H1 — the published plan carries no processor for that speaker's stream.** Evidence
  5's sixty exactly-equal windows say the shaped entry's `processor` was `nil`, i.e.
  `eqByDeviceID[id]` was flat at push time (`:3460 eqByDeviceID[id] ?? .flat`) even
  though the store held a non-flat curve (evidence 7). Sub-cases, all reached by the
  same instrumentation: the id `wholeSystemStreamByDevice` is keyed by differs from the
  id `eqByDeviceID` is keyed by (evidence 7 shows two ids for one physical speaker, and
  `?? .flat` turns a key miss into silence with NO bypass reason on the row); the device
  is in `added` but skipped for a stale `streamBindings` entry (evidence 8); the curve
  reached the store but not `eqByDeviceID` at the moment of the push.
- **H2 — the plan is right and the coordinator writes the unshaped copy.** The write
  loop (`NativeCaptureCoordinator.swift:1918-1936`) copies `enginePCM` per entry and
  runs `stream.processor` on it; `isPassthrough` (`EQProcessor.swift:526-528`) is only
  true for a single unshaped stream 0. Cheap to rule out, low prior — the plan it reads
  is the snapshot the same instrumentation prints.
- **H3 — the engine fans the wrong buffer.** `airplay_write` matches
  `obuf->data[i].stream_id != ams->stream_id` (`sender/airplay.c:4364-4370`); a master
  session left on stream 0 would feed the speaker flat audio. This would NOT change
  what `stream_health` reports (the peak is taken before the engine thread), so it
  survives H1/H2 being disproved and no earlier.
- **H4 — the EQ is applied and `peak_dbfs` cannot show it.** Demoted by evidence 5:
  sixty windows at exactly 0.0 dB is not a measurement blind spot. Kept only as the
  residue if Tracks 0-2 clear everything else; demonstrating it means a direct
  recording of the speaker's output (owner's phone mic or the sync-probe path) showing
  the shelf, NOT an assertion.

## Track 0 — GATE. Re-test the build that is already on disk. No code.

The whole ticket may be H0. Nothing else may start until this is answered.

1. Do not rebuild. Quit the running Audiout Dev (pid 5166) and relaunch
   `open "/Users/alechenderson/Projects/AirPlay Controller/.claude/worktrees/eq-livetest/build/Audiout Dev.app"`,
   which is the 04:50, trim-free binary. Confirm the new pid's mapped image matches the
   file on disk before handing over: `lsof -p <pid> | awk '$4=="txt"' | head -1` and
   `stat -f "%i %z %N" "<that path>"` must show the same inode and size.
2. Ask the owner to repeat the test on the Move 2: play music, raise Bass to about +8,
   listen, then set it back. Ask for the three answers in "Owner questions" below at
   the same time.
3. Re-run the measurement on the new session (read-only, no repo changes). Group
   `~/Library/Logs/Audiout/telemetry.jsonl` `stream_health` lines of that session id by
   `ts`, and for each window that has stream `0` and at least one stream
   `>= 2147483648`, print `peak_dbfs(home) − peak_dbfs(0)` and the per-window growth of
   both `writes` counters. Report: how many windows, how many deltas exactly 0.0, the
   distribution of the rest.
4. Report back: the owner's verdict in their words, the delta distribution, the
   confirmed pid/inode match.

Gate:
- Symptom GONE and deltas now positive on a bass boost → H0 was it. Close this ticket
  with that finding, add one line to `.scratch/eq-gapless/issues/01-eq-headroom.md`
  recording that the second report came from a stale process, and stop. No code.
- Symptom PERSISTS on the confirmed-fresh build → Track 1.

## Track 1 — minimum observability (only past the gate)

Three local `Telemetry.log` lines and one field fix. All local-only: `Telemetry.log`
never leaves the Mac (`AudioutCore/Sources/AudioutCore/AGENTS.md`, the
`Telemetry.fail` rule), which is why device ids are allowed here. Add NO PostHog event
and NO `Analytics.capture` — event names are an external contract and nothing here is a
user action worth a dashboard. No new `Telemetry.fail`: nothing here is a failure the
user felt yet.

1. `NativeBackend.swift`, in `setEQ` (`:3283`), after `self.eqByDeviceID[id] = eq` and
   before the Bluetooth branch: `Telemetry.log(.airplay, "eq_edit", [...])` with
   `device` (the id as passed), `commit`, `shaped` (`!eq.isFlat`), `bass`, `treble`,
   `loudness`, `balance`, `bands` (count of non-zero band gains), `home`
   (`wholeSystemStreamByDevice[id]` or `none`), `added` (whether `added.contains(id)`),
   `perapp` (whether `streamBindings[id] != nil`), `known` (whether `known[id] != nil`).
   Numbers, booleans and one local device id only — no names, no free text.
2. `NativeBackend.swift`, at the end of `pushEQPlanLocked` (`:3453-3477`), immediately
   before the `captureControlQueue.async`: `Telemetry.log(.airplay, "eq_plan", [...])`
   with `main` (`on`/`off`), `streams` (one joined string of `streamID:shaped|flat` in
   the order they are published) and `devices` (one joined string of
   `deviceID=stream` from `wholeSystemStreamByDevice`, restricted to ids in `added`).
   That single line answers H1 and every one of its sub-cases: which ids are homed,
   which streams are published, and which of them carry a processor.
3. `NativeCaptureCoordinator.swift`, inside `setEQPlan` (`:1629-1634`) under the
   `queue.sync`: `Telemetry.log(.captureWS, "eq_plan_applied", [...])` with
   `passthrough` (`plan.isPassthrough`), `main`, `streams` (same
   `streamID:shaped|flat` join). Prints what the delivery path will actually use, so a
   plan that is right when published and wrong when applied (H2) separates from H1 on
   two adjacent log lines.
4. `NativeBackend.swift:8617`, the `stream_health` `devices` field: it reads
   `streamBindings` only, so a whole-system home stream reports an empty device list
   (evidence 9). Make it name the union — per-app ids bound to that stream plus the
   ids `wholeSystemStreamByDevice` maps to it — keeping the existing sorted,
   comma-joined format. This is a log-content fix, not a behaviour change.

Tests (`AudioutCore/Tests/AudioutCoreTests/NativeBackendTests.swift`, extend, do not
add a suite):
- One test that a connected speaker with a non-flat stored curve appears in
  `stream_health`'s `devices` for its OWN home stream. Comment sentence: reverting
  `devices` to `streamBindings`-only turns this red.
- No test for the three log lines themselves — a log line asserting its own content is
  the kind of test the root AGENTS.md rule 4 deletes.

Commands: `bash scripts/run-tests.sh --filter NativeBackendTests` and
`bash scripts/run-tests.sh --filter EQProcessorTests`; quote both
`Test run with N tests` lines. Then
`APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh`,
quit the running copy, launch the new one, and hand it to the owner with the same test
as Track 0 step 2.

Report back: the `eq_edit` / `eq_plan` / `eq_plan_applied` lines around the owner's
bass edit, verbatim, plus the Track 0 step 3 delta measurement re-run on that session.

## Track 2 — GATE. Name the cause, then ask.

Read the three lines against the hypotheses:
- `eq_edit` shows `shaped=true` but `eq_plan` publishes that stream as `flat`, or omits
  it → H1. The `device`/`home`/`devices` fields say which sub-case: a key the plan does
  not know (id mismatch), `perapp=true` (per-app claim — then the row should ALSO be
  showing the `.perAppRouting` bypass note, and if it is not, that missing note is a
  second defect to report), `added=false` (not streaming).
- `eq_plan` publishes `shaped` and `eq_plan_applied` shows `flat` or `passthrough=true`
  → H2, in the coordinator.
- Both say `shaped`, the deltas stay at exactly 0.0 → the bytes handed to the engine
  are identical despite a live processor: re-read `deliver` (`:1918-1936`) for a copy
  that is written but not used, then H3.
- Both say `shaped` AND the deltas move with the slider, but the owner still hears no
  bass → H4. Say so plainly and propose the acoustic check; do NOT reach for a code
  change.

STOP here and report. Do not write the fix in the same pass. A fix that changes what
the EQ does to the sound needs the owner's ruling first (087). A fix that only restores
a curve that was supposed to reach the audio is ordinary repair and can proceed to
Track 3 with the cause named in the report.

## Track 3 — the fix, once Track 2 names the cause

Not specified here on purpose: the repair for H1's id-mismatch sub-case, H1's stale
per-app-binding sub-case, H2 and H3 are four different edits in four different files,
and writing all four now would be guessing. Whichever it is, it obeys:

- One fix at the root, not a guard at each call site.
- No behaviour change beyond restoring the stored curve to the audio it was always
  meant to reach.
- A test in `NativeBackendTests` that fails against the code as it stands today,
  with its one-sentence defect comment.
- The Track 1 instrumentation stays in — it is how the next report gets read.
- Adversarial review before it is called done.

## Out of scope — do not touch

- `EQProcessor`'s DSP: no headroom, no makeup trim, no preamp, no default changes, no
  curve reshaping (087 is rejected; a user-controlled preamp is a separate owner ask).
- The Track C topology: `connectTargetStreamLocked`, the budget, the
  one-stream-per-speaker rule. This ticket explains a symptom on top of it; it does not
  revisit the design.
- Bluetooth EQ (`pushBTSinkEQLocked`, `BTSyncedSink`), Main Out EQ behaviour, per-app
  routing behaviour, the device-EQ store format.
- No PostHog event, no `Analytics.capture`, no `Telemetry.fail`.
- No cleanup, no abstractions, no error handling for impossible cases, no
  backwards-compat shims, no renames, no doc rewrites beyond what a landed fix needs.
- `main` is merge-only; stay on `claude/equalizer-latency-optimization-d714da`.

## Owner questions — ask with the Track 0 build, they change the ranking

1. Between the first report (087 build) and the second, did you quit and relaunch
   Audiout Dev, or has the same copy been running the whole time? Evidence 6 says the
   same process has been running since 04:44 and predates the trim-free build.
2. `device-eq.json` has Loudness ON and every gain at 0 for three speakers. Did you
   turn Loudness on, and were you editing the speaker's own Equalizer or Main Out?
3. Do you have Music (or anything else) routed to the Move 2 as a per-app route? A
   per-app claim bypasses that speaker's EQ by design, and the session shows one was
   active at least once.

## Comments

- 2026-09-15 scoping (Fable): ranking above rests on the 176-window peak-delta
  measurement and on the running-image mismatch (evidence 5 and 6). Both are
  reproducible from `~/Library/Logs/Audiout/telemetry.jsonl` and `lsof`; neither needs
  a build.
