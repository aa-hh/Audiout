# Cast live-test fix handoff (roadmap 006, Phase (i) hardening)

Date: 2026-08-22. Written for a fresh session with no access to the
conversation that produced it — self-contained, verify everything below
against the code before trusting it.

## Where this sits in the roadmap

Roadmap 006 = Google Cast output support. Phase (i) (Cast as a third,
**unsynced** output transport) is committed on
`claude/cast-devices-support-scope-d72349` at `76bbc2e4`
("Roadmap 006: Phase (i) committed"), pushed to origin, **not merged to
main**. That commit was Fable-reviewed four rounds and shipped with 643
tests green. Read `dev/notes/006-cast-output-scope-2026-08-22.md` (scoping
+ hardware spike log) and `dev/notes/006-cast-sync-architecture-2026-08-22.md`
(the Phase ii/iii/iv sync design, not yet built) for full context. This
document covers ONLY what happened after `76bbc2e4`: a live test on real
hardware found three bugs, and two fix tracks were built in response.

## The live test that found the bugs

The owner built a signed test app (`APP_NAME="Audiout Cast v1"
BUNDLE_ID="com.audiout.Audiout.castv1"`) from `76bbc2e4` and tested
against their Google TV Streamer (192.168.4.54, wired Ethernet, same subnet as
the Mac's Wi-Fi). Results:

1. AirPlay unaffected — as required.
2. The "Cast Devices" popover section appeared correctly, no flicker, but the
   TV's icon rendered gray, reading as "disabled."
3. **First selection worked** — audio reached the TV ~5 s late, matching the
   spike numbers. Deselecting was fast. **Reselecting failed twice in a
   row**: the TV showed the receiver launching and "trying to stream," but
   audio never arrived; the app eventually gave up.
4. Changing the Cast row's volume made the TV show "use the remote to adjust
   the volume" instead of changing level.
5. Untested (deferred): pulling the Ethernet cable mid-play, and quitting the
   app while Cast is active.

## Diagnosis (Fable agent, full text preserved)

A background research agent read the app's own JSON telemetry log
(`~/Library/Logs/Audiout/telemetry.jsonl`, filtered `"cat":"cast"`) with
real timestamps, correlated it against the code, and produced root causes +
exact fix specs. **Full diagnosis text**:
`/private/tmp/claude-501/-Users-<user>-Projects-AirPlay-Controller--claude-worktrees-cast-devices-support-scope-d72349/46a6fb14-da61-42a7-b2ef-04a790fb967b/scratchpad/castv1-diagnosis.md`
(146 lines — **this scratchpad may not survive session end**; the summary
below is complete enough to work from, but re-read the original if it is
still there). The Cast-only telemetry extract it worked from is at
`.../scratchpad/castv1-telemetry-cast.jsonl` in the same directory.

### Bug 1 (PRIMARY, confirmed from the log with timestamps) — the app's own silence watchdog races Cast's startup and starves the feed

`NativeBackend.defaultSilenceFallbackDelay` is 10 seconds
(`NativeBackend.swift:723` at the time of diagnosis). When a selected output
device is not yet "audible," a countdown arms and — if it fires — stops the
whole-system capture tap, on the theory that nothing is listening so capture
should stop to save silence. For a Cast device, `desiredDeviceAudibleLocked`
only returned `true` once the receiver actually reported `PLAYING`
(`castPlaying.contains(id)`) — so from the moment of selection, a Cast
session in `.connecting` counted as "stranded," identically to a genuinely
dead device.

Cast's real connect→PLAYING time on this hardware is **also** about 10
seconds (2.7 s to launch the Default Media Receiver + ~5.5 s of receiver
buffering, per the spike log in `006-cast-output-scope-2026-08-22.md`). The
telemetry showed the capture tap stopping at almost exactly 10.00–10.08 s
after every selection, regardless of what Cast was doing — a dead heat:

| select | tap stops | Δ | Cast reaches playing |
|---|---|---|---|
| attempt 1 | +10.00 s | | +10.9 s (0.9 s **after** the tap already stopped) |
| attempt 2 | +10.00 s | | +12.7 s — recovered anyway |
| attempt 4 (reselect) | +10.05 s | | never — failed |
| session 2 (reselect) | +10.08 s | | never — failed |

When the tap stops mid-connect, the Cast feed ring (fed only from the
capture IOProc) starves. The stock receiver detects the gap, pauses to
rebuffer — and because our server paces the feed at exactly real-time rate,
the receiver can **never** get ahead of playback again with a live,
unbounded source. It sits `PAUSED` forever (confirmed in the log: runs of 6
and 14 consecutive `PAUSED` polls before the user gave up and deselected).
Nothing in the app ever sends a PAUSE command — this is the receiver
self-pausing on starvation.

This single bug explains: the PAUSED-forever hang, and the nondeterminism
("one success, two failures" — pure timing luck on whether Cast's PLAYING
lands before or after the 10 s mark).

**Fix (spec'd exactly, and — see Track T1 below — already written):**
`desiredDeviceAudibleLocked`'s Cast branch should also treat a session that
is still `.connecting` as *not stranded* (return `true`), not just one that
has reached PLAYING. A genuinely dead receiver is still caught safely: the
session's own 15 s `playDeadline` in `CastOutputManager` fails it, the row
leaves `.connecting` for `.failed`, and *then* the watchdog is free to arm.

### Bug 2 (SECONDARY — hypothesis, not fully confirmed by the log alone) — reselecting a Cast device can relaunch onto a receiver still tearing down the old session

Distinct failure signature: `connecting → media IDLE, IDLE, IDLE → failed`,
**no BUFFERING ever**, always immediately after a prior deselect/teardown
(<1 s later). The receiver visibly launched (the owner saw "trying to stream") so
LAUNCH succeeded, but no fetch ever happened.

Two live hypotheses the existing telemetry can't distinguish:
1. **Relaunch race**: on deselect, `CastOutputManager.teardown` sends STOP
   and closes the channel, but on an *immediate* reselect a brand-new
   session/channel is started before the old teardown's STOP has actually
   landed on the receiver. LAUNCHing a Default Media Receiver that is
   already running returns the *existing* app's transport/session id — so
   the new LOAD can land on an app the receiver is simultaneously stopping.
2. **Stale server address**: the per-attempt `CastLiveAudioServer`'s bound
   host/port could be wrong on a fast reselect, so the TV's GET never
   reaches us at all.

The diagnosis explicitly recommends adding diagnostic telemetry *before*
trusting hypothesis 1 over 2, but also specs the likely fix (serialize
relaunch behind the prior teardown's completion) as safe to apply
immediately since it can only help either way. **Both were done together in
Track T2** (see below) rather than staged — a judgment call by the executor,
not by this diagnosis.

### Bug 3 — gray Cast icon

`DeviceRowView` tints every device icon the same neutral gray
(`Tokens.Color.secondaryLabel`) regardless of kind or state — the diagnosis
found **no Cast-specific tinting bug**; an unselected AirPlay icon looks
identical. The "disabled" read is most likely the Cast row's `isAvailable`
flipping to `false` on a single missed Bonjour browse (this wired TV's
mDNS announcement reaches the Mac intermittently — already known from
earlier spike-log testing) combined with the row never showing a connection
halo/dot the way a currently-playing AirPlay row does. Spec'd fix: debounce
the availability flip (grace timer, not an immediate flip on one missed
browse) plus a `cast_row_state` telemetry line to confirm which theory is
right on the next run.

### Bug 4 — Cast volume slider does nothing on this receiver

The Streamer's `RECEIVER_STATUS` reports `volume.controlType: "fixed"` — a
real Cast concept meaning "this receiver's volume is not driven by
`SET_VOLUME`, it belongs to the TV remote/CEC," as opposed to
`"attenuation"` (a normal software-volume speaker). The app never parsed
`controlType` and always sent `SET_VOLUME`, which is silently ignored by a
`fixed` receiver — hence the on-screen "use your remote" notice and no
level change. Spec'd fix: parse `controlType`; for `fixed` receivers, stop
sending `SET_VOLUME` and instead apply the composed level as a PCM gain
inside our own feed ring, ramped over ≤20 ms to avoid zipper noise/clipping.

## What was built in response — two parallel fix tracks

Two Opus executors were launched in **separate git worktrees**, both forked
from `76bbc2e4` (the committed Phase (i) HEAD), so their diffs merge
independently:

- **Track T1** — worktree `~/Projects/AirPlay Controller/.claude/worktrees/cast-p1-fix-t1`, branch `claude/cast-p1-fix-t1` (pushed to origin). Files: `AudioutCore/Sources/AudioutCore/NativeBackend.swift`,
  `AudioutCore/Tests/AudioutCoreTests/NativeBackendCastTests.swift`.
  Covers Bug 1 (primary fix) and Bug 3 (availability debounce + `cast_row_state` telemetry).
- **Track T2** — worktree `~/Projects/AirPlay Controller/.claude/worktrees/cast-p1-fix-t2`, branch `claude/cast-p1-fix-t2` (pushed to origin). Files: `AudioutCore/Sources/AudioutCore/CastOutputManager.swift`,
  `AudioutCore/Sources/CastSender/CastClient.swift`,
  `AudioutCore/Sources/CastFakeReceiver/FakeCastReceiver.swift`,
  `AudioutCore/Tests/AudioutCoreTests/CastOutputManagerTests.swift`.
  Covers Bug 2 (relaunch serialization + five new `cast_*` telemetry events)
  and Bug 4 (fixed-receiver PCM gain).

**Both tracks were interrupted mid-run by an Anthropic API session-limit
error** ("You've hit your session limit"), NOT a code or logic failure. Read
their diffs directly — do not trust either agent's own prose, since neither
got to write a final report. I (the orchestrating session) read both diffs
directly after the interruption and they appear **functionally complete**
against their specs — see the file-by-file summary below — but **neither
has been run through `bash scripts/run-tests.sh` or `bash scripts/build.sh`
to a finished result.** A build attempt on T1 during this handoff timed out
inconclusively (240 s against the remote build queue, disk had 17 GB free
so that wasn't the cause) — this proves nothing either way and must be
re-run properly.

### Track T1 diff summary (read `git diff` in that worktree for ground truth)

- `NativeBackend.desiredDeviceAudibleLocked`: Cast branch now returns `true`
  for `castPlaying.contains(id) || device.connectionState == .connecting`
  (was: only `castPlaying.contains(id)`) — this is the Bug 1 fix, exactly as
  spec'd. AirPlay/BT branches of the function are untouched.
- New `castAbsenceFlips`/`castAbsenceGeneration` state + a new
  `Static let defaultCastAbsenceGrace: TimeInterval = 3` and injectable
  `castAbsenceGrace` constructor parameter — implements a 3-second grace
  timer (not a consecutive-omission counter; the executor's stated reason:
  `NWBrowser`'s `browseResultsChanged` is event-driven, so nothing
  guarantees a second browse ever arrives to decrement a counter) before a
  Cast row flips `isAvailable = false`. A reappearing browse cancels the
  pending flip.
- New `expireCastAbsence`, `logCastRowState`, `castRowConnectionName` —
  wiring for the above plus a `cast_row_state` Telemetry event on every real
  availability/connection-state change (guarded so a teardown `.idle` or a
  dropped late state doesn't spam it).
- Two new tests added to `NativeBackendCastTests.swift` (123 lines added) —
  names not independently confirmed in this handoff pass; read the file.
  The diagnosis asked for `connectingCastSessionDoesNotArmTheSilenceWatchdog`
  and `failedCastSessionStillArmsTheWatchdog`, plus a debounce test
  extending `snapshotSurfacesCastRowsAndKeepsVanishedOnes`.
- **Not yet done**: `AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
  --filter 'NativeBackendCastTests|NativeBackendTests|
  NativeCaptureCoordinatorTests|PopoverDeviceVisibilityTests'`,
  `bash scripts/build.sh`, and reading `aLatePlayingAfterDeselectLeavesTheRowOff`
  (a Phase (i) test) to confirm the new `.connecting` gate in
  `desiredDeviceAudibleLocked` doesn't change its meaning.

### Track T2 diff summary (read `git diff` in that worktree for ground truth)

- `CastFeedRing` gained `currentGain`/`targetGain` (Float, [0,1]),
  `setTargetGain(_:)`, a `gainTarget` read-only accessor, and
  `applyGainLocked` — a per-sample linear ramp capped at 882 frames (20 ms
  at 44.1 kHz) applied inside `render(frames:)` only when gain isn't unity
  on both ends (so the attenuation-receiver path stays a bare memcpy).
  `reset()` now snaps `currentGain` to `targetGain` so a fresh GET doesn't
  replay a stale ramp.
- `CastClient.CastReceiverStatus` gained `volumeControlType: String`
  (parsed from `volume["controlType"]`, default `"attenuation"`).
- `CastOutputManager.Session` gained `volumeControlIsFixed`,
  `loggedHTTPRequest`, `awaitingTeardown`. `pushLevel` now branches: if
  `volumeControlIsFixed`, calls `session.ring.setTargetGain(level)` and
  returns *without* ever calling `SET_VOLUME`; otherwise unchanged.
- New `teardownsInFlight: [String: Int]` dictionary + `teardownFinished`
  method: `setDevices` now checks whether a device id has a teardown in
  flight; if so, the new session is created but marked
  `awaitingTeardown = true` and put into `.connecting` state immediately
  (so the UI shows progress) rather than calling `startRecipe` right away.
  `teardown`'s existing completion closure (`finish`) now also calls
  `teardownFinished(id)` on the manager's queue; when a device's last
  in-flight teardown completes, if a session is waiting, `startRecipe` runs
  then. This is the Bug 2 relaunch-serialization fix — via the teardown's
  own completion, not a fixed delay, as the diagnosis preferred.
- Five new `Telemetry.log(.cast, …)` calls: `cast_server_ready`,
  `cast_launch_ok`, `cast_load_reply` (both success and failure paths),
  `cast_play_sent`, `cast_http_request` (fires once per session, off the
  server's queue hop, not the IOProc).
- `FakeCastReceiver` gained a `controlType` init parameter (default
  `"attenuation"`, injectable for tests), a `setVolumeCount` counter, an
  `events: [String]` log of `connect`/`close`/`LAUNCH`/`STOP` in arrival
  order (for a relaunch-ordering test to read), and advertises
  `controlType` in its `RECEIVER_STATUS` replies.
- New `CastOutputManager.test_ring(forDevice:)` seam so a test can read a
  session's `CastFeedRing` gain directly.
- New tests added to `CastOutputManagerTests.swift` (113 lines) — per spec
  these should include `rapidReselectRelaunchesCleanly`,
  `fixedReceiverAppliesGainInTheFeedNotSetVolume`,
  `attenuationReceiverStillUsesSetVolume`, and
  `fixedReceiverGainRampsWithoutZipper` — **read the file to confirm names
  and that assertions match**, this handoff did not independently verify
  them.
- **Not yet done**: `AUDIOUT_TEST_NO_CACHE=1 bash scripts/run-tests.sh
  --filter 'CastOutputManagerTests|CastFakeReceiverLoopTests|
  CastLiveAudioServerTests|CastMessageCodecTests|CastBrowserTests'`,
  `bash scripts/build.sh`, `bash scripts/build.sh --product cast-spike` +
  `swift run --package-path AudioutCore cast-spike --fake --hold 1`.

## What remains — the plan

1. **Verify each track independently, in its own worktree, exactly as its
   original spec's Verify section said** (see the two "Not yet done" lists
   above — these commands are copied straight from the executor prompts).
   If either fails, fix in that same worktree (small, targeted — the diffs
   are not large) and re-verify. Do not skip this because the diffs "look
   right" — neither track ever ran its own tests.
2. **Fold both tracks into `cast-devices-support-scope-d72349`** (the main
   Phase (i) worktree, still sitting at `76bbc2e4`, clean) the same way
   earlier Phase (i) tracks were merged in this session: `git -C <track-wt>
   add -A --intent-to-add && git -C <track-wt> diff HEAD --binary >
   <scratchpad>/<track>.patch`, then `git apply --3way <patch>` in the main
   worktree. The two tracks touch disjoint files (T1:
   `NativeBackend.swift` + its test file; T2: `CastOutputManager.swift`,
   `CastClient.swift`, `FakeCastReceiver.swift`, `CastOutputManagerTests.swift`)
   so this should apply cleanly with no manual conflict resolution.
3. **Run the combined verification** on the merged tree — the full Cast
   suite plus the wide cross-suite filter Phase (i) used (see
   `006-cast-output-scope-2026-08-22.md`'s Phase (i) section or the git log
   of `76bbc2e4` for the exact filter string; it lists every suite that must
   stay green: `NativeCaptureCoordinatorTests`, `SyncedLocalFanoutTests`,
   `BTSyncedSinkTests`, `NativeBackendTests` and its BT/synced-local/device
   siblings, `AlignmentTickInjectorTests`, `GroupControllerTests`,
   `PopoverControllerTests`, `PopoverDeviceVisibilityTests`,
   `DeviceBluetoothKindTests`, `DeviceCastKindTests`, and every `Cast*Tests`
   suite), plus `bash scripts/build.sh`.
4. **Get a Fable review of the merged fix diff** before committing — same
   pattern as every prior Phase (i) round in this feature: adversarial read
   against THE INVARIANT (no Cast device selected ⇒ AirPlay/BT/local
   byte-identical — re-confirm the new `.connecting` gate and the new
   `teardownsInFlight`/`awaitingTeardown` machinery don't touch that path),
   concurrency/lifecycle of the new gain ramp and teardown-completion chain,
   spec compliance, honesty of whatever report comes out of step 3.
5. **Commit** on `claude/cast-devices-support-scope-d72349` (still not
   merged to main — that's the owner's call, later). Push.
6. **Build a fresh signed test app** with a NEW bundle id/name (never reuse
   `com.audiout.Audiout.castv1` — TCC grants pin to bundle id + code
   signature, so re-signing the same id with changed code produces
   confusing stale-permission failures). Example:
   `APP_NAME="Audiout Cast v2" BUNDLE_ID="com.audiout.Audiout.castv2"
   bash scripts/make-app.sh`.
7. **Guide the owner through the live-test checklist again**, this time
   specifically re-testing the reselect flow (select → deselect → reselect,
   repeat a few times) since that's exactly what Bug 1 and Bug 2 targeted,
   plus the volume slider on the Streamer, plus the two deferred steps from
   the first round: pulling the Ethernet cable mid-play (expect: Cast row
   fails cleanly, AirPlay unaffected) and quitting the app while Cast is
   selected (expect: clean teardown, no stuck player on the TV). Pull
   `~/Library/Logs/Audiout/telemetry.jsonl` again afterward — the five new
   `cast_*` events from Track T2 exist specifically to make the next run's
   diagnosis fast even if something is still wrong.
8. **If Bug 2's root cause turns out to still be present** (i.e. the
   relaunch-serialization fix in T2 doesn't fully fix reselect), the new
   `cast_launch_ok`/`cast_load_reply`/`cast_http_request` telemetry should
   make it possible to tell hypothesis 1 (relaunch race) from hypothesis 2
   (stale server address) apart this time — re-read the diagnosis's
   "SECONDARY" section for exactly what each hypothesis would look like in
   the new events.
9. Only after a clean live test: decide (with the owner) whether to proceed to
   Phase (ii) (the synced N-way timeline + AirPlay pre-delay line design in
   `006-cast-sync-architecture-2026-08-22.md`) or pause here.

## Traps / things a fresh session should know

- **Never reuse a bundle id for a new test build** — see step 6 above,
  documented project-wide in `CLAUDE.md`/`AGENTS.md` already but easy to
  forget mid-debugging-session.
- **The scratchpad paths in this doc are session-scoped** and may be gone
  by the time you read this
  (`/private/tmp/claude-501/.../46a6fb14-.../scratchpad/`). The diagnosis
  content has been summarized in full above specifically so this doc stands
  alone if they're gone.
- **`Agent(isolation: "worktree")` forks from `main`, not the current
  branch** — a known trap hit earlier in this same feature's history (see
  memory `agent-worktree-isolation-forks-from-main.md` if available, or
  just always create track worktrees manually with `git worktree add
  <path> -b <branch> <sha>` from the actual branch HEAD you want).
- **`AUDIOUT_TEST_NO_CACHE=1` is required** when re-running a filter that
  was already green before these edits, or the test runner may report a
  stale cached pass instead of actually re-running.
- **THE INVARIANT is the one thing that must never move**: with no Cast
  device selected, AirPlay/Bluetooth/local output must be byte-identical to
  pre-Cast behavior. Every review round in this feature (Phase (i) had
  four) checked this adversarially by reading every touched hunk in
  `NativeBackend.swift`/`NativeCaptureCoordinator.swift`. Do the same for
  Track T1's changes to `desiredDeviceAudibleLocked` and the new
  `castAbsenceFlips` state before trusting it.
- **This whole feature (`006-*`) is uncommitted-until-reviewed by design**
  — nobody (no executor, no reviewer) commits without an explicit human
  decision. Keep that discipline for this fix too.

## File index

- `dev/notes/006-cast-output-scope-2026-08-22.md` — original scoping +
  hardware spike log (Phases 0 groundwork, the ~5.5s/~7.9s numbers this
  bug's timing analysis depends on).
- `dev/notes/006-cast-sync-architecture-2026-08-22.md` — Phase (ii)/(iii)/(iv)
  design, not started.
- This file — the live-test bug fix handoff.
- Track worktrees (uncommitted, pushed branches, not yet merged into the
  Phase (i) worktree): `cast-p1-fix-t1` (`claude/cast-p1-fix-t1`),
  `cast-p1-fix-t2` (`claude/cast-p1-fix-t2`).
