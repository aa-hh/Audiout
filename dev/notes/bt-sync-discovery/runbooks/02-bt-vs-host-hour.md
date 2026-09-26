# Runbook 2: do Bluetooth speakers drift against the Mac's clock, and can the app see it?

**Question.** Bluetooth-to-Bluetooth drift is closed (PR #200). What is open is whether
all Bluetooth speakers slide *together* against the host clock (one recording showed
~1 ms/min; the Move 2's pacing clock ran +21.7 ppm against host). If they do, every
Bluetooth speaker parts from every AirPlay speaker by roughly a minute's worth of ms per
hour. And the key design question: **does the app's own `bt_clock_deviation` line
predict that slide?** If yes, the fix is a cheap continuous servo on a signal the app
already has. If the acoustic slide is there and the log slope is flat, only a microphone
can see it.

**Decides.** The error signal for the Bluetooth servo (discovery option 1.1) and whether
common-mode drift is a real product problem. No AirPlay needed: the Mac's own speakers
are the host-clocked reference, and the built-in mic is the instrument.

**Needs.** Your Mac (lid open, on mains power, on 5 GHz Wi-Fi if possible, no full-screen
game running: Game Mode moves Bluetooth latency by 70–90 ms), one or two Bluetooth
speakers, the dev build, QuickTime Player, `click-track-3s.wav`, `click-pair-spacing.py`
(numpy). About 75 minutes, mostly unattended.

## Part A: in-app hour (the direct measurement)

1. Build and launch the dev id as in Runbook 1 (acquire the slot first).
2. Connect the Bluetooth speaker(s) and wait a full minute (the clock settles after
   connect; the Mac shows no indicator for it); each must have an alignment.
3. Selection: **This Mac plus the Bluetooth speaker(s)**. Mac speakers at a moderate
   level; Bluetooth speaker ~1–2 m from the Mac. Quiet room, nobody moving the laptop.
4. Note the time and the telemetry position:
   ```
   date -u; wc -l ~/Library/Logs/Audiout/telemetry.jsonl
   ```
5. QuickTime: open `click-track-3s.wav`, View › Loop, play. Start a **New Audio
   Recording** on the built-in mic. Leave both running for **60 minutes**. Do not pause,
   do not change volume, do not touch the speaker's buttons, do not open the sync drawer
   (a trim seek would move the offset on purpose).
6. Stop the recording, save as `hour.m4a`. Stop playback.

Read the acoustic slide:
```
afconvert -f WAVE -d LEI16 hour.m4a hour.wav
python3 click-pair-spacing.py hour.wav > hour.txt; tail -3 hour.txt
```
The last line gives the linear fit in ms/min and ppm, plus the first and last offsets.
The per-line output shows whether the change is a smooth line (rate drift) or steps
(latency events). With two Bluetooth speakers the script sees only the loudest second
arrival; run it twice with one speaker at a time if the output looks confused, or just
use one speaker for the hour.

Read the app's own view of the same hour. Every 30 s it logs how far the speaker's
pacing clock has moved from where host time says it should be:
```
grep bt_clock_deviation ~/Library/Logs/Audiout/telemetry.jsonl | tail -130 > dev.txt
python3 - <<'EOF'
import json, re
rows=[json.loads(l) for l in open('dev.txt')]
by={}
for r in rows: by.setdefault(r['uid'],[]).append((int(r['hostNanos'])/1e9, float(r['ms']), int(r['jumps'])))
for uid,pts in by.items():
    t0=pts[0][0]; xs=[p[0]-t0 for p in pts]; ys=[p[1] for p in pts]
    n=len(xs); mx=sum(xs)/n; my=sum(ys)/n
    slope=sum((x-mx)*(y-my) for x,y in zip(xs,ys))/sum((x-mx)**2 for x in xs)
    print(f"{uid[:12]}: {n} lines over {xs[-1]/60:.0f} min, slope {slope*60:+.3f} ms/min = {slope*1000:+.1f} ppm, jumps {sum(p[2] for p in pts)}, first {ys[0]:+.1f} last {ys[-1]:+.1f} ms")
EOF
```

## Part B (optional, 30 min): the spike tool's number

The drift meter on branch `claude/bt-multi-spike` plays a tone on each of two Bluetooth
speakers and reports each speaker's rate against the built-in mic's clock, which is the
Mac's audio clock. It is an independent instrument for the same quantity, and it is what
the "−0.02 ppm" claim came from (a 120 s run). Needs two Bluetooth speakers.

```
git fetch origin claude/bt-multi-spike
git worktree add .claude/worktrees/bt-multi-spike origin/claude/bt-multi-spike
cd .claude/worktrees/bt-multi-spike/dev/bt-multi-spike
swift build -c release            # type this in a terminal, not through Claude Code (the hook blocks bare swift)
.build/release/bt-multi-spike --list
.build/release/bt-multi-spike --drift-meter "<speaker A name>" "<speaker B name>" --seconds 1800 --log ~/Desktop/drift-meter.txt
```
Play a few seconds of audio to each speaker first if the tool reports a parked amp. It
needs Microphone permission for the terminal; if it cannot get a prompt, the README in
that folder describes the `.app` wrapper. Read `drift-meter.txt`: the per-speaker
"ppm vs mic" lines are the numbers to compare with Part A, and the "LINE vs STAIRCASE"
verdict says whether the speaker free-runs or re-syncs its buffer.

## Reading the result

| Acoustic slide (Part A script) | `bt_clock_deviation` slope (Part A log) | Meaning | What we build |
|---|---|---|---|
| ≥ ~0.3 ms/min (≥ 5 ppm) | same sign and within ~30 % of the acoustic number | The speaker follows the Mac's delivery rate and the app can see that rate | The servo steers the sink's resampler from the pacing-clock error against host time. Cheap, continuous, no mic needed for rate. |
| ≥ ~0.3 ms/min | flat (< 2 ppm) | The speaker's own buffer or clock is doing it, invisibly to the host | Rate is a microphone problem: event-driven acoustic re-checks plus a slow correction, no host servo for rate |
| flat (< 0.2 ms/min, < 3 ms over the hour) | flat | No common-mode drift in this setup | The servo still earns its place for pulls, lock misses and pauses (Runbook 1), but rate is not the field problem; the 1.2.0 creep came from something else |
| steps, not a line | `jumps` > 0 at the same times | Latency events, not drift | The event-driven design is right; check that a mic window fires on each |

Also worth noting from the log: whether the two speakers (if two) show the same slope
(shared cause, likely the controller or stack) or different ones (per-link).

## Hand back

Reply with: the script's last line (ms/min, ppm, first and last offset), the deviation
slope per speaker, and whether the per-line output is a line or steps. Attach `hour.txt`
and `dev.txt` (and `drift-meter.txt` if Part B ran). Release the slot.

## What this does not measure

The built-in mic and the Mac's speakers share the Mac's audio-device clock, which itself
runs tens of ppm off `CLOCK_MONOTONIC`. The acoustic slide here is Bluetooth against
*that* clock; against AirPlay (PTP on host time) the number can differ by the built-in
device's own offset. That offset is what the local sink's PI loop already corrects, and
it is small next to the ~17–22 ppm in question, but keep it in mind before quoting a
BT-vs-AirPlay figure. The AirPlay version of this test is the same procedure with an
AirPlay speaker in place of This Mac, whenever one is available.
