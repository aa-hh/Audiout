#!/usr/bin/env bash
#
# verify-0f2-e2e.sh — T-0f-2 Step 3d-3f, automated: system audio -> S16LE FIFO
# -> OwnTone -> fake AirPlay receiver (30 s), with a PASS/FAIL verdict.
#
# Preconditions (Steps 0, 1, 2, 3a-3c — done manually first, see
# dev/notes/0e3-0f2-verify.md):
#   • TCC audio-capture grant confirmed non-silent (Step 0)
#   • AirPlay Receiver is OFF, port 5000 free (Step 3a)
#   • "Verify Receiver" shairport-sync instance running (Step 3b)
#   • That output selected + unmuted in OwnTone (Step 3c)
#   • /tmp/tone440.wav exists (generated in Step 1)
#
# Usage:
#   ./dev/verify-0f2-e2e.sh
#
# Exit code reflects the final verdict: 0 = PASS (receiver got non-silent
# audio), 1 = FAIL or a precondition wasn't met.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIOCAP_DIR="$REPO_ROOT/dev/audiocap"
AC="$AUDIOCAP_DIR/.build/release/audiocap"
FIFO="$REPO_ROOT/dev/owntone/media/spike.fifo"
TONE="/tmp/tone440.wav"
RECV_PCM="$REPO_ROOT/dev/.run/verify-recv.pcm"

echo "--- preflight ---"
[[ -x "$AC" ]]  || { echo "!! audiocap not built at $AC"; exit 1; }
[[ -p "$FIFO" ]] || { echo "!! FIFO not found at $FIFO"; exit 1; }
[[ -f "$TONE" ]] || { echo "!! $TONE missing — regenerate with ffmpeg (Step 1)"; exit 1; }
lsof -iTCP:3689 -sTCP:LISTEN -n >/dev/null 2>&1 || { echo "!! OwnTone doesn't seem to be listening on :3689"; exit 1; }

RECV="$(pgrep -f 'shairport-sync -c .*verify-recv\.conf' 2>/dev/null | head -1 || true)"
[[ -n "$RECV" ]] || { echo "!! 'Verify Receiver' shairport-sync not running — run Step 3b first"; exit 1; }
echo "found Verify Receiver shairport pid = $RECV"

SELECTED="$(curl -s http://localhost:3689/api/outputs | python3 -c '
import sys, json
for o in json.load(sys.stdin)["outputs"]:
    if o["name"] == "Verify Receiver":
        print(o["selected"])
        break
')"
[[ "$SELECTED" == "True" ]] || { echo "!! 'Verify Receiver' not selected in OwnTone — run Step 3c first (got: ${SELECTED:-not found})"; exit 1; }
echo "Verify Receiver is selected in OwnTone"

cd "$AUDIOCAP_DIR"
mkdir -p captures

echo
echo "--- 3d: system audio -> FIFO -> OwnTone (~30 s) ---"

# Play known audio to capture, looping for the duration.
( for i in $(seq 1 12); do afplay "$TONE"; done ) & SRC=$!

# Global tap, S16LE -> FIFO, 30 s. Blocks on FIFO open.
# NOTE: no --exclude here. The silent shairport (file backend) never opens a
# Core Audio stream, so it cannot be excluded (translate-PID fails and audiocap
# aborts) — and it needs no excluding: it makes no sound, so no feedback loop.
# Exclusion is proven separately in step 2 against an audible process.
"$AC" --pipe "$FIFO" --duration 30 2> captures/e2e.log & CAP=$!
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

echo
echo "--- 3e: tear down + verdict ---"

wait "$CAP" 2>/dev/null || true      # audiocap self-stops at 30 s and closes the FIFO
kill "$SRC" 2>/dev/null || true
pkill -f "afplay $TONE" 2>/dev/null || true
curl -s -X PUT 'http://localhost:3689/api/player/stop' -o /dev/null -w "stop: %{http_code}\n"
kill "$RECV" 2>/dev/null || true     # stop shairport

echo
tail -6 captures/e2e.log

verdict=0
python3 - "$RECV_PCM" <<'PY' || verdict=$?
import struct, math, sys
path = sys.argv[1]
data = open(path, "rb").read()
n = len(data)//2
if n == 0:
    print("receiver PCM EMPTY — no audio reached the receiver. FAIL")
    sys.exit(1)
s = struct.unpack("<%dh" % n, data[:n*2])
rms = math.sqrt(sum(x*x for x in s)/n)/32768.0
print(f"receiver bytes={len(data)} frames={n//2} RMS={rms:.5f}")
print("VERDICT: PASS — receiver got NON-SILENT audio" if rms > 1e-4
      else "VERDICT: FAIL — receiver audio is silent")
sys.exit(0 if rms > 1e-4 else 1)
PY

echo
echo "--- 3f: leave OwnTone clean ---"
curl -s -X PUT 'http://localhost:3689/api/queue/clear' -o /dev/null -w "clear: %{http_code}\n"

echo
if [[ $verdict -eq 0 ]]; then
  echo "=== T-0f-2 Step 3: PASS ==="
else
  echo "=== T-0f-2 Step 3: FAIL ==="
fi
exit "$verdict"
