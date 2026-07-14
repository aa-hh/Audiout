#!/usr/bin/env bash
#
# verify-0f3-soak.sh — T-0f-3: 10-minute end-to-end soak + rough latency.
# Same chain as verify-0f2-e2e.sh but 600 s, with health sampling every 30 s
# and a continuity/underrun analysis at the end.
#
# Run ./dev/verify-0f2-prep.sh first (starts + selects the Verify Receiver).
# Play ANY system audio you like for the duration (music, YouTube, etc.) —
# or let the script loop the test tone if you pass --tone.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIOCAP_DIR="$REPO_ROOT/dev/audiocap"
AC="$AUDIOCAP_DIR/.build/release/audiocap"
FIFO="$REPO_ROOT/dev/owntone/media/spike.fifo"
RUN="$REPO_ROOT/dev/.run"
RECV_PCM="$RUN/verify-recv.pcm"
DUR=600
TONE="/tmp/tone440.wav"

echo "--- preflight ---"
[[ -x "$AC" ]]  || { echo "!! audiocap not built"; exit 1; }
[[ -p "$FIFO" ]] || { echo "!! FIFO missing"; exit 1; }
RECV="$(pgrep -f 'shairport-sync -c .*verify-recv\.conf' 2>/dev/null | head -1 || true)"
[[ -n "$RECV" ]] || { echo "!! Verify Receiver not running — run ./dev/verify-0f2-prep.sh first"; exit 1; }
echo "receiver pid = $RECV"

SRC=""
if [[ "${1:-}" == "--tone" ]]; then
  [[ -f "$TONE" ]] || { echo "!! $TONE missing"; exit 1; }
  ( while true; do afplay "$TONE"; done ) & SRC=$!
  echo "looping test tone (pid $SRC)"
else
  echo ">>> Play some system audio now (music/video) and keep it going ~10 min <<<"
fi

cd "$AUDIOCAP_DIR"; mkdir -p captures
: > "$RECV_PCM"

echo
echo "--- starting capture -> FIFO ($DUR s) ---"
T0=$(date +%s)
"$AC" --pipe "$FIFO" --duration "$DUR" 2> captures/soak.log & CAP=$!
sleep 1
curl -s -X PUT  'http://localhost:3689/api/queue/clear' -o /dev/null -w "clear: %{http_code}\n"
curl -s -X POST 'http://localhost:3689/api/queue/items/add?uris=library:track:2' -o /dev/null -w "add: %{http_code}\n"
curl -s -X PUT  'http://localhost:3689/api/player/play' -o /dev/null -w "play: %{http_code}\n"

# rough latency: time from play command until receiver file first grows
LAT="n/a"
for i in $(seq 1 100); do
  SZ=$(stat -f%z "$RECV_PCM" 2>/dev/null || echo 0)
  if [[ "$SZ" -gt 0 ]]; then LAT="$(( $(date +%s%N)/1000000 - T0*1000 )) ms (play->first receiver bytes)"; break; fi
  sleep 0.1
done
echo "rough latency: $LAT"

echo
echo "--- soaking; health sample every 30 s ---"
PREV=0; STALLS=0
for i in $(seq 1 $((DUR/30))); do
  sleep 30
  kill -0 "$CAP" 2>/dev/null || { echo "!! audiocap exited early at ${i}x30s"; break; }
  SZ=$(stat -f%z "$RECV_PCM" 2>/dev/null || echo 0)
  GREW=$((SZ-PREV)); PREV=$SZ
  STATE=$(curl -s http://localhost:3689/api/player | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null || echo "?")
  SEL=$(curl -s http://localhost:3689/api/outputs | python3 -c '
import sys,json
for o in json.load(sys.stdin)["outputs"]:
    if o["name"]=="Verify Receiver": print(o["selected"]); break' 2>/dev/null || echo "?")
  EXPECT=$((30*44100*2*2))
  FLAG="ok"
  if [[ "$GREW" -lt $((EXPECT*9/10)) ]]; then FLAG="UNDERRUN?"; STALLS=$((STALLS+1)); fi
  echo "t=$((i*30))s  recv+=${GREW}B (expect ~${EXPECT}B)  player=$STATE selected=$SEL  [$FLAG]"
done

echo
echo "--- teardown + verdict ---"
wait "$CAP" 2>/dev/null || true
[[ -n "$SRC" ]] && { kill "$SRC" 2>/dev/null; pkill -f "afplay $TONE" 2>/dev/null; }
curl -s -X PUT 'http://localhost:3689/api/player/stop' -o /dev/null -w "stop: %{http_code}\n"
kill "$RECV" 2>/dev/null || true
curl -s -X PUT 'http://localhost:3689/api/queue/clear' -o /dev/null -w "clear: %{http_code}\n"

tail -5 captures/soak.log
python3 - "$RECV_PCM" "$DUR" "$STALLS" <<'PY'
import struct, math, sys
path, dur, stalls = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = open(path, "rb").read()
n = len(data)//2
if n == 0:
    print("VERDICT: FAIL — receiver got nothing"); sys.exit(1)
s = struct.unpack("<%dh" % n, data[:n*2])
rms = math.sqrt(sum(x*x for x in s)/n)/32768.0
secs = n/2/44100
print(f"receiver: {len(data)} bytes = {secs:.1f}s of audio (target ~{dur}s), RMS={rms:.5f}, stalls flagged={stalls}")
ok = rms > 1e-4 and secs > dur*0.9 and stalls == 0
print("VERDICT:", "PASS — stable non-silent stream for the full soak" if ok
      else "PARTIAL/FAIL — see stats above")
sys.exit(0 if ok else 1)
PY
