# Cast latency rig: where the ~5 s goes, and what the 9.5 s cap and 10-sample settle cost

Date: 2026-10-04. HEAD `d87e4529`. Builds on, and does not repeat:
[`006-cast-output-scope-2026-08-22.md`](006-cast-output-scope-2026-08-22.md), [`006-cast-sync-architecture-2026-08-22.md`](006-cast-sync-architecture-2026-08-22.md),
[`bt-sync-discovery/research/cast.md`](bt-sync-discovery/research/cast.md). Paths are under `AudioutCore/Sources/AudioutCore/`
unless shown otherwise.

## What this measures and what it cannot

The rig lets the owner measure, on his own Google Cast hardware, where the ~5 s Cast
delay is spent and how much of it the Mac can cut. The goal is to judge two timing rules
in `CastRoomDelay` (the 9.5 s cap and the 10-sample settle) from recorded numbers instead
of the one 2026-08-22 session.

It reads two things.
- Mac-side stamps on the Cast feed ring: sample-exact timing from the moment the capture
  callback hands over audio to the moment the server renders it for sending.
- A microphone recording of the Mac speakers and the Cast receiver playing the same click
  track, which shows the gap between them as heard.

It cannot read the receiver's output stage below about 15 ms, and it changes no Cast
constant, prime, cushion or room-delay rule. It only measures. The receiver's own buffer
is read from its self-reported lead (`lead_ms`, rtt-gated, about plus or minus 10 ms).

Note, 2026-10-04: PR #283, stacked on this rig, set the ring's standing queue to 80 ms
(`CastFeedRing.standingQueueMs`) and added the feed gate and the 20 ms raise threshold
(`CastRoomDelay.raiseThresholdMs`). The "about 500 ms" ring row and the "+500" expectation
below apply to the rig commit alone.

## Where the time goes

Rows are in stream order.

| Stage | Today | Whose | Rig reads it as |
|---|---|---|---|
| Capture callback to fan-out push | The whole block's push lateness, about 0 to 2 ms | Ours | `ioproc_to_push_ms`, with `ioproc_to_push_max_ms` |
| Feed delay line | `room - settledLead + offset`; 0 for the receiver that set the term, seconds for a faster second receiver | Ours, by policy | `delay_line_ms` |
| Ring queue, the standing cushion | About 500 ms (`cushionFrames` 22 050) | Ours | `queue_ahead_ms` |
| Pacing phase | 0 to 20 ms (`chunkInterval` 0.020) | Ours | `pacing_phase_ms` |
| Socket send | Same timer tick as the render (`CastLiveAudioServer.swift:366`) | Ours | Not measured, zero by construction |
| Prime | 1000 ms of silence per GET. A startup lever, not steady latency: the August table shows first audio at 0.8 s with it against 3.7 s without, and the steady lead unchanged | Ours | `underrun_frames` = 44 100 at GET, and `rendered_s` |
| Receiver buffer | 5.1 to 5.9 s on the Google TV Streamer (August) | The receiver's | `lead_ms`, plus or minus 10 ms, rtt-gated |
| Receiver output stage | 0 to 80 ms per Google's guide; up to about 400 ms through a TV, ARC and soundbar chain (`BTTrimStore.swift:36-41`) | The receiver's | Acoustic recording only |
| Shared per-app mixer hold | 441 frames = 10 ms (`AppRouteMixer.swift:175`). Not on the Cast path today, because Cast is refused as a per-app target; listed for the routing question only | Ours | Not measured |

`e2e_ms = age_ms + lead_ms` is the capture-to-play-head latency of the frame being sent
now. `e2e_ms - room_ms` (with `room_ms` from the latest `room_delay_changed`) is the
alignment error the lead metric cannot see: expected near +500 before the first pause and
near 0 after a pause longer than 0.5 s, if cast.md sections 2.1 and 2.2 are right.

## Mac-side instrument

Switch: the existing diagnostic switch `AIRPLAY_AUDIO_DIAG`. An app started with `open`
does not see a shell variable, so set it for the login session first:

```bash
launchctl setenv AIRPLAY_AUDIO_DIAG ~/Library/Logs/Audiout/audio-diag.log
open "build/Audiout Dev.app"
# when finished:
launchctl unsetenv AIRPLAY_AUDIO_DIAG
```

With the switch on, every status poll (once a second) writes one `cast_stage_timing`
line to `~/Library/Logs/Audiout/telemetry.jsonl`, whether or not the poll's lead sample is
kept. Fields, all strings: `device`, `lead_ms`, `kept` (`1`/`0`), `age_ms`,
`ioproc_to_push_ms`, `delay_line_ms`, `queue_ahead_ms`, `pacing_phase_ms`, `ring_wait_ms`
(each one decimal, or `nil` before the first render that takes real frames, and again after every feed reset until pacing takes real frames; the prime renders none from an empty ring), `ioproc_to_push_max_ms`, `ring_wait_max_ms`
(the maximum since the previous line, one decimal, `0.0` when nothing was pushed or
rendered in it), `e2e_ms`, `queued_ms`, `rendered_s`
(frames rendered since the last feed reset, in seconds), `fanout_drops` (writes the
fan-out threw away on a busy lock).

The identity: `age = ioproc_to_push + delay_line + ring_wait - (the rendered frame's
offset into its block)`, because `ioproc_to_push` is the whole block's push lateness and
`age` is the frame's own; and `pacing_phase = ring_wait - queue_ahead`.

Since 2026-10-06 every stamp is on the raw mach clock: before, the capture `pts` (mach
plus an offset frozen at tap start) was subtracted from `CLOCK_MONOTONIC`, which the time
daemon `timed` slews and steps, so its corrections showed up as phantom changes in
`age_ms` and `ioproc_to_push_ms`.

Watch it live:

```bash
tail -n 0 -F ~/Library/Logs/Audiout/telemetry.jsonl | grep --line-buffered -E '"evt":"(cast_stage_timing|cast_lead_sample|cast_lead_settled|cast_feed_reset|cast_media_status|room_delay_changed|cast_session_state)"'
```

## Acoustic instrument

ProbeKit's microphone probe does not fit as it stands.
- The wizard probe plays its reference sweep on the lane Cast receives
  (`NativeCaptureCoordinator.swift:1909-2014`), so a Cast receiver plays the reference
  sweep, not a target sweep. A Cast lane means editing `deliver()` in
  `NativeCaptureCoordinator.swift`, a review risk path.
- Staging needs a running wizard (`currentWizardInjector()`, `:1499-1505`), and the
  wizard is Bluetooth-only.

So the rig reuses the instrument the Bluetooth runbooks already use: QuickTime audio
recording on the built-in microphone while `click-track-3s.wav` loops through Audiout to
This Mac plus the Cast receiver, analysed with `click-pair-spacing.py`:

```bash
afconvert -f WAVE -d LEI16 rec.m4a rec.wav
python3 dev/notes/bt-sync-discovery/runbooks/click-pair-spacing.py rec.wav --max-offset-ms 1500
```

Resolution: offsets inside plus or minus 15 ms read `merged` (`--min-sep-ms 15`); above
that the reading is at 1 ms.

Known-offset check, run before any Cast conclusion. Record the baseline. Then add Cast
SYNC offsets (the row's sync drawer, 1 ms steps) of +1, +5, +10 and +20 ms over a
pedestal, and confirm the script's offset moves by the same amount within 2 ms. The
pedestal is 0 if the baseline offset is already 40 ms or more; otherwise set +100 ms
first so all five points sit above the merge floor. Record all five readings.

Keep the Mac speakers quieter than the Cast receiver, so the second-loudest peak is the
Cast click. The script's loud/second ratio column is the check.

## Procedure

Owner-run.

1. Setup.
   - `bash scripts/livetest.sh acquire --label cast-rig`
   - `APP_NAME="Audiout Dev" BUNDLE_ID="com.audiout.Audiout.dev" bash scripts/make-app.sh`
   - `launchctl setenv AIRPLAY_AUDIO_DIAG ~/Library/Logs/Audiout/audio-diag.log`
   - `bash scripts/purge-stale-ptp-helpers.sh` (dry run first, read what it lists)
   - `open "build/Audiout Dev.app"`
   - `date -u; wc -l ~/Library/Logs/Audiout/telemetry.jsonl` to mark the start.
2. Record once per receiver: model and firmware (Google Home app, device settings);
   connection (Ethernet, or Wi-Fi band); the Mac output device and its sample rate
   (`system_profiler SPAudioDataType`); Mac on mains; no load generator unless the
   scenario says so.
3. Run each scenario on one TV-class receiver (the Google TV Streamer) and one
   audio-only receiver, with the acoustic recording running and the telemetry tail saved.
   - (a) Cold start: select Cast + This Mac from idle, play the click track, 90 s. From
     the tail record the time from `cast_session_state connecting` to `playing`, the
     `cast_media_status` `lead_s` series until it goes flat, `cast_lead_settled lead_ms`,
     and the first `cast_stage_timing` with `kept=1`.
   - (b) Steady: 5 min. Note the median `e2e_ms - room_ms` and the script's median offset.
   - (c) Silence then resume: pause the click track for 90 s, resume, 2 min. Note
     `queue_ahead_ms` and `e2e_ms` before and after, and the script's offset before and
     after.
   - (d) Soak: 30 min of music, then 2 min of click track. Note the slope the script
     prints (ms/min, ppm), the first and last median `cast_lead_sample lead_ms`, any
     `cast_feed_reset`, `dropped_blocks`, and `fanout_drops`.
   - (e) Selection change: add an AirPlay speaker, remove it, then deselect and reselect
     the Cast receiver. Note each `room_delay_changed`, each `cast_feed_reset
     discarded_ms`, and whether `cast_lead_settled` fires again and how long it takes.
   - (f) Open question 1: AirPlay + Cast + This Mac with the click track, 2 min, pause
     5 s, resume, 2 min. Run the script with `--max-offset-ms 1500` on both halves, and
     take `e2e_ms - room_ms` from the tail.
   - (g) Under load: repeat (b) for 2 min with `bash scripts/load-gen.sh 4 120` running.
4. Close: `launchctl unsetenv AIRPLAY_AUDIO_DIAG`, then `bash scripts/livetest.sh done`.

Hand back: the five known-offset readings; per scenario the numbers named above; the
script output for each recording; and the `telemetry.jsonl` lines from the start mark.

## Decision table

No constant changes are proposed here. Each change below is its own scoped track.

**Block 1: the 9.5 s cap (`CastRoomDelay.maxTermMs`).**
- It defends against holding every other output 9.5 s or more behind live for the sake of
  one receiver. The 10 s line capacities (Cast, AirPlay, local; Bluetooth 11 s) are sized
  to it, so raising it is a capacity change in four rings.
- The procedure must produce, per receiver: `cast_lead_settled lead_ms` from (a), the
  maximum `lead_ms` across (b) to (g), and the lead after (c) and after each (e) step.
- If no receiver settles above 7 000 ms in any scenario, the cap is not binding and stays.
- If an audio-only receiver settles above 9 500 ms in normal play, the cap and all four
  line capacities move together in a separate scoped change.
- Lowering the cap is justified only if (d) or (e) shows post-stall leads the owner cannot
  live with, measured as the median `lead_ms` after the event minus the settled lead. That
  is a product call, recorded as an open question.

**Block 2: the settle (`settleSampleCount` 10, `settleBandMs` 100).**
- It defends against the startup climb: 2 to 3 rebuffers in the first 12 s or so (test
  `theSettleGateDoesNotLatchDuringTheStartupClimb` in `CastRoomDelayTests`). One late
  reply is already removed by the 100 ms rtt gate.
- Its cost: the receiver plays unsynced from PLAYING until it settles, plus a fresh settle
  after every stall and re-GET.
- The procedure must produce, from at least 5 cold starts per receiver: the second at
  which `lead_s` last moved by more than 100 ms (end of the climb), the settled lead, and
  the spread of settled leads across starts.
- If the climb ends within K seconds on every start, a settle of `ceil(K)` samples is
  defensible. Check it by replaying each recorded `lead_ms` series through
  `CastRoomDelay` with the candidate count (the pattern of `CastRoomDelayTests.swift:259-291`)
  and counting settles that later moved more than 150 ms within 60 s. That count must be
  zero.
- If settled leads across starts on one receiver agree within 100 ms, `rememberedLeadMs`
  can be trusted on reselect and the second session's settle can be shortened. Otherwise
  it cannot.

## Open questions for the owner

1. Microphone. Default: the Mac's built-in one via QuickTime, as in the Bluetooth runbooks.
2. Audio-only receiver. Default: whichever Nest or Chromecast Audio is on hand. If none,
   mark the audio-only column not measured; do not substitute a second TV.
3. A line-in or multichannel interface for sub-millisecond work. Default: no. The Mac-side
   stamps are sample-exact, and the acoustic floor of 15 ms is enough for a 5 s budget.
4. Whether the output-stage residue below 15 ms justifies a Cast probe lane in
   `NativeCaptureCoordinator`. Default: no; revisit after this run.
