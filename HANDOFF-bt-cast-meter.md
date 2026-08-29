# HANDOFF — Bluetooth + Cast live meter (`claude/live-meter-bluetooth-cast-fc554c`)

Written 2026-08-29, late session. **UPDATE: the commit landed clean as
`65ad6eda`** (full 3,061-test suite passed on the mule with no flakes) —
§1/§4's "check if it landed" caveat no longer applies. Live check and the
roadmap 038 correction are still outstanding.

## 1. Where things stand

- **Worktree:** `.claude/worktrees/nifty-booth-abc386`, branch
  `claude/live-meter-bluetooth-cast-fc554c`, HEAD `65ad6eda` on top of
  `main@45598506`, pushed to origin.
- The first two commit attempts were blocked by pre-existing full-suite
  flakes (see §4) — the third attempt landed clean. If you're reading this
  after a `git pull`/fresh clone, you should already have `65ad6eda`; if not,
  `git fetch origin && git log origin/claude/live-meter-bluetooth-cast-fc554c`.

## 2. The task

Alec asked for an investigation into extending the per-device live level
meter (the little bar under a device row, `LevelMeterView`) to Bluetooth and
Cast output devices — it only worked for AirPlay. Two parallel discovery
subagents investigated BT and Cast independently; both converged on the
exact same root cause and the exact same fix, in the same function.

## 3. The fix (already written, already tested — do not re-derive it)

One function: `NativeBackend.isMeterable` in
`AudioutCore/Sources/AudioutCore/NativeBackend.swift` (~line 8914).

**Root cause.** It asked `Device.isSelected`. That flag is set only on the
AirPlay-engine state path. Bluetooth and Cast ids are structurally excluded
from the engine — `setOutputSet`'s converge loop guards on
`!device.isBluetooth`/`!device.isCast` — so `isSelected` was *never* true for
either, and both meters were permanently dark. This was not a missing
plumbing problem: the RMS the meter needs already existed. The BT and Cast
sinks are handed the identical converted PCM buffer the meter's RMS is
computed from, a few lines apart in `NativeCaptureCoordinator.deliver`
(BT-FANOUT / CAST-FANOUT comments mark the spot).

**The fix** — each transport now answers "am I actually rendering right now"
with its own fact instead of `isSelected`:

```swift
private func isMeterable(_ device: Device) -> Bool {
    if device.isBluetooth { return device.connectionState == .connected }
    if device.isCast { return castPlaying.contains(device.id) }
    return device.isLocalDevice ? syncedLocalSinkEnabled : device.isSelected
}
```

- BT's `.connected` means its delay gate has opened
  (`BTDeviceSink.hasStartedRendering`) — the same state that lights its armed
  dot. Deliberately NOT `btSelectedUIDs` (selected but silent) — a test pins
  this.
- Cast's `castPlaying` is set when the receiver reports PLAYING.
- Both mirror the pre-existing pattern for the local device
  (`syncedLocalSinkEnabled`), which had the identical bug fixed in an earlier
  phase and was the template for this fix.

**Files touched** (all currently `git add`-ed):
- `AudioutCore/Sources/AudioutCore/NativeBackend.swift` — the fix + doc comment
- `AudioutCore/AGENTS.md` — metering contract section updated
- `AudioutCore/Tests/AudioutCoreTests/NativeBackendBTSelectionTests.swift` —
  2 new tests + `FakeCapture.onLevel` fixed from a discard (`get{nil}set{}`)
  to a real store, since that suite could never test metering before
- `AudioutCore/Tests/AudioutCoreTests/NativeBackendCastTests.swift` — 2 new tests
- `AudioutCore/Tests/AudioutCoreTests/NativeBackendTests.swift` — `LevelSink`
  and `subscribeLevels` widened from `private` to internal so the BT/Cast
  suites can reuse them (no behavior change)

**Test results** (on the mule, `AUDIOUT_TEST_PREFER=remote`):
NativeBackendBTSelectionTests 33/33, NativeBackendCastTests 14/14,
NativeBackendTests 223/223.

## 4. Two traps this fix documents — READ before touching `isMeterable` again

1. **The meter does NOT follow a BT sync trim.** Alec asked this directly.
   One system-wide RMS feeds every device's bar, measured at capture time,
   *before* any per-device delay is applied. A trim changes `BTSyncedSink`'s
   delay line, which is downstream of that measurement. So dialling in
   `-500ms` changes when the speaker sounds and never when the bar moves —
   and every device's bar is identical regardless of its own delay. Most
   visible on Cast, which plays ~5.5s behind. This is consistent with the
   existing house rule (meter = PRE-volume SOURCE level, never the delayed/
   attenuated output) but nobody has separately decided whether Alec wants a
   delay-aware meter later. Don't build one without asking — it would need a
   per-device delay line for metering, which doesn't exist today.

2. **Roadmap 038 names the wrong cause.** It blames `BTSyncedSink` for "never
   publishing levels" and lists `LevelMeterView.swift`/`DeviceRowView.swift`/
   `BTSyncedSink.swift` as the touch set. None of those changed. Correct or
   close the entry once this is verified live — see §5.

## 5. Still owed (in priority order)

1. **Land the commit** if it hasn't (§1). If the full-suite guard fails
   again, read the failure list before assuming it's the same flakes —
   compare against clean `main` the way this session did (checked out a
   throwaway worktree off `45598506`, ran the same suites there). The
   failing set has rotated across three attempts so far
   (`TCCProbeRunnerTests` x3 process-spawn tests, `CastLiveAudioServerTests
   .servesAnEndlessChunkedWavStream` wall-clock pacing,
   `NativeBackendTests.bindBowsOutDuringWholeSystemTeardownAndIsRedriven`) —
   all four confirmed to reproduce on clean `main` or pass 3/3 in isolation
   on this branch. That's real evidence, not an assumption — if a NEW test
   shows up in the failure set that ISN'T one of these four, stop and
   investigate for real before treating it as a flake.
2. **Push the branch** — `git push -u origin claude/live-meter-bluetooth-cast-fc554c`.
   Per CLAUDE.md, every worktree branch needs a GitHub counterpart; this one
   doesn't have one yet.
3. **Live check on real hardware.** Nobody has built the dev id or held the
   live-test slot for this branch. Needs: `scripts/livetest.sh acquire`,
   `scripts/make-app.sh` (reuse `com.audiout.Audiout.dev` — this is a bug
   fix, not a permissions-path test), select a real BT speaker AND a real
   Cast receiver, play audio, confirm both bars move. If the armed dot
   already lights for a BT row, the meter will too — they share
   `.connected`.
4. **Correct roadmap 038** once live-verified — wrong touch list (§4.2),
   update status/notes, cite the actual commit.
5. **Ask Alec** about the wizard hold-silent case: a BT speaker held at zero
   gain by the alignment intercept is still `.connected`, so its meter will
   move while the speaker makes no sound. Consistent with the source-meter
   rule but a visible judgment call nobody has confirmed with him.

## 6. Commit message (already used / to reuse if retrying)

Saved at the time of writing in the scratchpad as `msg.txt` — if that's
gone, here's the text:

```
Meter Bluetooth and Cast rows from the tap they already share

`isMeterable` asked `Device.isSelected`, which only the AirPlay engine ever
sets. Bluetooth and Cast ids are structurally excluded from that engine by
`setOutputSet`'s converge guard, so neither could answer it true and both
transports' bars stayed empty.

Nothing had to be measured: the BT and Cast fan-outs are handed the same
converted PCM the meter's RMS is computed from, a few lines apart in
`NativeCaptureCoordinator.deliver`. Each transport now answers with its own
"rendering now" fact instead — a BT row's `.connected` (its delay gate has
opened) and `castPlaying` for a receiver that reported PLAYING, mirroring how
the local device already substitutes `syncedLocalSinkEnabled`.

Both use the rendering fact rather than selection on purpose: selection is
intent, and metering it would move the bar while the speaker is still silent.
A negative test per transport pins that.

The bar shows the UNDELAYED source, so a BT sync trim never moves it — the
trim acts on that device's delay line, downstream of the one system RMS every
bar is fed from. Documented as a trap; it is most visible on Cast, which plays
seconds behind.
```

## 7. Related memory

See auto-memory entries `bt-cast-meter-staged-uncommitted.md`,
`livetest-slot-queue.md`, `feedback-no-merge-without-explicit-go-ahead.md`.
