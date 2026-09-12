# Passive drift tracking — keep Bluetooth speakers aligned using the music itself

Decided with Alec 2026-09-12 (grilling session). Supersedes roadmap 062.

## Problem

After chirp calibration, Bluetooth speaker alignment moves during a session. Bench
research (`dev/notes/bt-latency-stability-research-2026-09-05.md`) says the movement
is discrete jumps, not slow drift: stream restart after silence rolls a fresh
20–90 ms latency, OS audio-mode changes shift 70–90 ms, warm-up creeps ~60 ms over
the first 20–30 min, each reconnect lands 20–90 ms from last time. Re-running the
chirp probe fixes it but is audible and needs the phone ritual. Alec thinks he has
also heard slow creep during uninterrupted playback; the bench data says no
(−0.02 ppm inter-speaker). Field logging settles that (ticket 06).

## Core idea

The mic does not need a known sound — it needs a reference, and we have one: we are
the sender. Every block leaving the fan-out (`NativeCaptureCoordinator.deliver`)
carries a monotonic host-clock timestamp. Retain a short history of those bytes,
cross-correlate a mic capture against it, and each speaker's arrival shows up as a
correlation peak whose delay is measured against the Mac's clock — the source of
truth. That reference never jumps when a speaker does, so even all speakers jumping
at once stays measurable.

What music cannot do that chirps can: attribution. All speakers play the same
program, so the mic can't tell which peak belongs to which speaker
(`dev/notes/mic-probe-calibration-brief.md:50-54` deferred exactly this). The way
out: chirp calibration gives known per-speaker delays (the baseline); afterwards a
jump moves one peak while the others stay put — attribute by which peak moved. When
several move at once, apply the most likely assignment, re-sample, and swap if the
verify sample disagrees (best guess + verify). Music's other weakness — quiet or
bass-only passages carry little timing information — is handled by the existing
confidence machinery (peak-to-sidelobe with median floor, `SyncProbeCorrelator`):
low confidence = discard the window, never act on it.

## Decisions (all Alec's, 2026-09-12)

| # | Decision |
|---|---|
| 1 | Chirps stay for initial calibration. Passive listening is a drift tracker only. |
| 2 | Sampling: short periodic windows (a few seconds, well under 10 s), plus event triggers: silence→audio, reconnect, audio-mode change. Plus a manual re-sync button on iOS. |
| 3 | Mac built-in mic is the primary tracker — always on, no ritual. iPhone mic is used only for calibration and the re-sync button (iOS background-mic limits rule out phone-side periodic sampling). |
| 4 | Silence→audio jump is prevented, not just corrected: keep feeding the Bluetooth stream silent frames during silence so it never restarts. Configurable, with a timeout (default 10 min) after which we let it idle and accept one jump on next play. |
| 5 | Correction lands in playback gaps where possible (inaudible by definition); small residuals slew gradually by resampling; never a hard snap during music. |
| 6 | Thresholds (starting values, tune from field data): <10 ms leave alone; 10–40 ms auto-correct silently; ≥40 ms correct and surface it. Same 10/40 lines as the staleness recommendation in `bt-latency-stability-research-2026-09-05.md:204-225`. |
| 7 | Ambiguous attribution → best guess + verify (apply likeliest assignment, re-sample, swap if wrong). No per-speaker signal tweaks, no level dips. |
| 8 | Mic movement mimics all-speakers-jumped (2.9 ms/m). Guard both ways: motion sensors gate phone captures; the everything-shifted-by-the-same-amount pattern re-baselines instead of correcting (only guard available on the Mac). |
| 9 | Mac mic gone blind (lid closed, wrong room): after N consecutive low-confidence windows, stop sampling quietly and show a small status note. No nagging; re-sync button still works. |
| 10 | iOS re-sync button: records ~5–10 s of the playing music, streams the capture to the Mac (which holds the reference bytes) for correlation. On low confidence: show the manual by-ear paddles, with the chirp probe as an offered option. |
| 11 | Every sample is logged locally — doubles as the field data that confirms or kills the mid-playback-creep theory and tunes the thresholds. |
| 12 | Roadmap 062 (reconnect-survival band-split chirps) folds into this: the reconnect trigger in decision 2 covers its goal without audible chirps. |

## What already exists (verified against code 2026-09-12)

- Matched-filter correlation, sub-sample peak interpolation, confidence scoring:
  `audiout-shared` `Sources/ProbeKit/SyncProbeCorrelator.swift`. Reuse; the passive
  correlator swaps the re-rendered sweep for retained program audio.
- Outgoing bytes + `CLOCK_MONOTONIC` pts exist per block in
  `NativeCaptureCoordinator.deliver` (`:1847`), including per-sink variants — but
  nothing retains them; each block is written and dropped. Ticket 01.
- Mac mic capture pinned to built-in device (never default input — HFP trap):
  `MicProbeSession.swift` / `BuiltInMicRecorder`.
- Phone capture + network staging: `ProbeCaptureSession` in audiout-remote,
  commands in `audiout-shared` `AudioutProtocol/CompanionCommand.swift`. Today the
  phone re-renders sweeps locally; the re-sync path instead ships the capture to
  the Mac. Ticket 07.
- Settle gate (`BTClockStability`, 60 s window) is the existing jump *detector* on
  the pacing clock — a cheap trigger input for ticket 03, not a replacement for
  acoustic measurement.

## Tickets

| # | File | Blocked by |
|---|---|---|
| 01 | issues/01-reference-ring-buffer.md | — |
| 02 | issues/02-passive-correlator.md | 01 |
| 03 | issues/03-mac-mic-sampler.md | 02 |
| 04 | issues/04-bt-keepalive-silence.md | — |
| 05 | issues/05-correction-application.md | 03 |
| 06 | issues/06-field-logging.md | 03 |
| 07 | issues/07-ios-resync-button.md | 02 |
| 08 | issues/08-roadmap-fold-062.md | — |
