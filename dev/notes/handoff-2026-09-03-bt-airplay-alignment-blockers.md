# Handoff — four defects found aligning a Bluetooth speaker to AirPlay (2026-09-03)

Self-contained. Found during the first real-hardware test of companion sync
calibration, on the settle-window branch (`claude/settle-window-adaptive`).
None of the three findings belongs to that branch's work: all are in the
alignment and AirPlay paths and all reproduce on `main`.

The short version: **a Bluetooth speaker aligns to the Mac's own output
perfectly and could not align to an AirPlay device until the start buffer was
raised.** Four independent defects, any of which is enough on its own:

1. Adding AirPlay to a room shrinks the Bluetooth compensation budget from
   1500 ms to 500 ms. Confirmed, and a settings change fixes it today.
2. The reference tone does not reliably reach the AirPlay speaker.
3. The confidence floor is 5, so a reading barely above noise is accepted and
   written to the store as a speaker's latency.
4. A keep that raises the stored latency can silence the speaker permanently.
   Seen twice. This one costs the user their music, not just their calibration,
   and it is the one to fix first.

Line numbers are the settle-window branch, which adds about 20 lines to
`NativeBackend.swift` above the alignment code. On `main` subtract that.

## What works, so the contrast is clear

Three runs, Bluetooth headset as target, MacBook speakers as reference,
microphone at the listening position:

| Heard | Prior latency | Stored | Confidence |
|---|---|---|---|
| +242.7 ms | 0 | 243 ms | 2747 |
| −25.4 ms | 243 | 218 ms | 1668 |
| −0.1 ms | 218 | 218 ms | 3425 |

It converges to nothing left to correct, and confidence runs in the thousands
where pure noise scores about 1. Nothing was clamped. The measurement itself,
the correlator, and the apply path are all sound. Keep this table: it is the
control for anything below.

An earlier attempt with the microphone held against the headset and the
speakers beside it scattered badly (413, 500, 500 ms). That was the rig, not
the code. The correlation needs two sources at comparable level and path
length, which a headset pressed to the microphone does not give it.

## Blocker 1 — adding AirPlay SHRINKS the compensation budget (confirmed, and there is a setting that fixes it)

`btWizardLatencyRangeMs` (`NativeBackend.swift:11151`) sets the ceiling on how
much a speaker's own latency can be compensated:

```
upper = reference − BTSyncedSink.defaultBTOnlyBufferMs
```

`defaultBTOnlyBufferMs` is 500 (`BTSyncedSink.swift:1303`). The reference
depends on what else is playing (`BTSyncedSink.swift:42`,
`usesPresentationReference` is `airPlayPresent || castPresent`):

| Room | Reference | Source | Usable ceiling |
|---|---|---|---|
| Bluetooth and the Mac only | 2000 ms | `btWizardReferenceBufferMs` (`NativeBackend.swift:3896`) | 1500 ms |
| Anything with AirPlay or Cast | 1000 ms | the live start buffer (`NativeBackend.swift:6871`) | **500 ms** |

Read that table twice, because it is the finding. A room gets **less** headroom
once AirPlay joins it, not more. Without AirPlay every Bluetooth sink runs
against a dedicated 2000 ms reference; the moment AirPlay or Cast appears the
room switches to the start buffer, which defaults to 1000. The intuition that
"AirPlay has about two seconds of delay, so there must be plenty of room" is
exactly backwards for this code path.

Measured on the same speaker in the same session:

| Reference | Wanted | Kept | Clamped | Confidence |
|---|---|---|---|---|
| AirPlay | 421 ms | 421 ms | no | 294 |
| AirPlay | 616 ms | **500 ms** | **yes** | 914 |

The speaker needs 616 ms of compensation and the room can only give it 500. The
proof that the correction stops reaching the speaker is in the second run: the
first added 203 ms, so a working correction would have left the second measuring
near zero. It measured +194.9 ms, essentially unchanged. The delay is already
floored (`BTReferenceTimeline`, clamped at or above 0), so raising the stored
latency further does nothing audible. About 120 ms of lag is unfixable in this
configuration by design.

**There is a workaround today, and it is confirmed.** The start buffer is
user-settable to 1000, 1500 or 2250 ms (`AppSettings.startBufferOptionsMs:116`).
Raising it to 2250 on the same speaker, same room, same session:

| Reference | Range ceiling | Heard | Kept | Clamped | Confidence |
|---|---|---|---|---|---|
| AirPlay, buffer 1000 | 500 ms | +194.9 ms | 500 ms | yes | 914 |
| AirPlay, buffer 2250 | **1750 ms** | −71.3 ms | 429 ms | **no** | 2796 |

The clamp is gone, confidence is back in the thousands, and the correction lands
instead of saturating. Reported from the room as "almost perfectly able to get
the delay". So the diagnosis is settled, not hypothesised.

The budget a room needs is `speaker latency + 500`. A Bluetooth speaker in the
wild carries 100 to 400 ms, and this headset wanted 616 ms of compensation, so
the 1000 ms default cannot serve a fairly ordinary case. Whether the fix is a
higher default, a budget sized from the speakers actually present, or telling
the user their room needs a bigger buffer, is a decision nobody has made.

Whether the real fix is to raise the default, to size the buffer from the
speakers actually present, or to tell the user their room needs a bigger buffer,
is a decision nobody has made yet. Note the ceiling exists for a reason: at
`latency == reference` the delay is 0, the ring is seeked dry, and the speaker
goes silent for the rest of the session with no way back. That comment is on
the range function itself and it should stay true of any replacement.

## Blocker 2 — the reference tone does not reliably reach the AirPlay speaker

Reported from the room: the tone is not consistently audible from the AirPlay
device during a run. The send loop agrees. During both AirPlay-reference runs,
`send_sched` reported gaps of 222 ms and 232 ms against a median cadence of
11.7 ms, which is roughly twenty packet cycles missed.

The measurement's own confidence corroborates it. Against the MacBook it ran
1668 to 3425. Against AirPlay it fell to 294 and 914: still finding an arrival,
but a far weaker one.

**Not yet proven:** that a sweep actually landed inside one of those stalls.
The gaps are real and the confidence drop is real, and the two are consistent
with each other, but nothing logs the sweep's own delivery. That is the next
thing to instrument if this is picked up.

These stalls are not new and not caused by the alignment work. Sessions going
back to 2026-08-29 show worse ones (2.2 s, 5.4 s, once 106 s) on builds with
none of this code. They deserve their own investigation.

## Blocker 3 — the confidence floor is 5, which admits noise

`confidence` is a peak-to-sidelobe ratio: pure noise scores about 1. The phone
will report anything at or above **5**, and the Mac accepts any finite
non-negative number (`CompanionCommandDispatcher.swift:293` onward, and the
comment there states the floor).

That floor is far too low. From this session:

| Run | Confidence | What it did |
|---|---|---|
| good runs | 1668 to 3425 | converged to −0.1 ms |
| 15:26:27 | **5.1** | stored 500 ms, clamped, offset +230.9 ms |

A reading 500 times weaker than a good one squeaked past the floor, was
accepted, was clamped to the ceiling and was written to the store as this
speaker's latency. Nothing told the user it was junk. This is the failure the
whole feature exists to prevent: not a refusal, but a confident wrong number.

The fix is a real floor, informed by data now that measurements are logged. The
gap between 5 and 1668 is wide enough that almost any threshold in between would
have caught this one. It belongs on the phone, where the analysis happens and
where a refusal already has a page to live on ("couldn't hear well enough",
which is exactly what a low ratio means).

## Blocker 4 — a keep that raises the latency can silence the speaker for good

The worst of the four, because it costs the user their music rather than their
calibration. Seen twice on 2026-09-03, both times with the same trigger.

The clearest instance, device `54-2A-1B-79-08-9E:output`:

| Time | Event | Delay in force |
|---|---|---|
| 15:36:43.673 | `bt_sink_anchored` | 1795 ms (matches stored latency 455) |
| 15:36:45.888 | `wizard_keep` writes **670 ms** | implies 1580 ms |
| after | **nothing, ever** | speaker silent |

The sink logged no anchor, no rebuild, no ring drops and no failure after that
keep. The app stayed running. The speaker just stopped.

`delay = reference − latency`, so raising the stored latency LOWERS the delay,
and the change is applied as a live seek forward through the ring
(`BTDeviceSink.applyTrimDelta`, no rebuild). Both incidents were forward seeks
of roughly 200 ms. The first recovered on its own; the second did not.

This is the same hazard the range ceiling already guards against at its extreme.
The comment on `btWizardLatencyRangeMs` says that at `latency == reference` the
delay is 0, the ring is seeked completely dry, and the speaker is "silent for
the rest of the session with no way back". The ceiling stops the delay reaching
zero. It does not stop a large forward seek emptying the ring well short of
zero, which is what appears to be happening here.

**Recovery:** deselect and reselect the speaker, which drops and rebuilds its
sink (`BTSyncedSink.setDevices`). Nothing short of a rebuild brings it back.

**What is not yet known:** whether the ring is genuinely dry or the render loop
has stopped for another reason. Nothing logs a dry ring or a seek, so this needs
instrumenting on the seek path before it can be called closed. That is the first
thing to add if this is picked up.

## Where the reference comes from, since it surprised us

`CompanionSnapshotBuilder.alignmentReferenceID:220` picks, in order: the Mac's
own output, then any non-Bluetooth device, then any remaining speaker. So while
the MacBook speakers are audible they are always the reference and an AirPlay
device is never measured against. Aligning a Bluetooth speaker "to the room"
while the Mac plays aligns it to the Mac, and any disagreement between the Mac
and AirPlay is inherited whole.

That is worth stating in the product sense: a speaker can be perfectly aligned
and still audibly late against a third device, and nothing on screen says so.

## The measurement log this was read from

The branch adds one line per measurement, `bt_align_measurement`
(`NativeBackend.swift`, inside `applyCompanionAlignmentMeasurement`): the
microphone's confidence, the raw offset it heard, the stagger, the prior stored
latency, the corrected value, what was actually kept, whether it clamped, the
range at the time, and the settle estimate. `confidence` is a peak-to-sidelobe
ratio carried on the wire from the phone, which the Mac previously discarded at
`AppDelegate` `reportMeasurement`.

It is marked as diagnostic and should be dropped once one-shot measurement is
proven on hardware. It is what made both findings above readable in minutes
rather than guessed at, so consider keeping it until then.

## Watch out for

- **Test rig decides everything.** Two real speakers, comparable volume, phone
  at the listening position. A headset against the microphone produces
  confident wrong answers.
- **Only one Audiout may run at a time** (the helper binds its ports
  exclusively), and the shared dev bundle id is behind the live-test slot
  (`scripts/livetest.sh`). A parallel session held it during this test; the way
  through is a fresh bundle id, not taking the slot.
- **A fresh bundle id costs a new microphone and local-network grant**, because
  macOS pins those to the bundle id and signature.
- **`make-app.sh` needs `.env`**, which no new worktree has, and it exits before
  codesigning without it. Check the real exit code; a half-built bundle still
  launches.
