# 0e3 + 0f2 — human verification (copy-paste, run in ahh's Terminal)

These are the four human checks for T-0e-3 (per-app tap + exclude) and T-0f-2
(tap → S16LE FIFO → OwnTone → fake receiver). **Run them at the machine, in a
foreground Terminal window** — the TCC audio-capture dialog only renders there, and
the agent that built this could not click it. Every step prints its own PASS/FAIL.

Assumptions already true (set up by the build task):
- `audiocap` rebuilt at `dev/audiocap/.build/release/audiocap` (selftest passed).
- OwnTone running (`dev/owntone/`, JSON API :3689), `pipe_sample_rate = 44100`.
- Pipe FIFO `dev/owntone/media/spike.fifo` exists (`library:track:2`).
- macOS AirPlay Receiver is OFF (port 5000 free). If unsure, Step 4 checks it.

All commands assume you start from the repo root:

```sh
cd "/Users/alechenderson/Projects/Audiouter"
```

Set a shell shortcut used below:

```sh
AC="dev/audiocap/.build/release/audiocap"
```

---

## Step 0 — Re-grant TCC (REQUIRED after the rebuild)

The CLI is ad-hoc signed, so rebuilding it **reset the audio-capture grant**. Reset
the record so the dialog fires cleanly, then trigger it with a 3 s throwaway capture:

```sh
tccutil reset AudioCapture           # clears the grant for all apps (re-arms the prompt)
$AC --duration 3 --out /tmp/_grant_probe.pcm
```

- A dialog **"Terminal would like to record this computer's audio."** appears →
  click **Allow** (or open System Settings ▸ Privacy & Security ▸ Screen & System
  Audio Recording and enable **Terminal**).
- If the dialog appeared *after* capture started, the probe run captured silence —
  that's fine, it was only to trigger the prompt.
- **Confirm the grant took:** play any audio (e.g. a YouTube tab, or the afplay
  line below) and re-run the probe; the tool must print
  `OK captured NON-SILENT audio`:

```sh
( afplay /System/Library/Sounds/Submarine.aiff & ) ; \
  $AC --duration 3 --out /tmp/_grant_probe.pcm
```

Expected tail: `audiocap: OK captured NON-SILENT audio (peak 0.NN).`
If it still says `ALL SILENCE`, the grant did not attach — re-open the Settings pane
and toggle Terminal on, then retry. **Do not proceed until this prints NON-SILENT.**

---

## Step 1 — Per-app tap PASS/FAIL (`--pid`)

Two `afplay` processes play two pure tones. Tap ONLY the 440 Hz one; the capture must
contain 440 Hz and NOT 880 Hz.

```sh
cd "/Users/alechenderson/Projects/Audiouter/dev/audiocap"
AC=".build/release/audiocap"

# 1. Generate two 20 s pure-tone WAVs (once).
ffmpeg -nostdin -y -f lavfi -i "sine=frequency=440:duration=20" -ar 44100 -ac 2 /tmp/tone440.wav
ffmpeg -nostdin -y -f lavfi -i "sine=frequency=880:duration=20" -ar 44100 -ac 2 /tmp/tone880.wav

# 2. Start both tones looping in the background; capture their pids.
( while :; do afplay /tmp/tone440.wav; done ) & A440=$!
( while :; do afplay /tmp/tone880.wav; done ) & A880=$!
sleep 1   # let both open their audio streams so pid->object translation works

# 3. The real pid to tap is the afplay child, not the subshell. Find it:
PID440=$(pgrep -f "afplay /tmp/tone440.wav" | head -1)
echo "tapping 440 Hz afplay pid = $PID440"

# 4. Tap ONLY the 440 Hz process for 8 s.
$AC --pid "$PID440" --duration 8 --out captures/perapp440.pcm

# 5. Stop the tone loops.
kill $A440 $A880 2>/dev/null; pkill -f "afplay /tmp/tone" 2>/dev/null

# 6. Verdict: 440 must be present, 880 absent.
python3 rms.py --tones captures/perapp440.pcm 44100 440 880 2
```

**Expected:** `VERDICT: PASS — 440.0 Hz present and 880.0 Hz absent, as required.`
(The `present/absent ratio` should be large, ≥8; 880 Hz magnitude near zero.)

**FAIL modes:**
- `present tone too weak` → the 440 afplay wasn't captured (wrong pid, or it wasn't
  playing). Re-check `PID440` is the `afplay` child, and that Step 0 granted TCC.
- `the '880.0 Hz' tone leaked in` → the per-app tap captured audio it shouldn't
  have. That's a real T-0e-3 failure — report it.

---

## Step 2 — Exclusion tap PASS/FAIL (`--exclude`)

Same two tones. Global tap EXCLUDING the 440 Hz process; the capture must contain
880 Hz and NOT 440 Hz. (This is the feedback-loop guard exercised for real.)

```sh
cd "/Users/alechenderson/Projects/Audiouter/dev/audiocap"
AC=".build/release/audiocap"

( while :; do afplay /tmp/tone440.wav; done ) & A440=$!
( while :; do afplay /tmp/tone880.wav; done ) & A880=$!
sleep 1
PID440=$(pgrep -f "afplay /tmp/tone440.wav" | head -1)
echo "excluding 440 Hz afplay pid = $PID440"

# Global tap of everything EXCEPT the 440 process.
$AC --exclude "$PID440" --duration 8 --out captures/exclude440.pcm

kill $A440 $A880 2>/dev/null; pkill -f "afplay /tmp/tone" 2>/dev/null

# Verdict: 880 must be present, 440 absent.
python3 rms.py --tones captures/exclude440.pcm 44100 880 440 2
```

**Expected:** `VERDICT: PASS — 880.0 Hz present and 440.0 Hz absent, as required.`

**FAIL modes:**
- `present tone too weak` → nothing else was making sound; make sure the 880 tone
  loop is running (and no other loud app is masking it).
- `the '440.0 Hz' tone leaked in` → exclusion did not take — the excluded process's
  audio still reached the capture. Real T-0e-3 failure; report it.

> Note: if other apps are playing audio during this run, the "everything-else" tap
> will also contain their audio — that's correct behavior, and the 880 tone still
> dominates 440. Keep the machine otherwise quiet for the cleanest verdict.

---

## Step 3 — End-to-end: system audio → S16LE FIFO → OwnTone → fake receiver (30 s)

This proves the full T-0f-2 bridge with a SILENT receiver-side capture (shairport's
`stdout` backend → a file, checked for non-silence — no audible feedback, and the
capture excludes shairport so there's no loop).

### 3a. Confirm AirPlay Receiver is off (port 5000 must be free)

```sh
lsof -iTCP:5000 -sTCP:LISTEN -n 2>/dev/null && \
  echo "!! Port 5000 IN USE — turn OFF System Settings ▸ General ▸ AirDrop & Handoff ▸ AirPlay Receiver" || \
  echo "OK: port 5000 free"
```

Only proceed when it says `OK: port 5000 free`.

### 3b. Start ONE fake receiver with its decoded PCM captured to a file

We launch shairport-sync directly (not via fake-speakers.sh) so its `stdout` backend
goes to a **file** we can inspect, instead of /dev/null.

```sh
cd "/Users/alechenderson/Projects/Audiouter/dev"
SHAIRPORT="$(command -v shairport-sync)"
RUN=".run"; mkdir -p "$RUN"
cat > "$RUN/verify-recv.conf" <<'EOF'
general = { name = "Verify Receiver"; output_backend = "stdout"; };
EOF
# stdout (decoded S16LE 44100 stereo) -> capture file ; stderr -> log
"$SHAIRPORT" -c "$RUN/verify-recv.conf" -v > "$RUN/verify-recv.pcm" 2> "$RUN/verify-recv.log" &
RECV=$!
echo "shairport pid = $RECV"
sleep 2
kill -0 "$RECV" 2>/dev/null && echo "receiver alive" || { echo "!! receiver died:"; tail -3 "$RUN/verify-recv.log"; }
```

Confirm OwnTone sees it (mDNS, a few seconds):

```sh
curl -s http://localhost:3689/api/outputs | python3 -c '
import sys,json
for o in json.load(sys.stdin)["outputs"]:
    print(o["id"], repr(o["name"]), "type="+o.get("type",""))'
```

You should see a row named `Verify Receiver`. Copy its numeric **id** into `OUT` below.

### 3c. Select + unmute the receiver output in OwnTone

```sh
OUT=<paste the Verify Receiver id here>
curl -s -X PUT "http://localhost:3689/api/outputs/set" -H 'Content-Type: application/json' -d "{\"outputs\":[\"$OUT\"]}" -o /dev/null -w "select: %{http_code}\n"
curl -s -X PUT "http://localhost:3689/api/outputs/$OUT" -H 'Content-Type: application/json' -d '{"volume": 70}' -o /dev/null -w "volume: %{http_code}\n"
```

Both should print `204`.

### 3d. Start audiocap → FIFO, and start OwnTone playing the pipe

Order matters: OwnTone must be reading the FIFO (or about to) so audiocap's
`open(O_WRONLY)` unblocks. Start audiocap in the background first; it blocks on open.
Then explicitly start OwnTone on the pipe (autostart is unreliable — pipe brief).

Do NOT pass `--exclude` here. The silent shairport (file backend) never opens a
Core Audio stream, so translate-PID fails and audiocap aborts — and it needs no
excluding: it makes no sound, so there is no feedback loop. (Exclusion is proven
in Step 2 against an audible process. In the real app, exclusion targets must be
resolved lazily — a process is only excludable once it starts playing audio.)

```sh
cd "/Users/alechenderson/Projects/Audiouter/dev/audiocap"
AC=".build/release/audiocap"
FIFO="/Users/alechenderson/Projects/Audiouter/dev/owntone/media/spike.fifo"

# Play known audio to capture (loop a tone or your music) for the duration:
( for i in $(seq 1 12); do afplay /tmp/tone440.wav; done ) & SRC=$!

# Global tap (no --exclude, see above), S16LE -> FIFO, 30 s. Blocks on FIFO open.
$AC --pipe "$FIFO" --duration 30 2> captures/e2e.log & CAP=$!
sleep 1

# Tell OwnTone to read the pipe (clear queue -> add pipe -> play).
curl -s -X PUT  'http://localhost:3689/api/queue/clear' -o /dev/null -w "clear: %{http_code}\n"
curl -s -X POST 'http://localhost:3689/api/queue/items/add?uris=library:track:2' -o /dev/null -w "add: %{http_code}\n"
curl -s -X PUT  'http://localhost:3689/api/player/play' -o /dev/null -w "play: %{http_code}\n"

# Let it stream ~25 s, then check OwnTone stayed healthy mid-stream.
sleep 25
curl -s http://localhost:3689/api/player | python3 -c 'import sys,json;d=json.load(sys.stdin);print("player state:",d["state"])'
curl -s http://localhost:3689/api/outputs | python3 -c '
import sys,json
for o in json.load(sys.stdin)["outputs"]:
    if o["name"]=="Verify Receiver": print("receiver selected:",o["selected"])'
```

Expected mid-stream: `player state: play` and `receiver selected: True`.
(If `selected` is False, OwnTone auto-deselected after a stall — see pipe brief;
report it.)

### 3e. Tear down cleanly and check the receiver actually got non-silent audio

```sh
wait $CAP 2>/dev/null                       # audiocap self-stops at 30 s and closes the FIFO
kill $SRC 2>/dev/null; pkill -f "afplay /tmp/tone" 2>/dev/null
curl -s -X PUT 'http://localhost:3689/api/player/stop' -o /dev/null -w "stop: %{http_code}\n"
kill "$RECV" 2>/dev/null                     # stop shairport

# audiocap's own summary (should be NON-SILENT, no ring overflow, FIFO opened):
tail -6 captures/e2e.log

# The receiver's decoded PCM (shairport stdout backend = S16LE 44100 stereo).
# Check it is non-silent = audio traveled tap -> FIFO -> OwnTone -> AirPlay receiver.
python3 - <<'PY'
import struct, math
data = open("/Users/alechenderson/Projects/Audiouter/dev/.run/verify-recv.pcm","rb").read()
n = len(data)//2
if n == 0:
    print("receiver PCM EMPTY — no audio reached the receiver. FAIL"); raise SystemExit(1)
s = struct.unpack("<%dh" % n, data[:n*2])
rms = math.sqrt(sum(x*x for x in s)/n)/32768.0
print(f"receiver bytes={len(data)} frames={n//2} RMS={rms:.5f}")
print("VERDICT: PASS — receiver got NON-SILENT audio" if rms > 1e-4
      else "VERDICT: FAIL — receiver audio is silent")
PY
```

**Expected:**
- `captures/e2e.log` tail: `OK captured NON-SILENT audio`, `FIFO open — OwnTone
  attached`, `wrote NNNN bytes (S16LE to FIFO)`, and NO `ring overflow` warning.
- Receiver PCM check: `VERDICT: PASS — receiver got NON-SILENT audio`.

If you also want to hear it (optional, breaks the "silent" property but confirms
pitch is correct — a 440 Hz tone should sound like 440 Hz, not shifted):
re-run 3b with `output_backend = "ao"` instead of `stdout`.

### 3f. Leave OwnTone in a clean state

```sh
curl -s -X PUT 'http://localhost:3689/api/queue/clear' -o /dev/null -w "clear: %{http_code}\n"
```

OwnTone stays running for later tasks; queue cleared, player stopped, receiver killed.

---

## One-line summary of what PASS across all four means

- Step 0: TCC re-granted, capture non-silent.
- Step 1: per-app `--pid` tap captured ONLY the target app (440 present, 880 absent).
- Step 2: `--exclude` removed the target app from the global tap (880 present, 440 absent).
- Step 3: the S16LE FIFO bridge carried real system audio through OwnTone to an
  AirPlay-1 receiver at the correct 44100 rate, without underruns or auto-deselect.
